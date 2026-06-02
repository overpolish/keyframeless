/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimingCompat.h"
#import "KKTimingEvaluation.h"

// Time tolerance for "same boundary". One frame at 240 fps is well below any
// snap threshold the editors use and matches the duplicate-insert ε in
// KKTimelineAdvancedView.
static const double kBoundaryEps = 1.0 / 240.0;
static const double kValueEps = 1.0e-4;

static BOOL KKAdvNearZero(double t) { return t <= kBoundaryEps; }
static BOOL KKAdvNearOne(double t) { return t >= 1.0 - kBoundaryEps; }

static BOOL KKValuesEqual(NSArray<NSNumber *> *a, NSArray<NSNumber *> *b) {
  if (a.count != b.count)
    return NO;
  for (NSUInteger i = 0; i < a.count; i++)
    if (fabs(a[i].doubleValue - b[i].doubleValue) > kValueEps)
      return NO;
  return YES;
}

// Snap `t` to an existing internal time within ε, returning that canonical
// value; otherwise append `t` as a new internal time.
static double KKCanonicalInternal(double t, NSMutableArray<NSNumber *> *acc) {
  for (NSNumber *n in acc) {
    if (fabs(n.doubleValue - t) <= kBoundaryEps)
      return n.doubleValue;
  }
  [acc addObject:@(t)];
  return t;
}

BOOL KKTimelineIsBasicCompatible(KKTimeline *timeline) {
  if (!timeline)
    return YES;
  NSMutableArray<NSNumber *> *internals = [NSMutableArray array];

  // First pass: collect every internal (non-0, non-1) keypose time across
  // all animatable lanes; canonicalise duplicates within ε.
  for (KKLane *lane in timeline.lanes) {
    if (!lane.enabled)
      continue;
    for (KKKeyPose *kp in lane.keyposes) {
      double t = kp.time;
      if (KKAdvNearZero(t) || KKAdvNearOne(t))
        continue;
      KKCanonicalInternal(t, internals);
    }
  }
  // Basic supports at most two internal boundaries (t_inEnd, t_outStart).
  if (internals.count > 2)
    return NO;
  [internals sortUsingSelector:@selector(compare:)];

  // Basic's projection is shared across lanes - `inEnabled`/`outEnabled`
  // toggle the same boundaries on every animatable lane. So any internal
  // boundary that appears in *one* lane must appear in *every* lane (PLAN:
  // "consistent boundary times exist such that every animatable lane's
  // keyposes are a subset of {0, t_inEnd, t_outStart, 1}"). A lane with
  // extra or missing internal KPs relative to the global set isn't
  // representable in Basic.
  for (KKLane *lane in timeline.lanes) {
    if (!lane.enabled)
      continue;
    NSInteger laneInternalCount = 0;
    for (KKKeyPose *kp in lane.keyposes) {
      double t = kp.time;
      if (KKAdvNearZero(t) || KKAdvNearOne(t))
        continue;
      laneInternalCount++;
      // Each internal KP must match a canonical global boundary.
      BOOL matched = NO;
      for (NSNumber *n in internals)
        if (fabs(n.doubleValue - t) <= kBoundaryEps) {
          matched = YES;
          break;
        }
      if (!matched)
        return NO;
    }
    // No missing internals: lane must have a KP at every global boundary.
    if (laneInternalCount != (NSInteger)internals.count)
      return NO;
  }

  if (internals.count < 2)
    return YES;

  double tIn = internals[0].doubleValue;
  double tOut = internals[1].doubleValue;

  // Hold interval (between t_inEnd and t_outStart) must hold flat - PLAN
  // requires equal endpoint values; modulation on the interval is allowed
  // and isn't checked here.
  for (KKLane *lane in timeline.lanes) {
    if (!lane.enabled)
      continue;
    KKKeyPose *atIn = nil;
    KKKeyPose *atOut = nil;
    for (KKKeyPose *kp in lane.keyposes) {
      if (fabs(kp.time - tIn) <= kBoundaryEps)
        atIn = kp;
      else if (fabs(kp.time - tOut) <= kBoundaryEps)
        atOut = kp;
    }
    if (atIn && atOut && !KKValuesEqual(atIn.values, atOut.values))
      return NO;
  }
  return YES;
}

KKTimeline *KKTimelineReseedToBasic(KKTimeline *timeline, double endFrac) {
  if (!timeline || KKTimelineIsBasicCompatible(timeline))
    return timeline;
  if (endFrac <= 0.0 || endFrac > 1.0)
    endFrac = 1.0;

  // Basic's projection is uniform across lanes - partial reseeds leave
  // siblings misaligned at the global boundaries and the timeline stays
  // incompatible. Per the user-chosen "flat hold at midpoint" strategy,
  // collapse every animatable lane to a two-keypose flat hold; lanes the
  // user wasn't animating (disabled) are untouched.
  KKTimeline *out = [timeline copy];
  NSMutableArray<KKLane *> *newLanes = [out.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)newLanes.count; i++) {
    KKLane *lane = newLanes[i];
    if (!lane.enabled)
      continue;
    NSArray<NSNumber *> *midVals = KKTimelineLaneValueAtFraction(lane, 0.5);
    if (!midVals) {
      KKKeyPose *first = lane.keyposes.firstObject;
      midVals = first.values ?: @[ @0.0 ];
    }
    KKLane *nl = [lane copy];
    nl.keyposes = @[
      [KKKeyPose keyposeAtTime:0.0 values:midVals],
      [KKKeyPose keyposeAtTime:endFrac values:midVals],
    ];
    nl.holdShape = KKLaneHoldShapeNone;
    newLanes[i] = nl;
  }
  out.lanes = newLanes;
  return out;
}
