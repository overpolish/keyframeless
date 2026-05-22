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
      _popoverAnchor, isOut, isOut ? p.outStartFrac : 0.0,
      isOut ? 1.0 : p.inEndFrac, cur, inten, freq, partLabels, partStates,
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
        _popoverAnchor, NO, p.inEndFrac, p.outStartFrac,
        (KKIntervalCurve)p.holdCurve, p.holdIntensity, p.holdFrequency,
        holdLabels, driftStates,
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
  // Each animatable lane becomes one compound pill: single-component lanes
  // are one-segment compounds (just the lane label); multi-component lanes
  // are master+components (lane label + W/H/X/Y), rendered as one capsule
  // with internal dividers so 4+1 sub-pills don't eat the popover width.
  NSMutableArray<NSArray<NSString *> *> *partCompoundLabels =
      [NSMutableArray array];
  NSMutableArray<NSArray<NSNumber *> *> *partCompoundStates =
      [NSMutableArray array];
  // Parallel decode map for the flat-index participation callback. One
  // entry per visible segment, pairing (lane label, componentIdx). -1 in
  // componentIdx means the segment is a master (toggles the lane); -2 is
  // the single-segment compound for a single-component lane.
  NSMutableArray<NSString *> *partLaneLabels = [NSMutableArray array];
  NSMutableArray<NSNumber *> *partComponentIdx = [NSMutableArray array];
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    NSArray<NSString *> *compLabels = KKLaneComponentLabels(lane);
    NSUInteger compCount = lane.keyposes.firstObject.values.count;
    KKInterval *liv = lane.keyposes[KKShapeOfLane(lane).holdStart].outgoing;
    BOOL laneModActive = liv && liv.modulation != KKIntervalModulationNone;
    if (compLabels.count > 1 && compCount > 1) {
      showsLinked = YES;
      NSIndexSet *mask = liv.modulationComponents;
      NSMutableArray<NSString *> *segLabels =
          [NSMutableArray arrayWithObject:lane.label];
      NSMutableArray<NSNumber *> *segStates =
          [NSMutableArray arrayWithObject:@(laneModActive)];
      [partLaneLabels addObject:lane.label];
      [partComponentIdx addObject:@(-1)]; // master segment
      for (NSUInteger c = 0; c < compCount; c++) {
        NSString *cn =
            (c < compLabels.count)
                ? compLabels[c]
                : [NSString stringWithFormat:@"%lu", (unsigned long)c];
        [segLabels addObject:cn];
        BOOL on = laneModActive && (!mask || [mask containsIndex:c]);
        [segStates addObject:@(on)];
        [partLaneLabels addObject:lane.label];
        [partComponentIdx addObject:@(c)];
      }
      [partCompoundLabels addObject:segLabels];
      [partCompoundStates addObject:segStates];
    } else {
      [partCompoundLabels addObject:@[ lane.label ]];
      [partCompoundStates addObject:@[ @(laneModActive) ]];
      [partLaneLabels addObject:lane.label];
      [partComponentIdx addObject:@(-2)]; // single-segment, lane-level
    }
  }
  // Rebuilder closure — re-runs the same state derivation against the
  // current timeline so external mutations (cmd-Z) can refresh the
  // already-open popover's pills. Captures weak so it lives as long as
  // the popover does.
  NSArray<NSArray<NSNumber *> *> * (^partRebuilder)(void) =
      ^NSArray<NSArray<NSNumber *> *> * {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return nil;
    NSMutableArray<NSArray<NSNumber *> *> *out = [NSMutableArray array];
    for (KKLane *lane in strong->_timeline.lanes) {
      if (!lane.enabled || lane.keyposes.count < 2)
        continue;
      NSArray<NSString *> *compLabels2 = KKLaneComponentLabels(lane);
      NSUInteger compCount2 = lane.keyposes.firstObject.values.count;
      KKInterval *liv2 = lane.keyposes[KKShapeOfLane(lane).holdStart].outgoing;
      BOOL active = liv2 && liv2.modulation != KKIntervalModulationNone;
      if (compLabels2.count > 1 && compCount2 > 1) {
        NSMutableArray<NSNumber *> *segStates =
            [NSMutableArray arrayWithObject:@(active)];
        NSIndexSet *mask = liv2.modulationComponents;
        for (NSUInteger c = 0; c < compCount2; c++) {
          BOOL on = active && (!mask || [mask containsIndex:c]);
          [segStates addObject:@(on)];
        }
        [out addObject:segStates];
      } else {
        [out addObject:@[ @(active) ]];
      }
    }
    return out;
  };
  self.onHoldModulationPopover(
      _popoverAnchor, p.inEndFrac, p.outStartFrac, mod, mInten, mFreq, seed,
      linked, showsLinked, partCompoundLabels, partCompoundStates,
      partRebuilder,
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
      ^(NSInteger idx, BOOL on) {
        if (idx < 0 || idx >= (NSInteger)partLaneLabels.count)
          return;
        NSInteger c = partComponentIdx[idx].integerValue;
        if (c < 0)
          [weak _setHoldModApplied:on forLabel:partLaneLabels[idx]];
        else
          [weak _setHoldModComponent:(NSUInteger)c
                                  on:on
                            forLabel:partLaneLabels[idx]];
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

// Per-component modulation participation for a multi-component lane. Adds
// or removes `componentIdx` in the lane's Hold-interval modulationComponents
// mask. When the mask empties out the lane's modulation flips to None (the
// pill row reads the lane as excluded); turning a component on while the
// lane is excluded re-arms the modulation with the current shared type +
// intensity/freq/seed taken from the projection so it lights up immediately.
- (void)_setHoldModComponent:(NSUInteger)componentIdx
                          on:(BOOL)on
                    forLabel:(NSString *)label {
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
    NSUInteger compCount = lane.keyposes.firstObject.values.count;
    // Seed the mask from current state: nil ⇒ all components active.
    NSMutableIndexSet *mask =
        iv.modulationComponents ? [iv.modulationComponents mutableCopy] : ({
          NSMutableIndexSet *all = [NSMutableIndexSet indexSet];
          [all addIndexesInRange:NSMakeRange(0, compCount)];
          all;
        });
    if (on)
      [mask addIndex:componentIdx];
    else
      [mask removeIndex:componentIdx];
    iv.modulationComponents = mask;
    if (mask.count == 0) {
      iv.modulation = KKIntervalModulationNone;
    } else if (iv.modulation == KKIntervalModulationNone) {
      iv.modulation = type;
      iv.modulationIntensity = p.holdModIntensity;
      iv.modulationFrequency = p.holdModFrequency;
      iv.modulationSeed = p.holdModSeed;
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
    dl.componentUnits = tmpl ? tmpl.componentUnits : lane.componentUnits;
    dl.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:vals ?: @[ @0.0 ]] ];
    [displayLanes addObject:dl];
  }
  if (displayLanes.count == 0 && excludedLabels.count == 0)
    return;

  // Anchor on the boundary pill (full track height) so the popover arrow
  // lands on the pill body regardless of where the click hit it.
  CGFloat pillX = KKBasicXForFrac((d == 1 ? 0.0 : d == 4 ? 1.0 : frac), g, p);
  if (!_popoverAnchor) {
    _popoverAnchor = [[NSView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_popoverAnchor positioned:NSWindowBelow relativeTo:nil];
  }
  _popoverAnchor.frame =
      NSMakeRect(pillX - kPillW * 0.5, NSMinY(g) + kPillInsetY, kPillW,
                 NSHeight(g) - 2.0 * kPillInsetY);

  // For an unlinked Hold, this picks the single targeted interior keypose
  // (d==2 → hold-start, d==3 → hold-end); ignored for In/Out boundaries.
  // Must be the *stored* keypose time, not `frac` — when a phase is off,
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
  // Bind the popover's state into ivars so the closures below read live
  // values — that's what lets requestValuePopoverAtFraction: (filmstrip
  // click) swap boundaries on the open popover without rebuilding it.
  _curBoundary = boundary;
  _curBoundaryInOn = p.inEnabled;
  _curBoundaryOutOn = p.outEnabled;
  _curBoundaryHoldFrac = (d == 3) ? holdEndTime : holdStartTime;
  _curAnimateSec = (boundary == KKBasicBoundaryInStart) ? KKBasicSectionIn
                                                        : KKBasicSectionOut;
  _curDiamond = d;
  __weak typeof(self) weak = self;
  self.onBoundaryValuePopover(
      _popoverAnchor, displayLanes, frac, excludedLabels,
      ^(NSString *label, NSArray<NSNumber *> *values) {
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        [s _writeBoundary:s->_curBoundary
                    values:values
                  forLabel:label
                      inOn:s->_curBoundaryInOn
                     outOn:s->_curBoundaryOutOn
            holdTargetFrac:s->_curBoundaryHoldFrac];
      },
      ^(NSString *label) {
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        [s _setLaneParticipation:YES forLabel:label section:s->_curAnimateSec];
        [s _openBoundaryPopoverForDiamond:s->_curDiamond];
      },
      self.onDragBegin, self.onDragEnd);
}

- (void)requestValuePopoverAtFraction:(double)fraction {
  // Map the requested fraction to whichever of the 4 boundary diamonds is
  // closest, then re-open at that diamond. Reuses the lanes-view in-place
  // rebind path for an already-open popover.
  KKBasicProj p = [self _projection];
  double in0 = 0.0, inE = p.inEndFrac, outS = p.outStartFrac, out1 = 1.0;
  double dists[4] = {fabs(fraction - in0), fabs(fraction - inE),
                     fabs(fraction - outS), fabs(fraction - out1)};
  NSInteger best = 0;
  double bestDt = dists[0];
  for (NSInteger i = 1; i < 4; i++)
    if (dists[i] < bestDt) {
      bestDt = dists[i];
      best = i;
    }
  // Diamond IDs are 1-indexed (1=InStart, 2=Hold-start, 3=Hold-end,
  // 4=OutEnd); array index `best` maps directly to (best + 1).
  [self _openBoundaryPopoverForDiamond:(best + 1)];
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
