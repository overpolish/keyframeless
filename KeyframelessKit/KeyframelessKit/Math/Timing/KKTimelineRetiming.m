/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Timeline retiming free functions: proportional rebalance across a duration
// change, and the media-anchored retime that keeps keyposes pinned to their
// absolute media time. Pure transforms over the public KKTimeline API.

#import "KKTimeline.h"

#import "KKBezierPath.h"
#import "KKEasing.h"
#import "KKPathMorph.h"

KKTimeline *KKTimelineRebalanced(KKTimeline *timeline, double oldDuration,
                                 double newDuration) {
  if (oldDuration <= 0 || newDuration <= 0 || oldDuration == newDuration)
    return timeline;

  KKTimeline *result = [timeline copy];
  NSMutableArray<KKLane *> *newLanes =
      [NSMutableArray arrayWithCapacity:result.lanes.count];

  for (KKLane *lane in result.lanes) {
    KKLane *newLane = [lane copy];
    newLane.lastKnownClipDuration = newDuration;

    NSArray<KKKeyPose *> *kps = lane.keyposes;
    if (kps.count < 2) {
      [newLanes addObject:newLane];
      continue;
    }

    // Compute desired fractional width for each interval.
    NSUInteger intervalCount = kps.count - 1;
    NSMutableArray<NSNumber *> *targetFracs =
        [NSMutableArray arrayWithCapacity:intervalCount];
    double totalLocked = 0.0;
    double totalUnlockedFrac = 0.0;

    for (NSUInteger i = 0; i < intervalCount; i++) {
      KKKeyPose *a = kps[i];
      KKKeyPose *b = kps[i + 1];
      double frac = b.time - a.time;
      double lockedSecs = a.outgoing.lockedSeconds;
      if (lockedSecs > 0) {
        double desiredFrac = lockedSecs / newDuration;
        [targetFracs addObject:@(desiredFrac)];
        totalLocked += desiredFrac;
      } else {
        [targetFracs addObject:@(frac)];
        totalUnlockedFrac += frac;
      }
    }

    // If locked intervals overflow, scale everything proportionally.
    NSMutableArray<NSNumber *> *finalFracs =
        [NSMutableArray arrayWithCapacity:intervalCount];
    double totalSpan = kps.lastObject.time - kps.firstObject.time;
    double available = totalSpan;

    if (totalLocked > available) {
      double scale = available / totalLocked;
      for (NSUInteger i = 0; i < intervalCount; i++) {
        KKKeyPose *a = kps[i];
        if (a.outgoing.lockedSeconds > 0) {
          [finalFracs addObject:@([targetFracs[i] doubleValue] * scale)];
        } else {
          [finalFracs addObject:@(0.0)];
        }
      }
    } else {
      double unlockedAvailable = available - totalLocked;
      for (NSUInteger i = 0; i < intervalCount; i++) {
        KKKeyPose *a = kps[i];
        if (a.outgoing.lockedSeconds > 0) {
          [finalFracs addObject:targetFracs[i]];
        } else {
          double frac = totalUnlockedFrac > 0
                            ? [targetFracs[i] doubleValue] / totalUnlockedFrac *
                                  unlockedAvailable
                            : 0.0;
          [finalFracs addObject:@(frac)];
        }
      }
    }

    // Rebuild keypose times from the first keypose's position.
    NSMutableArray<KKKeyPose *> *newKps =
        [NSMutableArray arrayWithCapacity:kps.count];
    double t = kps.firstObject.time;
    KKKeyPose *firstCopy = [kps.firstObject copy];
    firstCopy.time = t;
    [newKps addObject:firstCopy];
    for (NSUInteger i = 0; i < intervalCount; i++) {
      t += [finalFracs[i] doubleValue];
      KKKeyPose *copy = [kps[i + 1] copy];
      copy.time = MIN(1.0, MAX(0.0, t));
      [newKps addObject:copy];
    }
    newLane.keyposes = newKps;
    [newLanes addObject:newLane];
  }

  result.lanes = newLanes;
  return result;
}

// Builds the coalesced edge keypose: `edge` moved to `newTime` (keeping its
// easing/handles), but with the INTERPOLATED value at the clip boundary when a
// sampler is supplied - `fOrig` is the boundary's fraction in the original
// frame. Without a sampler it keeps `edge`'s raw value.
static KKKeyPose *KKRetimeBoundaryKeypose(KKKeyPose *edge, double newTime,
                                          KKLane *lane, double fOrig,
                                          KKLaneFractionSampler sampler) {
  KKKeyPose *kp = [edge keyposeBySettingTime:newTime];
  if (sampler) {
    NSArray<NSNumber *> *v = sampler(lane, MIN(1.0, MAX(0.0, fOrig)));
    if (v.count)
      kp.values = v;
  }
  return kp;
}

KKTimeline *KKTimelineRetimedForMediaAnchor(KKTimeline *timeline,
                                            double fromSrcIn, double fromDur,
                                            double toSrcIn, double toDur,
                                            KKLaneFractionSampler sampler,
                                            double edgeEps) {
  if (fromDur <= 0 || toDur <= 0)
    return timeline;
  double eps = MAX(0.0, MIN(0.25, edgeEps));

  KKTimeline *result = [timeline copy];
  NSMutableArray<KKLane *> *newLanes =
      [NSMutableArray arrayWithCapacity:result.lanes.count];

  for (KKLane *lane in result.lanes) {
    KKLane *newLane = [lane copy];
    newLane.lastKnownClipDuration = toDur;
    NSArray<KKKeyPose *> *kps = lane.keyposes;
    if (kps.count < 2) {
      [newLanes addObject:newLane];
      continue;
    }

    // Map each keypose to its new fraction `f = (media - toSrcIn)/toDur`. The
    // map is monotonic in `kp.time`, so the keyposes split into a head run
    // (f below the clip start), interior (inside), and a tail run (past the
    // end). Off-edge runs are COALESCED to a single edge keypose instead of
    // piling up (which would leave overlapping keyposes - invalid, the visible
    // trim/split symptom).
    //   - If a REAL keypose sits ON the edge (within `eps`, e.g. a split AT a
    //     keypose), snap THAT one to the edge - keeping its own value + easing,
    //     and NOT also adding a synthesized boundary (the duplicate-keypose
    //     bug). `eps` is ~half a frame.
    //   - Otherwise synthesize one boundary keypose carrying the INTERPOLATED
    //     value at the clip edge (so a split is continuous).
    KKKeyPose *headBelow = nil; // last keypose with f < -eps
    KKKeyPose *headNear = nil;  // last keypose with |f| <= eps
    KKKeyPose *tailNear = nil;  // first keypose with |f-1| <= eps
    KKKeyPose *tailAbove = nil; // first keypose with f > 1+eps
    NSMutableArray<KKKeyPose *> *interior = [NSMutableArray array];
    for (KKKeyPose *kp in kps) {
      double media = fromSrcIn + kp.time * fromDur;
      double f = (media - toSrcIn) / toDur;
      if (f < -eps) {
        headBelow = kp;
      } else if (f <= eps) {
        headNear = kp;
      } else if (f < 1.0 - eps) {
        [interior addObject:[kp keyposeBySettingTime:f]];
      } else if (f <= 1.0 + eps) {
        if (!tailNear)
          tailNear = kp;
      } else if (!tailAbove) {
        tailAbove = kp;
      }
    }

    NSMutableArray<KKKeyPose *> *newKps = [NSMutableArray array];
    if (headNear)
      [newKps addObject:[headNear keyposeBySettingTime:0.0]];
    else if (headBelow)
      [newKps addObject:KKRetimeBoundaryKeypose(headBelow, 0.0, lane,
                                                (toSrcIn - fromSrcIn) / fromDur,
                                                sampler)];
    [newKps addObjectsFromArray:interior];
    if (tailNear)
      [newKps addObject:[tailNear keyposeBySettingTime:1.0]];
    else if (tailAbove)
      [newKps addObject:KKRetimeBoundaryKeypose(
                            tailAbove, 1.0, lane,
                            (toSrcIn + toDur - fromSrcIn) / fromDur, sampler)];
    if (newKps.count == 0)
      [newKps addObject:[kps.firstObject keyposeBySettingTime:0.0]];

    newLane.keyposes = newKps;
    [newLanes addObject:newLane];
  }

  result.lanes = newLanes;
  return result;
}
