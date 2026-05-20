/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineBasicView_Private.h"

#import "../Math/KKTimelineScale.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKKeyposeSymbol.h"
#import "KKMiniCanvasView.h"
#import "KKSegmentEditView.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

@implementation KKTimelineBasicView (Popovers)

// The In / Out interval shared by every animatable lane: In is the t=0
// keypose's outgoing interval, Out the second-to-last keypose's. Builds the
// KKSegmentEditView (Transition) popover via the host and routes curve /
// intensity / frequency edits back across all animatable lanes.
- (void)_openGapPopoverForSection:(KKBasicSection)sec {
  if (_onGapTapped)
    _onGapTapped((NSInteger)sec);
  if (!self.onGapPopover)
    return;
  KKBasicProj p = [self _projection];
  NSRect g = [self _graphRect];
  if (NSWidth(g) <= 0.0)
    return;
  BOOL isOut = (sec == KKBasicSectionOut);
  if (isOut ? !p.outEnabled : !p.inEnabled)
    return;

  double midFrac = isOut ? (p.outStartFrac + 1.0) / 2.0 : p.inEndFrac / 2.0;
  double lo = 0.0, hi = 1.0;
  KKBasicValueExtent(p, &lo, &hi);
  NSPoint c = KKBasicPoint(g, midFrac, 0.5, lo, hi, p);
  if (!_popoverAnchor) {
    _popoverAnchor = [[NSView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_popoverAnchor positioned:NSWindowBelow relativeTo:nil];
  }
  _popoverAnchor.frame = NSMakeRect(c.x - kDiamondR, c.y - kDiamondR,
                                    2 * kDiamondR, 2 * kDiamondR);

  KKIntervalCurve cur = (KKIntervalCurve)(isOut ? p.outCurve : p.inCurve);
  double inten = isOut ? p.outIntensity : p.inIntensity;
  double freq = isOut ? p.outFrequency : p.inFrequency;

  // Per-property participation in THIS phase: each animatable lane + whether
  // it currently has the In (t=0) / Out (t=1) keypose.
  NSMutableArray<NSString *> *partLabels = [NSMutableArray array];
  NSMutableArray<NSNumber *> *partStates = [NSMutableArray array];
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    [partLabels addObject:lane.label];
    [partStates addObject:@(isOut ? s.outEnabled : s.inEnabled)];
  }

  __weak typeof(self) weak = self;
  KKBasicSection capSec = sec;
  self.onGapPopover(
      _popoverAnchor, isOut, cur, inten, freq, partLabels, partStates,
      ^(KKIntervalCurve c2) {
        [weak _mutateInterval:capSec
                         with:^(KKInterval *iv) {
                           iv.curve = c2;
                         }];
      },
      ^(double v) {
        [weak _mutateInterval:capSec
                         with:^(KKInterval *iv) {
                           iv.intensity = v;
                         }];
      },
      ^(double v) {
        [weak _mutateInterval:capSec
                         with:^(KKInterval *iv) {
                           iv.frequency = v;
                         }];
      },
      ^(NSInteger laneIndex, BOOL on) {
        if (laneIndex >= 0 && laneIndex < (NSInteger)partLabels.count)
          [weak _setLaneParticipation:on
                             forLabel:partLabels[laneIndex]
                              section:capSec];
      },
      self.onDragBegin, self.onDragEnd);
}

// Per-lane phase participation: rebuild just this lane so it gains/loses its
// In (t=0) or Out (t=1) keypose, keeping its always-present Hold pair, the
// other endpoint, and all intervals (via _rebuiltLane:). Uses the lane's own
// stored Hold-pair times so its boundaries are preserved.
- (void)_setLaneParticipation:(BOOL)on
                     forLabel:(NSString *)label
                      section:(KKBasicSection)sec {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (!lane.enabled || ![lane.label isEqualToString:label] ||
        lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    BOOL inOn = (sec == KKBasicSectionOut) ? s.inEnabled : on;
    BOOL outOn = (sec == KKBasicSectionOut) ? on : s.outEnabled;
    double tIn = lane.keyposes[s.holdStart].time;
    double tOut = lane.keyposes[s.holdEnd].time;
    lanes[i] = [self _rebuiltLane:lane inOn:inOn outOn:outOn tIn:tIn tOut:tOut];
    break;
  }
  t.lanes = lanes;
  _timeline = t;
  self.needsLayout = YES;
  [self layoutSubtreeIfNeeded];
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// The shared Hold interval only exists in the full In+Hold+Out shape. A flat
// Hold opens the modulation editor; a drift (interior keyposes differ) opens
// the easing editor, since a drift is a real tween from hold-start to
// hold-end. (Modulation on a Hold-only / In-only / Out-only property needs
// the 2-equal-keypose carrier — deferred with the In/Out enable work.)
- (void)_openHoldPopover {
  KKBasicProj p = [self _projection];
  NSRect g = [self _graphRect];
  if (NSWidth(g) <= 0.0 || !p.anyAnimatable)
    return;

  double midFrac = (p.inEndFrac + p.outStartFrac) / 2.0;
  double lo = 0.0, hi = 1.0;
  KKBasicValueExtent(p, &lo, &hi);
  NSPoint c = KKBasicPoint(g, midFrac, KKBasicMotionY(midFrac, p), lo, hi, p);
  if (!_popoverAnchor) {
    _popoverAnchor = [[NSView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_popoverAnchor positioned:NSWindowBelow relativeTo:nil];
  }
  _popoverAnchor.frame = NSMakeRect(c.x - kDiamondR, c.y - kDiamondR,
                                    2 * kDiamondR, 2 * kDiamondR);
  __weak typeof(self) weak = self;

  // Per-property participation for the Hold popover: which animatable
  // properties the Hold modulation/drift applies to. For drift, a lane
  // participates when its Hold interval is unlinked (drift-capable).
  NSMutableArray<NSString *> *holdLabels = [NSMutableArray array];
  NSMutableArray<NSNumber *> *driftStates = [NSMutableArray array];
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKInterval *liv = lane.keyposes[KKShapeOfLane(lane).holdStart].outgoing;
    [holdLabels addObject:lane.label];
    [driftStates addObject:@(liv && !liv.endpointsLinked)];
  }

  if (p.holdDrift) {
    if (!self.onGapPopover)
      return;
    self.onGapPopover(
        _popoverAnchor, NO, (KKIntervalCurve)p.holdCurve, p.holdIntensity,
        p.holdFrequency, holdLabels, driftStates,
        ^(KKIntervalCurve c2) {
          [weak _mutateInterval:KKBasicSectionHold
                           with:^(KKInterval *iv) {
                             iv.curve = c2;
                           }];
        },
        ^(double v) {
          [weak _mutateInterval:KKBasicSectionHold
                           with:^(KKInterval *iv) {
                             iv.intensity = v;
                           }];
        },
        ^(double v) {
          [weak _mutateInterval:KKBasicSectionHold
                           with:^(KKInterval *iv) {
                             iv.frequency = v;
                           }];
        },
        ^(NSInteger laneIndex, BOOL on) {
          if (laneIndex < 0 || laneIndex >= (NSInteger)holdLabels.count)
            return;
          [weak _setHoldDriftApplied:on forLabel:holdLabels[laneIndex]];
          // Collapsing the last drift back to a flat Hold means this
          // popover (the easing editor) is now the wrong one — swap to
          // the modulation editor in place.
          if (![weak _holdDrift])
            [weak _openHoldPopover];
        },
        self.onDragBegin, self.onDragEnd);
    return;
  }

  if (!self.onHoldModulationPopover)
    return;
  KKInterval *hv = nil;
  for (KKLane *lane in _timeline.lanes)
    if (lane.enabled && lane.keyposes.count >= 2) {
      hv = lane.keyposes[KKShapeOfLane(lane).holdStart].outgoing;
      break;
    }
  KKIntervalModulation mod = hv ? hv.modulation : KKIntervalModulationNone;
  double mInten = hv ? hv.modulationIntensity : 1.0;
  double mFreq = hv ? hv.modulationFrequency : 1.0;
  uint32_t seed = hv ? hv.modulationSeed : 0;
  BOOL linked = hv ? hv.modulationLinked : YES;
  BOOL showsLinked = NO;
  NSMutableArray<NSString *> *partLabels = [NSMutableArray array];
  NSMutableArray<NSNumber *> *partStates = [NSMutableArray array];
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    if (lane.keyposes.firstObject.values.count > 1)
      showsLinked = YES;
    KKInterval *liv = lane.keyposes[KKShapeOfLane(lane).holdStart].outgoing;
    [partLabels addObject:lane.label];
    [partStates addObject:@(liv && liv.modulation != KKIntervalModulationNone)];
  }
  self.onHoldModulationPopover(
      _popoverAnchor, mod, mInten, mFreq, seed, linked, showsLinked, partLabels,
      partStates,
      ^(KKIntervalModulation m) {
        [weak _mutateHoldModWith:^(KKInterval *iv) {
          iv.modulation = m;
        }];
      },
      ^(double v) {
        [weak _mutateHoldModWith:^(KKInterval *iv) {
          iv.modulationIntensity = v;
        }];
      },
      ^(double v) {
        [weak _mutateHoldModWith:^(KKInterval *iv) {
          iv.modulationFrequency = v;
        }];
      },
      ^(uint32_t s) {
        [weak _mutateHoldModWith:^(KKInterval *iv) {
          iv.modulationSeed = s;
        }];
      },
      ^(BOOL l) {
        [weak _mutateHoldModWith:^(KKInterval *iv) {
          iv.modulationLinked = l;
        }];
      },
      ^(NSInteger laneIndex, BOOL on) {
        if (laneIndex >= 0 && laneIndex < (NSInteger)partLabels.count)
          [weak _setHoldModApplied:on forLabel:partLabels[laneIndex]];
      },
      self.onDragBegin, self.onDragEnd);
}

// Hold-modulation param edits apply only to lanes the modulation is ON for
// (Hold interval modulation != None) so tweaking a param never silently
// re-enables an excluded lane. If none participate yet, target all
// animatable lanes — picking a type from the None state turns it on for all
// (the user then unticks individual properties).
- (void)_mutateHoldModWith:(void (^)(KKInterval *iv))mut {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL anyParticipating = NO;
  for (KKLane *lane in lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKInterval *iv = lane.keyposes[KKShapeOfLane(lane).holdStart].outgoing;
    if (iv && iv.modulation != KKIntervalModulationNone) {
      anyParticipating = YES;
      break;
    }
  }
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    KKInterval *cur = lane.keyposes[s.holdStart].outgoing;
    if (anyParticipating &&
        (!cur || cur.modulation == KKIntervalModulationNone))
      continue; // excluded — leave it None
    KKLane *nl = [lane copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    KKKeyPose *kp = [kps[s.holdStart] copy];
    KKInterval *iv = [kp.outgoing copy] ?: [[KKInterval alloc] init];
    mut(iv);
    kp.outgoing = iv;
    kps[s.holdStart] = kp;
    nl.keyposes = kps;
    lanes[i] = nl;
  }
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Toggle whether the Hold modulation applies to one lane. On → copy the
// shared type/params onto its Hold interval (defaulting to Wiggle if no
// type chosen yet); off → modulation None (curve/intensity kept for drift).
- (void)_setHoldModApplied:(BOOL)on forLabel:(NSString *)label {
  KKBasicProj p = [self _projection];
  KKIntervalModulation type = (p.holdMod != KKIntervalModulationNone)
                                  ? p.holdMod
                                  : KKIntervalModulationWiggle;
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (!lane.enabled || ![lane.label isEqualToString:label] ||
        lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    KKLane *nl = [lane copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    KKKeyPose *kp = [kps[s.holdStart] copy];
    KKInterval *iv = [kp.outgoing copy] ?: [[KKInterval alloc] init];
    if (on) {
      iv.modulation = type;
      iv.modulationIntensity = p.holdModIntensity;
      iv.modulationFrequency = p.holdModFrequency;
      iv.modulationSeed = p.holdModSeed;
    } else {
      iv.modulation = KKIntervalModulationNone;
    }
    kp.outgoing = iv;
    kps[s.holdStart] = kp;
    nl.keyposes = kps;
    lanes[i] = nl;
    break;
  }
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Toggle whether one lane participates in the Hold drift. On → unlink its
// Hold interval (drift-capable, starts linear; the user then edits its
// hold-end value); off → relink and collapse hold-end back to hold-start so
// it's a flat hold again.
- (void)_setHoldDriftApplied:(BOOL)on forLabel:(NSString *)label {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (!lane.enabled || ![lane.label isEqualToString:label] ||
        lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    if (s.holdEnd <= s.holdStart)
      continue;
    KKLane *nl = [lane copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    KKKeyPose *b = [kps[s.holdStart] copy];
    KKKeyPose *c = [kps[s.holdEnd] copy];
    KKInterval *iv = [b.outgoing copy] ?: [[KKInterval alloc] init];
    iv.endpointsLinked = !on;
    if (on)
      iv.curve = KKIntervalCurveLinear; // a fresh drift starts linear
    b.outgoing = iv;
    if (!on) // relink → flatten: hold-end mirrors hold-start
      c = [KKKeyPose keyposeAtTime:c.time values:b.values];
    c.outgoing = kps[s.holdEnd].outgoing;
    kps[s.holdStart] = b;
    kps[s.holdEnd] = c;
    nl.keyposes = kps;
    lanes[i] = nl;
    break;
  }
  t.lanes = lanes;
  _timeline = t;
  self.needsLayout = YES;
  [self layoutSubtreeIfNeeded];
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Apply `mut` to the In / Hold / Out interval of every animatable lane —
// Basic shares one In easing, one Out easing, one Hold (modulation/drift) —
// then fire onTimelineMutated. The live BasicView redraw is local
// (setNeedsDisplay re-reads from the projection); the host coalesces the
// per-tick blob writes into the slider drag's undo group.
- (void)_mutateInterval:(KKBasicSection)section
                   with:(void (^)(KKInterval *iv))mut {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    NSArray<KKKeyPose *> *kps = lane.keyposes;
    KKHoldShape s = KKShapeOfLane(lane);
    NSInteger idx;
    if (section == KKBasicSectionOut) {
      if (!s.outEnabled)
        continue;      // this lane has no Out phase
      idx = s.holdEnd; // keypose before t=1 carries the Out interval
    } else if (section == KKBasicSectionHold) {
      idx = s.holdStart; // Hold interval — always present
    } else {
      if (!s.inEnabled)
        continue; // this lane has no In phase
      idx = 0;
    }
    KKLane *nl = [lane copy];
    NSMutableArray<KKKeyPose *> *nkps = [kps mutableCopy];
    KKKeyPose *kp = [nkps[idx] copy];
    KKInterval *iv = [kp.outgoing copy] ?: [[KKInterval alloc] init];
    mut(iv);
    kp.outgoing = iv;
    nkps[idx] = kp;
    nl.keyposes = nkps;
    lanes[i] = nl;
  }
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

- (void)_openBoundaryPopoverForDiamond:(NSInteger)d {
  if (_onDiamondTapped)
    _onDiamondTapped(d);
  if (!self.onBoundaryValuePopover)
    return;
  KKBasicProj p = [self _projection];
  NSRect g = [self _graphRect];
  if (NSWidth(g) <= 0)
    return;

  KKBasicBoundary boundary;
  double frac;
  if (d == 1)
    boundary = p.inEnabled ? KKBasicBoundaryInStart : KKBasicBoundaryHold;
  else if (d == 4)
    boundary = p.outEnabled ? KKBasicBoundaryOutEnd : KKBasicBoundaryHold;
  else
    boundary = KKBasicBoundaryHold;

  if (boundary == KKBasicBoundaryInStart)
    frac = 0.0;
  else if (boundary == KKBasicBoundaryOutEnd)
    frac = 1.0;
  else if (d == 2)
    frac = p.inEndFrac;
  else if (d == 3)
    frac = p.outStartFrac;
  else
    frac = p.inEnabled ? p.inEndFrac : (p.outEnabled ? p.outStartFrac : 0.0);

  // Build synthetic single-keypose lanes carrying the value at this boundary
  // — with valueType / component bounds taken from the plugin template
  // (canonical), exactly like _timelineSeededFrom:, so the reused
  // static-values rows pick the right editor (Radius float 0–100, Crop grid).
  NSMutableArray<KKLane *> *displayLanes = [NSMutableArray array];
  NSMutableArray<NSString *> *excludedLabels = [NSMutableArray array];
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled)
      continue;
    // A property that doesn't participate in this boundary's phase has no
    // keypose here — flag it excluded (its row becomes a message + Animate,
    // in place, so the original property order is preserved). Hold always
    // participates (the Hold pair always exists).
    if (lane.keyposes.count >= 2) {
      KKHoldShape sh = KKShapeOfLane(lane);
      BOOL participates =
          boundary == KKBasicBoundaryInStart
              ? sh.inEnabled
              : (boundary == KKBasicBoundaryOutEnd ? sh.outEnabled : YES);
      if (!participates)
        [excludedLabels addObject:lane.label];
    }
    NSArray<NSNumber *> *vals = KKTimelineLaneValueAtFraction(lane, frac)
                                    ?: lane.keyposes.firstObject.values;
    KKLane *tmpl = nil;
    for (KKLane *t in _availableLanes)
      if ([t.label isEqualToString:lane.label]) {
        tmpl = t;
        break;
      }
    KKLane *dl = [KKLane laneWithLabel:lane.label];
    dl.valueType = tmpl ? tmpl.valueType : lane.valueType;
    dl.componentMin = tmpl ? tmpl.componentMin : lane.componentMin;
    dl.componentMax = tmpl ? tmpl.componentMax : lane.componentMax;
    dl.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:vals ?: @[ @0.0 ]] ];
    [displayLanes addObject:dl];
  }
  if (displayLanes.count == 0 && excludedLabels.count == 0)
    return;

  double lo = 0.0, hi = 1.0;
  KKBasicValueExtent(p, &lo, &hi);
  NSPoint c = KKBasicPoint(g,
                           (d == 1   ? 0.0
                            : d == 4 ? 1.0
                                     : frac),
                           (d == 1   ? (p.inEnabled ? 0.0 : 1.0)
                            : d == 4 ? (p.outEnabled ? 0.0 : 1.0)
                                     : KKBasicMotionY(frac, p)),
                           lo, hi, p);
  if (!_popoverAnchor) {
    _popoverAnchor = [[NSView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_popoverAnchor positioned:NSWindowBelow relativeTo:nil];
  }
  _popoverAnchor.frame = NSMakeRect(c.x - kDiamondR, c.y - kDiamondR,
                                    2 * kDiamondR, 2 * kDiamondR);

  BOOL inOn = p.inEnabled, outOn = p.outEnabled;
  // For an unlinked Hold, this picks the single targeted interior keypose
  // (d==2 → hold-start, d==3 → hold-end); ignored for In/Out boundaries.
  // It must be the *stored* keypose time, not `frac` — when a phase is off
  // the projection pins frac to the clip edge (0/1) while the keypose stays
  // at its boundary, so frac would match neither Hold keypose and the edit
  // would be dropped.
  double holdStartTime = p.inEndFrac, holdEndTime = p.outStartFrac;
  for (KKLane *lane in _timeline.lanes)
    if (lane.enabled && lane.keyposes.count >= 2) {
      KKHoldShape s = KKShapeOfLane(lane);
      holdStartTime = lane.keyposes[s.holdStart].time;
      holdEndTime = lane.keyposes[s.holdEnd].time;
      break;
    }
  double holdFrac = (d == 3) ? holdEndTime : holdStartTime;
  KKBasicSection animateSec = (boundary == KKBasicBoundaryInStart)
                                  ? KKBasicSectionIn
                                  : KKBasicSectionOut;
  NSInteger capD = d;
  __weak typeof(self) weak = self;
  self.onBoundaryValuePopover(
      _popoverAnchor, displayLanes, frac, excludedLabels,
      ^(NSString *label, NSArray<NSNumber *> *values) {
        [weak _writeBoundary:boundary
                      values:values
                    forLabel:label
                        inOn:inOn
                       outOn:outOn
              holdTargetFrac:holdFrac];
      },
      ^(NSString *label) {
        // Opt the property back into this phase, then re-present so its
        // editable row replaces the message in place.
        [weak _setLaneParticipation:YES forLabel:label section:animateSec];
        [weak _openBoundaryPopoverForDiamond:capD];
      },
      self.onDragBegin, self.onDragEnd);
}

// Rewrite the keyposes that make up `boundary` for the lane `label`,
// preserving times + intervals. Hold sets every interior/edge hold keypose
// equal (stays flat); In-start / Out-end set just their endpoint keypose.
- (void)_writeBoundary:(KKBasicBoundary)boundary
                values:(NSArray<NSNumber *> *)values
              forLabel:(NSString *)label
                  inOn:(BOOL)inOn
                 outOn:(BOOL)outOn
        holdTargetFrac:(double)holdTargetFrac {
  // A linked Hold mirrors the value to both interior keyposes; an unlinked
  // Hold writes only the one the user grabbed, so the two can drift apart.
  BOOL holdLinked = [self _holdLinked];
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].label isEqualToString:label])
      continue;
    KKLane *nl = [lanes[i] copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
      double tm = kps[k].time;
      BOOL isIn = inOn && tm < kEps;
      BOOL isOut = outOn && tm > 1.0 - kEps;
      BOOL isHold = !isIn && !isOut;
      if (isHold && !holdLinked && kps.count >= 2 &&
          fabs(tm - holdTargetFrac) > kEps)
        continue; // unlinked: only the grabbed interior keypose
      BOOL belongs = boundary == KKBasicBoundaryInStart  ? isIn
                     : boundary == KKBasicBoundaryOutEnd ? isOut
                                                         : isHold;
      if (!belongs)
        continue;
      KKKeyPose *nk = [KKKeyPose keyposeAtTime:tm values:values];
      nk.outgoing = kps[k].outgoing;
      kps[k] = nk;
    }
    nl.keyposes = kps;
    lanes[i] = nl;
    break;
  }
  // Drift and modulation are alternative authoring states in Basic — the
  // Hold popover routes to one or the other based on `_holdDrift`, so a
  // modulation field lingering on a now-drifting Hold has no UI access and
  // would still wiggle the rendered curve. If this edit just caused the
  // global Hold pair to drift, wipe modulation from every animatable lane's
  // hold-start interval (re-linking won't bring it back — matches the
  // mental model that drift replaced the wobble).
  BOOL nowDrifts = NO;
  for (KKLane *lane in lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    if (s.holdEnd > s.holdStart &&
        !KKValuesEqual(lane.keyposes[s.holdStart].values,
                       lane.keyposes[s.holdEnd].values)) {
      nowDrifts = YES;
      break;
    }
  }
  if (nowDrifts)
    for (NSInteger li = 0; li < (NSInteger)lanes.count; li++) {
      KKLane *lane = lanes[li];
      if (!lane.enabled || lane.keyposes.count < 2)
        continue;
      KKHoldShape s = KKShapeOfLane(lane);
      KKInterval *iv = lane.keyposes[s.holdStart].outgoing;
      if (!iv || iv.modulation == KKIntervalModulationNone)
        continue;
      KKLane *nl2 = [lane copy];
      NSMutableArray<KKKeyPose *> *kps2 = [nl2.keyposes mutableCopy];
      KKKeyPose *kp = [kps2[s.holdStart] copy];
      KKInterval *niv = [iv copy];
      niv.modulation = KKIntervalModulationNone;
      kp.outgoing = niv;
      kps2[s.holdStart] = kp;
      nl2.keyposes = kps2;
      lanes[li] = nl2;
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

@end
