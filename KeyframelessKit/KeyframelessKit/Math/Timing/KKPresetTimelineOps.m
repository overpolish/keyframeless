/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPresetTimelineOps.h"

#import "KKTimeline.h"

static BOOL _kkAnyLockedSeconds(KKTimeline *t) {
  for (KKLane *l in t.lanes)
    for (KKKeyPose *k in l.keyposes)
      if (k.outgoing.lockedSeconds > 0.0)
        return YES;
  return NO;
}

static BOOL _kkValuesEqual(NSArray<NSNumber *> *a, NSArray<NSNumber *> *b) {
  if (a.count != b.count)
    return NO;
  for (NSUInteger i = 0; i < a.count; i++)
    if (fabs(a[i].doubleValue - b[i].doubleValue) > 1e-6)
      return NO;
  return YES;
}

// Drop interior keyposes that sit inside a flat hold (equal value to both
// neighbours) with no modulation or spatial handles - merging an in-preset then
// an out-preset leaves a redundant hold point at the seam. The curve is
// irrelevant across equal values, so removal is visually identical; the kept
// previous keypose's interval simply spans the wider flat region.
static KKLane *_kkLaneCollapsingFlatHolds(KKLane *lane) {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  if (kps.count < 3)
    return lane;
  NSMutableArray<KKKeyPose *> *out = [NSMutableArray arrayWithObject:kps[0]];
  for (NSUInteger i = 1; i + 1 < kps.count; i++) {
    KKKeyPose *prev = out.lastObject;
    KKKeyPose *cur = kps[i];
    KKKeyPose *next = kps[i + 1];
    BOOL flat = _kkValuesEqual(prev.values, cur.values) &&
                _kkValuesEqual(cur.values, next.values);
    BOOL noMod =
        (!prev.outgoing ||
         prev.outgoing.modulation == KKIntervalModulationNone) &&
        (!cur.outgoing || cur.outgoing.modulation == KKIntervalModulationNone);
    BOOL noSpatial =
        (cur.inHandle == nil && cur.outHandle == nil && !cur.spatialSmooth);
    if (flat && noMod && noSpatial)
      continue; // drop cur; prev's interval now spans the flat region
    [out addObject:cur];
  }
  [out addObject:kps.lastObject];
  if (out.count == kps.count)
    return lane;
  KKLane *nl = [lane copy];
  nl.keyposes = out;
  return nl;
}

static void _kkPresetTimeBounds(KKTimeline *t, double *outMin, double *outMax) {
  double mn = INFINITY, mx = -INFINITY;
  for (KKLane *l in t.lanes)
    for (KKKeyPose *k in l.keyposes) {
      if (k.time < mn)
        mn = k.time;
      if (k.time > mx)
        mx = k.time;
    }
  if (mn == INFINITY) {
    mn = 0.0;
    mx = 0.0;
  }
  *outMin = mn;
  *outMax = mx;
}

KKTimeline *KKPresetTimelineRemapped(KKTimeline *preset, double start,
                                     double end, double clipDurSec) {
  double tmin = 0.0, tmax = 0.0;
  _kkPresetTimeBounds(preset, &tmin, &tmax);
  double srcSpan = tmax - tmin;
  double dstSpan = end - start;
  KKTimeline *out = [preset copy];
  NSMutableArray<KKLane *> *lanes =
      [NSMutableArray arrayWithCapacity:preset.lanes.count];
  for (KKLane *lane in preset.lanes) {
    KKLane *nl = [lane copy];
    NSMutableArray<KKKeyPose *> *kps =
        [NSMutableArray arrayWithCapacity:lane.keyposes.count];
    for (KKKeyPose *kp in lane.keyposes) {
      double nt = (srcSpan > 1e-9)
                      ? start + (kp.time - tmin) / srcSpan * dstSpan
                      : start;
      [kps addObject:[kp keyposeBySettingTime:nt]];
    }
    nl.keyposes = kps;
    [lanes addObject:nl];
  }
  out.lanes = lanes;
  // Pin fixed transition durations for this clip: the remap above set the
  // endpoints + proportional layout; rebalance keeps locked gaps at their
  // seconds and lets flexible holds absorb the rest. Only when the clip
  // duration is known and something is actually locked (else a no-op).
  // `oldDuration` only gates KKTimelineRebalanced's early-return, so passing a
  // value != clipDur forces it to run.
  if (clipDurSec > 0.0 && _kkAnyLockedSeconds(out))
    out = KKTimelineRebalanced(out, clipDurSec + 1.0, clipDurSec);
  return out;
}

KKTimeline *KKPresetTimelineMergedAtFraction(KKTimeline *preset,
                                             KKTimeline *current, double p,
                                             double end, double clipDurSec) {
  if (!current)
    return KKPresetTimelineRemapped(preset, p, end, clipDurSec);

  KKTimeline *remapped = KKPresetTimelineRemapped(preset, p, end, clipDurSec);
  NSMutableDictionary<NSString *, KKLane *> *presetByLabel =
      [NSMutableDictionary dictionary];
  for (KKLane *l in remapped.lanes)
    if (l.label)
      presetByLabel[l.label] = l;

  KKTimeline *out = [current copy];
  NSMutableArray<KKLane *> *merged =
      [NSMutableArray arrayWithCapacity:current.lanes.count];
  NSMutableSet<NSString *> *consumed = [NSMutableSet set];
  for (KKLane *cur in current.lanes) {
    KKLane *pl = cur.label ? presetByLabel[cur.label] : nil;
    // Only the preset's ANIMATED lanes merge in; its disabled (unused) lanes
    // leave the current lane untouched - otherwise an insert turns every param
    // animatable.
    if (!pl || !pl.enabled) {
      [merged addObject:cur];
      if (pl)
        [consumed addObject:cur.label];
      continue;
    }
    [consumed addObject:cur.label];
    NSMutableArray<KKKeyPose *> *kps = [NSMutableArray array];
    for (KKKeyPose *kp in cur.keyposes)
      if (kp.time < p - 1e-6)
        [kps addObject:kp];
    // The last kept keypose must carry an interval to bridge into the preset
    // region (the original lane's final keypose has none).
    if (kps.count && !kps.lastObject.outgoing) {
      KKKeyPose *lc = [kps.lastObject copy];
      lc.outgoing = [[KKInterval alloc] init];
      kps[kps.count - 1] = lc;
    }
    [kps addObjectsFromArray:pl.keyposes];
    KKLane *nl = [cur copy];
    nl.keyposes = kps;
    nl.enabled = YES;
    nl.holdShape = KKLaneHoldShapeAuto;
    [merged addObject:_kkLaneCollapsingFlatHolds(nl)];
  }
  for (KKLane *pl in remapped.lanes)
    if (pl.enabled && (!pl.label || ![consumed containsObject:pl.label])) {
      KKLane *nl = [pl copy];
      nl.enabled = YES;
      [merged addObject:nl];
    }
  out.lanes = merged;
  return out;
}

KKTimeline *KKPresetTimelineAutoLocked(KKTimeline *timeline,
                                       double clipDurSec) {
  if (!timeline || clipDurSec <= 0.0)
    return timeline;
  KKTimeline *out = [timeline copy];
  NSMutableArray<KKLane *> *lanes =
      [NSMutableArray arrayWithCapacity:timeline.lanes.count];
  for (KKLane *lane in timeline.lanes) {
    KKLane *nl = [lane copy];
    NSArray<KKKeyPose *> *src = lane.keyposes;
    NSMutableArray<KKKeyPose *> *kps =
        [NSMutableArray arrayWithCapacity:src.count];
    for (NSUInteger i = 0; i < src.count; i++) {
      KKKeyPose *kp = [src[i] copy];
      if (i + 1 < src.count && kp.outgoing) {
        KKInterval *iv = [kp.outgoing copy];
        BOOL moving =
            !iv.holdsFlat && !_kkValuesEqual(kp.values, src[i + 1].values);
        iv.lockedSeconds =
            moving ? (src[i + 1].time - kp.time) * clipDurSec : 0.0;
        kp.outgoing = iv;
      }
      [kps addObject:kp];
    }
    nl.keyposes = kps;
    [lanes addObject:nl];
  }
  out.lanes = lanes;
  return out;
}
