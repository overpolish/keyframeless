/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Timeline mutation free functions: return a NEW timeline/lane with one lane
// changed (spatial-smooth, aspect-link, link-expression, gradient-type, and
// the value-at-index / nearest-fraction setters). Operate on the public
// KKLane / KKTimeline API; the model classes live in KKTimeline.m.

#import "KKLog.h"
#import "KKTimeline.h"

#import "KKBezierPath.h"
#import "KKEasing.h"
#import "KKPathMorph.h"

KKTimeline *KKTimelineSettingSpatialSmooth(KKTimeline *timeline,
                                           NSString *label, double frac,
                                           BOOL on) {
  KKTimeline *t = [timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].key isEqualToString:label])
      continue;
    KKLane *nl = [lanes[i] copy];
    NSArray<KKKeyPose *> *kps = nl.keyposes;
    if (kps.count == 0)
      return nil;
    NSInteger best = 0;
    double bestDt = fabs(kps[0].time - frac);
    for (NSInteger j = 1; j < (NSInteger)kps.count; j++) {
      double dt = fabs(kps[j].time - frac);
      if (dt < bestDt) {
        bestDt = dt;
        best = j;
      }
    }
    // A hold-linked pair is two coincident keyposes the user sees as one, so
    // toggle the whole linked run (best + its twins) - otherwise clicking the
    // incoming half leaves the outgoing twin a corner and the curve doesn't
    // change. Walk both directions across linked intervals.
    NSMutableIndexSet *run =
        [NSMutableIndexSet indexSetWithIndex:(NSUInteger)best];
    for (NSInteger j = best;
         j + 1 < (NSInteger)kps.count && kps[j].outgoing.endpointsLinked; j++)
      [run addIndex:(NSUInteger)(j + 1)];
    for (NSInteger j = best; j > 0 && kps[j - 1].outgoing.endpointsLinked; j--)
      [run addIndex:(NSUInteger)(j - 1)];
    __block BOOL anyDiffers = NO;
    [run enumerateIndexesUsingBlock:^(NSUInteger j, BOOL *stop) {
      if (kps[j].spatialSmooth != on) {
        anyDiffers = YES;
        *stop = YES;
      }
    }];
    if (!anyDiffers)
      return nil; // whole run already in that state - no commit, no undo entry
    NSMutableArray<KKKeyPose *> *mkps = [kps mutableCopy];
    [run enumerateIndexesUsingBlock:^(NSUInteger j, BOOL *stop) {
      KKKeyPose *nk = [mkps[j] copy];
      nk.spatialSmooth = on;
      mkps[j] = nk;
    }];
    nl.keyposes = mkps;
    lanes[i] = nl;
    t.lanes = lanes;
    return t;
  }
  return nil;
}

KKTimeline *KKTimelineSettingAspectLinked(KKTimeline *timeline, NSString *label,
                                          BOOL on) {
  KKTimeline *t = [timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].key isEqualToString:label])
      continue;
    if (lanes[i].aspectLinked == on)
      return nil; // already in that state - no commit, no undo entry
    KKLane *nl = [lanes[i] copy];
    nl.aspectLinked = on;
    lanes[i] = nl;
    t.lanes = lanes;
    return t;
  }
  return nil;
}

KKTimeline *KKTimelineSettingLinkExpression(KKTimeline *timeline,
                                            NSString *label, NSString *expr) {
  KKTimeline *t = [timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  // Keep an EMPTY expression present (passthrough) so clearing the editor text
  // leaves the inline editor open; only a nil `expr` (the Remove Expression
  // menu) truly clears the binding.
  NSString *e = expr;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].key isEqualToString:label])
      continue;
    NSString *cur = lanes[i].linkExpression;
    if (cur == e || [cur isEqualToString:e])
      return nil; // unchanged
    KKLane *nl = [lanes[i] copy];
    nl.linkExpression = e;
    lanes[i] = nl;
    t.lanes = lanes;
    return t;
  }
  return nil;
}

KKTimeline *KKTimelineSettingGradientType(KKTimeline *timeline, NSString *label,
                                          NSInteger type) {
  KKTimeline *t = [timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].key isEqualToString:label])
      continue;
    KKLane *nl = [lanes[i] copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    BOOL changed = NO;
    for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
      NSArray<NSNumber *> *v = kps[k].values;
      if (v.count < 1 || (NSInteger)llround(v[0].doubleValue) == type)
        continue;
      NSMutableArray<NSNumber *> *nv = [v mutableCopy];
      nv[0] = @((double)type);
      KKKeyPose *nk = [kps[k] copy]; // preserve time/outgoing/spatial state
      nk.values = nv;
      kps[k] = nk;
      changed = YES;
    }
    if (!changed)
      return nil;
    nl.keyposes = kps;
    lanes[i] = nl;
    t.lanes = lanes;
    return t;
  }
  return nil;
}

NSInteger KKLaneNearestKeyposeIndex(KKLane *lane, double frac) {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  if (kps.count == 0)
    return NSNotFound;
  NSInteger best = 0;
  double bestDt = fabs(kps[0].time - frac);
  for (NSInteger j = 1; j < (NSInteger)kps.count; j++) {
    double dt = fabs(kps[j].time - frac);
    if (dt < bestDt) {
      bestDt = dt;
      best = j;
    }
  }
  return best;
}

KKLane *KKLaneBySettingValuesAtIndex(KKLane *lane, NSInteger index,
                                     NSArray<NSNumber *> *values) {
  KKLane *nl = [lane copy];
  NSMutableArray<KKKeyPose *> *mkps = [nl.keyposes mutableCopy];
  if (index < 0 || index >= (NSInteger)mkps.count)
    return nl;
  // Copy-preserve (not rebuild) so spatialSmooth + in/out handles + outgoing
  // survive a value edit - the "edit resets the path to linear" class of bug.
  KKKeyPose *nk = [mkps[index] copy];
  nk.values = values;
  mkps[index] = nk;
  // Hold-link propagation: a linked interval's two endpoints share one value.
  // Walk the WHOLE linked chain outward from `index` in both directions - not
  // just the immediate neighbour. A multi-segment hold chains several keyposes
  // (e.g. coincident boundary pairs kp1=kp2, kp3=kp4 joined by linked intervals
  // kp1->kp2->kp3->kp4); stopping after one step left the far end stale
  // mid-drag so the motion path drew a phantom segment until a mouse-up
  // reconcile re-synced the chain. The chain stops at the first non-linked
  // interval, so unlinked endpoints (In-start / Out-end) are never touched.
  for (NSInteger i = index;
       i + 1 < (NSInteger)mkps.count && mkps[i].outgoing.endpointsLinked; i++) {
    KKKeyPose *np = [mkps[i + 1] copy];
    np.values = values;
    mkps[i + 1] = np;
  }
  for (NSInteger i = index; i > 0 && mkps[i - 1].outgoing.endpointsLinked;
       i--) {
    KKKeyPose *np = [mkps[i - 1] copy];
    np.values = values;
    mkps[i - 1] = np;
  }
  nl.keyposes = mkps;
  return nl;
}

KKLane *KKLaneBySettingValuesNearestFraction(KKLane *lane, double frac,
                                             NSArray<NSNumber *> *values) {
  if (lane.keyposes.count == 0) {
    KKLane *nl = [lane copy];
    nl.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:values] ];
    return nl;
  }
  return KKLaneBySettingValuesAtIndex(
      lane, KKLaneNearestKeyposeIndex(lane, frac), values);
}

KKTimeline *
KKTimelineSettingValuesNearestFraction(KKTimeline *timeline, NSString *label,
                                       double frac,
                                       NSArray<NSNumber *> *values) {
  KKTimeline *t = [timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].key isEqualToString:label])
      continue;
    lanes[i] = KKLaneBySettingValuesNearestFraction(lanes[i], frac, values);
    t.lanes = lanes;
    return t;
  }
  return nil;
}
