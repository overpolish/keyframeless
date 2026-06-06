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

  // Per-property "applies to" in THIS phase: a lane applies when it has the
  // phase keypose AND that interval isn't flat (holdsFlat). Toggling a checkbox
  // flips holdsFlat (non-destructive) via _setLaneParticipation.
  NSMutableArray<NSString *> *partLabels = [NSMutableArray array];
  NSMutableArray<NSNumber *> *partStates = [NSMutableArray array];
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    BOOL applies =
        isOut ? (s.outEnabled && !lane.keyposes[s.holdEnd].outgoing.holdsFlat)
              : (s.inEnabled && !lane.keyposes.firstObject.outgoing.holdsFlat);
    [partLabels addObject:lane.label];
    [partStates addObject:@(applies)];
  }

  __weak typeof(self) weak = self;
  KKBasicSection capSec = sec;
  NSString *repLabel = [self _representativeLaneLabelForSection:capSec];
  self.onGapPopover(
      _popoverAnchor, isOut, isOut ? p.outStartFrac : 0.0,
      isOut ? 1.0 : p.inEndFrac, cur, inten, freq, partLabels, partStates,
      ^NSArray<NSNumber *> * {
        // Recompute applies-to states from the current timeline so the host
        // can refresh the pills after cmd-Z (same lane order as partLabels).
        __strong typeof(weak) s = weak;
        if (!s)
          return nil;
        NSMutableArray<NSNumber *> *out = [NSMutableArray array];
        for (KKLane *lane in s->_timeline.lanes) {
          if (!lane.enabled || lane.keyposes.count < 2)
            continue;
          KKHoldShape sh = KKShapeOfLane(lane);
          BOOL ap = (capSec == KKBasicSectionOut)
                        ? (sh.outEnabled &&
                           !lane.keyposes[sh.holdEnd].outgoing.holdsFlat)
                        : (sh.inEnabled &&
                           !lane.keyposes.firstObject.outgoing.holdsFlat);
          [out addObject:@(ap)];
        }
        return out;
      },
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
        __strong typeof(weak) s = weak;
        if (!s || laneIndex < 0 || laneIndex >= (NSInteger)partLabels.count)
          return;
        [s _setLaneParticipation:on
                        forLabel:partLabels[laneIndex]
                         section:capSec];
        // Unchecking the last property empties the phase → the curve popover
        // has nothing left to edit, so close it (mirrors the keypose popover).
        KKBasicProj pp = [s _projection];
        BOOL phaseOn =
            (capSec == KKBasicSectionOut) ? pp.outEnabled : pp.inEnabled;
        if (!phaseOn && s.onRequestClosePopover)
          s.onRequestClosePopover();
      },
      self.onDragBegin, self.onDragEnd,
      // Representative interval + its lane label so plugins can gate extras
      // by lane (e.g. MagicMove's rotate-with-motion only on Position). The
      // mutator targets ONLY that lane's interval - the property is lane-
      // specific and shouldn't pollute other lanes' userProperties dicts.
      repLabel,
      [self _representativeIntervalForSection:capSec]
          ?: [[KKInterval alloc] init],
      ^KKInterval *(void) {
        return [weak _representativeIntervalForSection:capSec];
      },
      ^(void (^_Nonnull mutate)(KKInterval *_Nonnull)) {
        [weak _mutateIntervalInLaneLabel:repLabel section:capSec with:mutate];
      });
}

- (NSString *)_representativeLaneLabelForSection:(KKBasicSection)section {
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    if (section == KKBasicSectionOut && !s.outEnabled)
      continue;
    if (section == KKBasicSectionIn && !s.inEnabled)
      continue;
    return lane.label;
  }
  return nil;
}

// Returns a representative outgoing-interval for the phase: the first
// enabled lane's relevant interval. Plugins read state from it for their
// extra-row toggles; the mutator fans the write across every participating
// lane. nil if no lane currently participates.
- (KKInterval *)_representativeIntervalForSection:(KKBasicSection)section {
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    NSInteger idx;
    if (section == KKBasicSectionOut) {
      if (!s.outEnabled)
        continue;
      idx = s.holdEnd;
    } else if (section == KKBasicSectionHold) {
      idx = s.holdStart;
    } else {
      if (!s.inEnabled)
        continue;
      idx = 0;
    }
    if (idx >= 0 && idx < (NSInteger)lane.keyposes.count)
      return lane.keyposes[idx].outgoing;
  }
  return nil;
}

// Per-lane phase "applies to" - NON-DESTRUCTIVE. Turning a phase off for one
// property just flips that property's In/Out interval to holdsFlat (it sits at
// the Hold value through the phase, no animation); the keypose and its stored
// value are kept, so turning it back on restores the exact animation. Keyposes
// are never moved or removed (moving them is what corrupted the shared boundary
// times before). Legacy fallback: if a lane somehow lacks the phase keypose
// when enabling, build it once via _rebuiltLane:.
- (void)_setLaneParticipation:(BOOL)on
                     forLabel:(NSString *)label
                      section:(KKBasicSection)sec {
  // Removing the LAST applier empties the phase: disable it structurally
  // (drop every lane's start keypose for that phase) instead of leaving a
  // lane flat, so the off state matches the master checkbox. One mutation.
  if (!on) {
    BOOL othersApply = NO;
    for (KKLane *lane in _timeline.lanes) {
      if (!lane.enabled || lane.keyposes.count < 2 ||
          [lane.label isEqualToString:label])
        continue;
      KKHoldShape s = KKShapeOfLane(lane);
      BOOL applies =
          (sec == KKBasicSectionOut)
              ? (s.outEnabled && !lane.keyposes[s.holdEnd].outgoing.holdsFlat)
              : (s.inEnabled && !lane.keyposes.firstObject.outgoing.holdsFlat);
      if (applies) {
        othersApply = YES;
        break;
      }
    }
    if (!othersApply) {
      if (sec == KKBasicSectionOut)
        [self _setOutEnabled:NO];
      else
        [self _setInEnabled:NO];
      return;
    }
  }
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (!lane.enabled || ![lane.label isEqualToString:label] ||
        lane.keyposes.count < 2)
      continue;
    KKHoldShape s = KKShapeOfLane(lane);
    BOOL hasPhase = (sec == KKBasicSectionOut) ? s.outEnabled : s.inEnabled;
    if (hasPhase) {
      // Flip the phase interval's flat flag, leaving every keypose in place.
      NSInteger ivIdx = (sec == KKBasicSectionOut) ? s.holdEnd : 0;
      KKLane *nl = [lane copy];
      NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
      KKKeyPose *kp = [kps[ivIdx] copy];
      KKInterval *iv = [kp.outgoing copy] ?: [[KKInterval alloc] init];
      iv.holdsFlat = !on;
      kp.outgoing = iv;
      kps[ivIdx] = kp;
      nl.keyposes = kps;
      lanes[i] = nl;
    } else if (on) {
      // Legacy data with no keypose for this phase yet → create it (animating).
      BOOL inOn = (sec == KKBasicSectionOut) ? s.inEnabled : YES;
      BOOL outOn = (sec == KKBasicSectionOut) ? YES : s.outEnabled;
      double tIn = lane.keyposes[s.holdStart].time;
      double tOut = lane.keyposes[s.holdEnd].time;
      lanes[i] = [self _rebuiltLane:lane
                               inOn:inOn
                              outOn:outOn
                                tIn:tIn
                               tOut:tOut];
    }
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
// the 2-equal-keypose carrier - deferred with the In/Out enable work.)
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
    NSString *holdRepLabel =
        [self _representativeLaneLabelForSection:KKBasicSectionHold];
    self.onGapPopover(
        _popoverAnchor, NO, p.inEndFrac, p.outStartFrac,
        (KKIntervalCurve)p.holdCurve, p.holdIntensity, p.holdFrequency,
        holdLabels, driftStates, nil,
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
          // popover (the easing editor) is now the wrong one - swap to
          // the modulation editor in place.
          if (![weak _holdDrift])
            [weak _openHoldPopover];
        },
        self.onDragBegin, self.onDragEnd, holdRepLabel,
        [self _representativeIntervalForSection:KKBasicSectionHold]
            ?: [[KKInterval alloc] init],
        ^KKInterval *(void) {
          return [weak _representativeIntervalForSection:KKBasicSectionHold];
        },
        ^(void (^_Nonnull mutate)(KKInterval *_Nonnull)) {
          [weak _mutateIntervalInLaneLabel:holdRepLabel
                                   section:KKBasicSectionHold
                                      with:mutate];
        });
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
  // Rebuilder closure - re-runs the same state derivation against the
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
      self.onDragBegin, self.onDragEnd,
      [self _representativeLaneLabelForSection:KKBasicSectionHold],
      [self _representativeIntervalForSection:KKBasicSectionHold]
          ?: [[KKInterval alloc] init],
      ^KKInterval *(void) {
        return [weak _representativeIntervalForSection:KKBasicSectionHold];
      },
      ^(void (^_Nonnull mutate)(KKInterval *_Nonnull)) {
        NSString *lbl =
            [weak _representativeLaneLabelForSection:KKBasicSectionHold];
        [weak _mutateIntervalInLaneLabel:lbl
                                 section:KKBasicSectionHold
                                    with:mutate];
      });
}

// Apply `mut` to the In / Hold / Out interval of every animatable lane -
// Basic shares one In easing, one Out easing, one Hold (modulation/drift) -
// then fire onTimelineMutated. The live BasicView redraw is local
// (setNeedsDisplay re-reads from the projection); the host coalesces the
// per-tick blob writes into the slider drag's undo group.
// Per-lane variant: write only to the named lane's phase interval. Used by
// gap-popover extras whose semantics are lane-specific (e.g. MagicMove's
// rotate-with-motion is a property of the Position curve, not of every
// participating lane). nil/empty label is a no-op.
- (void)_mutateIntervalInLaneLabel:(NSString *)laneLabel
                           section:(KKBasicSection)section
                              with:(void (^)(KKInterval *iv))mut {
  if (laneLabel.length == 0)
    return;
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (![lane.label isEqualToString:laneLabel])
      continue;
    if (!lane.enabled || lane.keyposes.count < 2)
      return;
    KKHoldShape s = KKShapeOfLane(lane);
    NSInteger idx;
    if (section == KKBasicSectionOut) {
      if (!s.outEnabled)
        return;
      idx = s.holdEnd;
    } else if (section == KKBasicSectionHold) {
      idx = s.holdStart;
    } else {
      if (!s.inEnabled)
        return;
      idx = 0;
    }
    KKLane *nl = [lane copy];
    NSMutableArray<KKKeyPose *> *nkps = [lane.keyposes mutableCopy];
    KKKeyPose *kp = [nkps[idx] copy];
    KKInterval *iv = [kp.outgoing copy] ?: [[KKInterval alloc] init];
    mut(iv);
    kp.outgoing = iv;
    nkps[idx] = kp;
    nl.keyposes = nkps;
    lanes[i] = nl;
    break;
  }
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

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
      idx = s.holdStart; // Hold interval - always present
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

@end
