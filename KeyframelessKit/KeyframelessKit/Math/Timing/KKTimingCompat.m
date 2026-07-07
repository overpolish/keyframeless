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

// A keypose at the clip's end: either the frame-aligned park spot
// `endFrac == lastFrameFrac == (clipDur-frameDur)/clipDur` (which can sit well
// below 1.0 for a short clip), or an exact 1.0 end (older / non-frame-aligned
// data). Anything strictly between 0 and the end is an interior boundary.
static BOOL KKAdvIsEnd(double t, double endFrac) {
  return fabs(t - endFrac) <= kBoundaryEps || t >= 1.0 - kBoundaryEps;
}

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

BOOL KKTimelineIsBasicCompatible(KKTimeline *timeline, double endFrac) {
  if (!timeline)
    return YES;
  // `endFrac` is the clip's last-frame fraction (lastFrameFrac); the
  // end-of-clip keypose parks there, NOT at 1.0, so for a short clip it can sit
  // well below the 1/240 "near one" tolerance (e.g. 0.9907 = 107/108). Anchor
  // the endpoint to it. Guard a missing/invalid value back to 1.0 (callers that
  // don't know the clip duration get the legacy near-1.0 behaviour).
  if (endFrac <= 0.0 || endFrac > 1.0)
    endFrac = 1.0;
  NSMutableArray<NSNumber *> *internals = [NSMutableArray array];

  // Every animatable lane must actually span [0, endFrac]: Basic's In/Hold/Out
  // always starts at 0 and ends at the clip's last frame. A lane whose final
  // keypose stops short (e.g. an animation ending mid-clip) - or whose first
  // keypose isn't at the start - is Advanced-only, even if its interior
  // boundary count would otherwise fit.
  for (KKLane *lane in timeline.lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    if (!KKAdvNearZero(lane.keyposes.firstObject.time) ||
        !KKAdvIsEnd(lane.keyposes.lastObject.time, endFrac))
      return NO;
  }

  // First pass: collect every internal (non-0, non-end) keypose time across
  // all animatable lanes; canonicalise duplicates within ε.
  for (KKLane *lane in timeline.lanes) {
    if (!lane.enabled)
      continue;
    for (KKKeyPose *kp in lane.keyposes) {
      double t = kp.time;
      if (KKAdvNearZero(t) || KKAdvIsEnd(t, endFrac))
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
      if (KKAdvNearZero(t) || KKAdvIsEnd(t, endFrac))
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
  if (endFrac <= 0.0 || endFrac > 1.0)
    endFrac = 1.0;
  if (!timeline || KKTimelineIsBasicCompatible(timeline, endFrac))
    return timeline;

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
