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
      double frac = MAX(0.0, b.time - a.time);
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

    // Locked gaps normally retain their requested seconds while unlocked gaps
    // divide the remainder proportionally. If the requested locks cannot all
    // fit, preserve them by priority: transitions before holds, then timeline
    // order. A lower-priority lock can temporarily compress to zero, but its
    // stored lockedSeconds is untouched so it recovers when the clip grows.
    NSMutableArray<NSNumber *> *finalFracs =
        [NSMutableArray arrayWithCapacity:intervalCount];
    double totalSpan = kps.lastObject.time - kps.firstObject.time;
    double available = totalSpan;

    if (totalLocked > available) {
      for (NSUInteger i = 0; i < intervalCount; i++)
        [finalFracs addObject:@(0.0)];
      double remaining = available;
      for (NSInteger transitionPass = 1; transitionPass >= 0; transitionPass--)
        for (NSUInteger i = 0; i < intervalCount && remaining > 0.0; i++) {
          KKKeyPose *a = kps[i], *b = kps[i + 1];
          if (a.outgoing.lockedSeconds <= 0.0)
            continue;
          BOOL transition = !KKLaneKeyposeValuesEqual(newLane, a, b);
          if (transition != (BOOL)transitionPass)
            continue;
          double granted = MIN([targetFracs[i] doubleValue], remaining);
          finalFracs[i] = @(granted);
          remaining -= granted;
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
      // Every interval is locked: no flexible gap exists to absorb growth.
      // Put the surplus into the lowest-priority (latest hold, otherwise latest
      // transition) without changing its stored lock request.
      if (totalUnlockedFrac <= 0.0 && unlockedAvailable > 0.0) {
        NSInteger fallback = -1;
        for (NSInteger i = (NSInteger)intervalCount - 1; i >= 0; i--)
          if (kps[i].outgoing.lockedSeconds > 0.0 &&
              KKLaneKeyposeValuesEqual(newLane, kps[i], kps[i + 1])) {
            fallback = i;
            break;
          }
        if (fallback < 0)
          fallback = (NSInteger)intervalCount - 1;
        finalFracs[fallback] =
            @([finalFracs[fallback] doubleValue] + unlockedAvailable);
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

KKTimeline *KKTimelineRetimedForMaintainTiming(
    KKTimeline *timeline, double fromSrcIn, double fromDur, double toSrcIn,
    double toDur, KKLaneFractionSampler sampler, double edgeEps) {
  KKTimeline *media = KKTimelineRetimedForMediaAnchor(
      timeline, fromSrcIn, fromDur, toSrcIn, toDur, sampler, edgeEps);
  BOOL anyLocked = NO;
  for (KKLane *lane in timeline.lanes)
    if (KKLaneHasDurationLocks(lane)) {
      anyLocked = YES;
      break;
    }
  if (!anyLocked)
    return media;

  KKTimeline *balanced = KKTimelineRebalanced(timeline, fromDur, toDur);
  KKTimeline *result = [media copy];
  NSMutableArray<KKLane *> *lanes = [result.lanes mutableCopy];
  NSUInteger count = MIN(timeline.lanes.count, balanced.lanes.count);
  for (NSUInteger i = 0; i < count; i++)
    if (KKLaneHasDurationLocks(timeline.lanes[i]))
      lanes[i] = balanced.lanes[i];
  result.lanes = lanes;
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
