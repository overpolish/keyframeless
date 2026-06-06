/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineBasicView_Private.h"

#import "KKKeyposeSymbol.h"
#import "KKMiniViewerView.h"
#import "KKSegmentEditView.h"
#import "KKTimelineScale.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

@implementation KKTimelineBasicView (Model)

// Current Hold (settled) value of a lane, independent of which phases it has.
- (NSArray<NSNumber *> *)_holdValuesForLane:(KKLane *)lane {
  NSArray<KKKeyPose *> *k = lane.keyposes;
  if (k.count == 0) {
    for (KKLane *t in _availableLanes)
      if ([t.label isEqualToString:lane.label] &&
          t.keyposes.firstObject.values.count)
        return t.keyposes.firstObject.values;
    return @[ @0.0 ];
  }
  if (k.count == 1)
    return k[0].values;
  return k[KKShapeOfLane(lane).holdStart].values;
}

// The always-present Hold interval (between the two Hold keyposes); nil only
// if the lane hasn't been expanded to the ≥2-keypose shape yet.
- (KKInterval *)_holdIntervalForLane:(KKLane *)lane {
  if (lane.keyposes.count < 2)
    return nil;
  return lane.keyposes[KKShapeOfLane(lane).holdStart].outgoing;
}

BOOL KKValuesEqual(NSArray<NSNumber *> *a, NSArray<NSNumber *> *b) {
  if (a.count != b.count)
    return NO;
  for (NSUInteger i = 0; i < a.count; i++)
    if (fabs(a[i].doubleValue - b[i].doubleValue) > 1e-6)
      return NO;
  return YES;
}

// The Hold pair is "linked" when its interval says so (Basic holds start
// linked). Read from the first enabled lane that has the linkable shape.
- (BOOL)_holdLinked {
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled)
      continue;
    KKInterval *iv = [self _holdIntervalForLane:lane];
    if (iv)
      return iv.endpointsLinked;
  }
  return YES;
}

// "Drift": the two interior Hold keyposes actually carry different values
// on some enabled lane (only possible while unlinked).
- (BOOL)_holdDrift {
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    if (s.holdEnd > s.holdStart &&
        !KKValuesEqual(lane.keyposes[s.holdStart].values,
                       lane.keyposes[s.holdEnd].values))
      return YES;
  }
  return NO;
}

// A phase is a real transition only when some enabled lane's phase endpoints
// actually differ (value-based, matching Advanced's per-keypose rule). A
// freshly enabled In/Out seeds its endpoint to the hold value, so it stays
// accent until the user gives it a distinct value.
- (BOOL)_inIsTransition {
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    if (!s.inEnabled || lane.keyposes.firstObject.outgoing.holdsFlat)
      continue; // no In keypose, or applies-to off (flat) → not animating
    if (!KKValuesEqual(lane.keyposes.firstObject.values,
                       lane.keyposes[s.holdStart].values))
      return YES;
  }
  return NO;
}

- (BOOL)_outIsTransition {
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    if (!s.outEnabled || lane.keyposes[s.holdEnd].outgoing.holdsFlat)
      continue;
    if (!KKValuesEqual(lane.keyposes[s.holdEnd].values,
                       lane.keyposes.lastObject.values))
      return YES;
  }
  return NO;
}

// Toggle the Hold link across every enabled 4-keypose lane. Linking back on
// collapses any drift to a single shared value (the hold-start value) so it
// is a true Hold again.
- (void)_toggleHoldLink {
  BOOL newLinked = ![self _holdLinked];
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    if (s.holdEnd <= s.holdStart)
      continue;
    KKLane *nl = [lane copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    KKKeyPose *b = [kps[s.holdStart] copy];
    KKKeyPose *c = [kps[s.holdEnd] copy];
    KKInterval *iv = [b.outgoing copy] ?: [[KKInterval alloc] init];
    iv.endpointsLinked = newLinked;
    // A drift is a real tween from hold-start to hold-end - start it linear
    // (the EaseInOut default belongs to In/Out, not a freshly split Hold).
    if (!newLinked)
      iv.curve = KKIntervalCurveLinear;
    b.outgoing = iv;
    if (newLinked)
      c.values = b.values;
    c.outgoing = kps[s.holdEnd].outgoing;
    kps[s.holdStart] = b;
    kps[s.holdEnd] = c;
    nl.keyposes = kps;
    lanes[i] = nl;
  }
  t.lanes = lanes;
  _timeline = t;
  self.needsLayout = YES;
  [self layoutSubtreeIfNeeded]; // flush now so the Hold/Drift label
                                // refreshes in lockstep with the curve
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Carry the spatial-curve state (smoothness + bezier handles) from a source
// keypose onto a freshly rebuilt one. The Basic In/Out rebuild constructs new
// keyposes from scratch; without this a boundary change would silently reset
// every Position keypose to linear.
static void KKBasicCopySpatial(KKKeyPose *dst, KKKeyPose *_Nullable src) {
  if (!dst || !src)
    return;
  dst.spatialSmooth = src.spatialSmooth;
  dst.inHandle = src.inHandle;
  dst.outHandle = src.outHandle;
}

// Rebuild one animatable lane's keyposes for the requested In/Out phases.
// New model: hold-pair sits at [0, outEndFrac] when neither phase is on;
// enabling In moves the hold-start to tIn and adds an in-start at 0; Out
// moves the hold-end to tOut and adds an out-end at outEndFrac. Counts
// 2/3/3/4. Every keypose value defaults to the Hold (constant) value so a
// freshly-animatable property has every phase seeded to its constant rather
// than a stray 0. Existing In-start / Out-end values and the In / Hold /
// Out intervals (curve, intensity, frequency, modulation, link) preserved.
- (KKLane *)_rebuiltLane:(KKLane *)lane
                    inOn:(BOOL)inOn
                   outOn:(BOOL)outOn
                     tIn:(double)tIn
                    tOut:(double)tOut {
  NSArray<NSNumber *> *hold = [self _holdValuesForLane:lane];
  NSArray<KKKeyPose *> *old = lane.keyposes;
  KKHoldShape os = KKShapeOfLane(lane);
  NSArray<NSNumber *> *inStart = os.inEnabled ? old.firstObject.values : hold;
  NSArray<NSNumber *> *outEnd = os.outEnabled ? old.lastObject.values : hold;
  // Preserve drift: when the existing Hold endpoints carry different
  // values (unlinked / drift), keep them on rebuild. Falling back to the
  // shared `hold` value collapsed drift on every boundary drag.
  NSArray<NSNumber *> *holdStartVals =
      (old.count >= 2) ? old[os.holdStart].values : hold;
  NSArray<NSNumber *> *holdEndVals =
      (old.count >= 2) ? old[os.holdEnd].values : hold;

  KKInterval *oldHold = (old.count >= 2) ? old[os.holdStart].outgoing : nil;
  KKInterval *oldIn = os.inEnabled ? old.firstObject.outgoing : nil;
  KKInterval *oldOut = os.outEnabled ? old[os.holdEnd].outgoing : nil;

  // FCP's playhead stops one frame before clipEnd, so storing the hold/out
  // end at exactly 1.0 makes it unreachable. Use (clipDur-frameDur)/clipDur
  // when known; fall back to 1.0 cold-start.
  double outEndFrac = 1.0;
  double clipDur = [self _clipDuration];
  if (clipDur > 0.0 && _frameDurationSeconds > 0.0 &&
      _frameDurationSeconds < clipDur)
    outEndFrac = (clipDur - _frameDurationSeconds) / clipDur;

  NSMutableArray<KKKeyPose *> *kps = [NSMutableArray array];
  if (inOn) {
    KKKeyPose *a = [KKKeyPose keyposeAtTime:0.0 values:inStart];
    a.outgoing = [oldIn copy] ?: [[KKInterval alloc] init];
    KKBasicCopySpatial(a, os.inEnabled ? old.firstObject : nil);
    [kps addObject:a];
  }
  KKKeyPose *hs =
      [KKKeyPose keyposeAtTime:(inOn ? tIn : 0.0) values:holdStartVals];
  hs.outgoing = [oldHold copy];
  if (!hs.outgoing) {
    // A freshly built Basic Hold starts linked (the two interior keyposes move
    // together); the In/Out intervals stay unlinked (model default).
    KKInterval *freshHold = [[KKInterval alloc] init];
    freshHold.endpointsLinked = YES;
    hs.outgoing = freshHold;
  }
  KKBasicCopySpatial(hs, (old.count >= 2) ? old[os.holdStart] : nil);
  [kps addObject:hs];
  KKKeyPose *he =
      [KKKeyPose keyposeAtTime:(outOn ? tOut : outEndFrac) values:holdEndVals];
  KKBasicCopySpatial(he, (old.count >= 2) ? old[os.holdEnd] : nil);
  [kps addObject:he];
  if (outOn) {
    he.outgoing = [oldOut copy] ?: [[KKInterval alloc] init];
    KKKeyPose *oe = [KKKeyPose keyposeAtTime:outEndFrac values:outEnd];
    KKBasicCopySpatial(oe, os.outEnabled ? old.lastObject : nil);
    [kps addObject:oe];
  }

  KKLane *nl = [lane copy];
  nl.keyposes = kps;
  // Pin the projection's interpretation so the keypose-count + middle-time
  // heuristic can't second-guess us mid-drag.
  if (inOn && outOn)
    nl.holdShape = KKLaneHoldShapeBoth;
  else if (inOn)
    nl.holdShape = KKLaneHoldShapeInOnly;
  else if (outOn)
    nl.holdShape = KKLaneHoldShapeOutOnly;
  else
    nl.holdShape = KKLaneHoldShapeNone;
  return nl;
}

- (void)_rebuildInOn:(BOOL)inOn
               outOn:(BOOL)outOn
                 tIn:(double)tIn
                tOut:(double)tOut {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++)
    if (lanes[i].enabled)
      lanes[i] = [self _rebuiltLane:lanes[i]
                               inOn:inOn
                              outOn:outOn
                                tIn:tIn
                               tOut:tOut];
  t.lanes = lanes;
  _timeline = t;
  [self _restoreCheckboxes];
  self.needsLayout = YES;
  [self layoutSubtreeIfNeeded]; // flush now so the Hold/Drift label
                                // refreshes in lockstep with the curve
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

- (void)_applyInEnabled:(BOOL)inOn outEnabled:(BOOL)outOn {
  KKBasicProj p = [self _projection];
  double tIn = p.inEnabled ? p.inEndFrac : kDefaultInEnd;
  double tOut = p.outEnabled ? p.outStartFrac : kDefaultOutStart;
  if (tIn >= tOut) {
    tIn = kDefaultInEnd;
    tOut = kDefaultOutStart;
  }
  [self _rebuildInOn:inOn outOn:outOn tIn:tIn tOut:tOut];
}

// Master In/Out checkbox is structural: on adds the phase's start keyposes,
// off removes them. Per-property exclusion uses holdsFlat (non-destructive),
// but the *fully-off* phase has no keyposes - and removing the last applier
// (in _setLaneParticipation) routes here so the disabled state is consistent.
- (void)_setInEnabled:(BOOL)on {
  [self _applyInEnabled:on outEnabled:[self _projection].outEnabled];
}

- (void)_setOutEnabled:(BOOL)on {
  [self _applyInEnabled:[self _projection].inEnabled outEnabled:on];
}

@end
