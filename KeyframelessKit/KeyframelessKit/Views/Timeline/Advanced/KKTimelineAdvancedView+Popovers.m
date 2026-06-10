/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineAdvancedView_Private.h"

#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

@implementation KKTimelineAdvancedView (Popovers)

- (void)writeSpatialSmoothForLabel:(NSString *)label
                            atFrac:(double)frac
                              isOn:(BOOL)on {
  KKTimeline *t = KKTimelineSettingSpatialSmooth(_timeline, label, frac, on);
  if (!t)
    return;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

- (void)writeAspectLinkedForLabel:(NSString *)label isOn:(BOOL)on {
  KKTimeline *t = KKTimelineSettingAspectLinked(_timeline, label, on);
  if (!t)
    return;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

- (void)_openValuePopoverForLane:(NSInteger)laneIdx kp:(NSInteger)kpIdx {
  if (!self.onValuePopover)
    return;
  NSArray<KKLane *> *lanes = [self _animatableLanes];
  if (laneIdx < 0 || laneIdx >= (NSInteger)lanes.count)
    return;
  KKLane *lane = lanes[laneIdx];
  if (kpIdx < 0 || kpIdx >= (NSInteger)lane.keyposes.count)
    return;
  KKKeyPose *kp = lane.keyposes[kpIdx];
  double frac = kp.time;

  // Anchor: transient invisible subview the size of the clicked pill so the
  // popover arrow lands on the pill body.
  NSRect tracks = [self _tracksRect];
  NSRect row = [self _rowRectForIndex:laneIdx count:lanes.count];
  CGFloat x = [self _xForFrac:frac inLane:lane inTracks:tracks];
  CGFloat pillBot = NSMinY(row) + kPillInsetY;
  CGFloat pillTop = NSMaxY(row) - kPillInsetY;
  if (pillTop <= pillBot) {
    pillBot = NSMinY(row);
    pillTop = NSMaxY(row);
  }
  if (!_popoverAnchor) {
    _popoverAnchor = [[NSView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_popoverAnchor positioned:NSWindowBelow relativeTo:nil];
  }
  _popoverAnchor.frame =
      NSMakeRect(x - kPillW * 0.5, pillBot, kPillW, pillTop - pillBot);

  // Display lanes: every animatable lane in the same group that has a KP at
  // *exactly* this time goes into the active zone (editable + mini-viewer
  // handle visible). Same-group lanes without a co-time KP go into
  // excludedLabels - shown as the "available zone" row with an "Animate"
  // button.
  NSString *groupKey = lane.groupKey;
  NSMutableArray<KKLane *> *displayLanes = [NSMutableArray array];
  NSMutableArray<NSString *> *excludedLabels = [NSMutableArray array];
  for (KKLane *l in lanes) {
    BOOL sameGroup =
        (l.groupKey == groupKey) || [l.groupKey isEqualToString:groupKey];
    if (!sameGroup)
      continue;
    KKKeyPose *match = nil;
    for (KKKeyPose *k in l.keyposes)
      if (fabs(k.time - frac) < 1.0e-4) {
        match = k;
        break;
      }
    // A same-group lane with no co-time keypose still gets a (base) display
    // row so the static popover can swap it to an "Animate" row IN PLACE,
    // preserving property order - matching Basic. Without a base row,
    // applyExcludedLabels: no-ops (it only transforms an existing row), so
    // the property silently vanished from the popover.
    NSArray<NSNumber *> *vals = match ? match.values
                                      : (KKTimelineLaneValueAtFraction(l, frac)
                                             ?: l.keyposes.firstObject.values);
    if (!match)
      [excludedLabels addObject:l.label];
    KKLane *display = [KKLane laneWithLabel:l.label];
    display.valueType = l.valueType;
    display.componentMin = l.componentMin;
    display.componentMax = l.componentMax;
    display.componentUnits = l.componentUnits;
    display.componentLabels = l.componentLabels;
    display.componentLabelColors = l.componentLabelColors;
    // spatialCurvable is lane metadata, not per-project state, so source it
    // from the template - an older blob (saved before the flag existed) would
    // otherwise leave it off and hide the curve toggle.
    KKLane *tmpl = nil;
    for (KKLane *t in _availableLanes)
      if ([t.label isEqualToString:l.label]) {
        tmpl = t;
        break;
      }
    display.spatialCurvable = tmpl ? tmpl.spatialCurvable : l.spatialCurvable;
    // aspectLinkable is metadata (template); aspectLinked is user state (blob).
    display.aspectLinkable = tmpl ? tmpl.aspectLinkable : l.aspectLinkable;
    display.aspectLinked = l.aspectLinked;
    display.integerValued = tmpl ? tmpl.integerValued : l.integerValued;
    [display kkApplyPickerMetadataFrom:tmpl]; // category / animatable / seed
    KKKeyPose *displayKp = [KKKeyPose keyposeAtTime:0.0
                                             values:vals ?: @[ @0.0 ]];
    // Carry the curve state so the row's toggle reflects this keypose.
    if (match) {
      displayKp.spatialSmooth = match.spatialSmooth;
      displayKp.inHandle = match.inHandle;
      displayKp.outHandle = match.outHandle;
    }
    display.keyposes = @[ displayKp ];
    [displayLanes addObject:display];
  }
  if (displayLanes.count == 0 && excludedLabels.count == 0)
    return;

  _currentPopoverFrac = frac;
  __weak typeof(self) weak = self;
  void (^onValue)(NSString *, NSArray<NSNumber *> *) =
      ^(NSString *lab, NSArray<NSNumber *> *values) {
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        [s _writeValueForLabel:lab atFrac:s->_currentPopoverFrac values:values];
      };
  void (^onAnimate)(NSString *) = ^(NSString *lab) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    double f = s->_currentPopoverFrac;
    [s _addKeyposeAtFrac:f forLabel:lab];
    // Re-drive the popover so the just-added lane flips from an Animate row to
    // an editable row in place (the present path detects it's open → rebuilds
    // rows, no reopen / canvas blink).
    [s requestValuePopoverAtFraction:f];
  };
  NSString *capGroup = groupKey;
  void (^onRemove)(NSString *) = ^(NSString *lab) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    double f = s->_currentPopoverFrac;
    [s _removeKeyposeAtFrac:f forLabel:lab];
    // Other same-group lanes still keyed here → refresh in place so the
    // removed row flips back to "No keypose here"; nothing left → close.
    if ([s _anySameGroupKeyposeAtFrac:f group:capGroup])
      [s requestValuePopoverAtFraction:f];
    else if (s.onRequestClosePopover)
      s.onRequestClosePopover();
  };
  void (^onDragBegin)(void) = ^{
    __strong typeof(weak) s = weak;
    if (s && s.onDragBegin)
      s.onDragBegin();
  };
  void (^onDragEnd)(void) = ^{
    __strong typeof(weak) s = weak;
    if (s && s.onDragEnd)
      s.onDragEnd();
  };
  self.onValuePopover(_popoverAnchor, displayLanes, frac, excludedLabels,
                      lane.categoryKey, onValue, onAnimate, onRemove,
                      onDragBegin, onDragEnd);
}

- (void)requestValuePopoverAtFraction:(double)fraction {
  NSArray<KKLane *> *lanes = [self _animatableLanes];
  NSInteger preferredLane = -1;
  if (_topLaneLabel) {
    for (NSInteger i = 0; i < (NSInteger)lanes.count; i++)
      if ([lanes[i].label isEqualToString:_topLaneLabel]) {
        preferredLane = i;
        break;
      }
  }
  const double kEps = 1.0e-4;
  NSInteger foundLane = -1, foundKP = -1;
  if (preferredLane >= 0) {
    KKLane *l = lanes[preferredLane];
    for (NSInteger k = 0; k < (NSInteger)l.keyposes.count; k++) {
      if (fabs(l.keyposes[k].time - fraction) < kEps) {
        foundLane = preferredLane;
        foundKP = k;
        break;
      }
    }
  }
  if (foundLane < 0) {
    for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
      KKLane *l = lanes[i];
      for (NSInteger k = 0; k < (NSInteger)l.keyposes.count; k++) {
        if (fabs(l.keyposes[k].time - fraction) < kEps) {
          foundLane = i;
          foundKP = k;
          break;
        }
      }
      if (foundLane >= 0)
        break;
    }
  }
  if (foundLane < 0)
    return;
  _topLaneLabel = [lanes[foundLane].label copy];
  _topKPIdx = foundKP;
  [self _openValuePopoverForLane:foundLane kp:foundKP];
}

// Equal endpoints → modulation pills (Wiggle / Oscillate / Handheld) - curve
// type has no visible effect when values are equal. Different endpoints →
// curve pills, modulation isn't useful there. Mirrors Basic's
// `_openGapPopoverForSection:` vs `_openHoldPopover` routing.
- (void)_openGapPopoverForLabel:(NSString *)label kpIdx:(NSInteger)aIdx {
  KKLane *lane = nil;
  for (KKLane *l in _timeline.lanes)
    if ([l.label isEqualToString:label]) {
      lane = l;
      break;
    }
  if (!lane || aIdx < 0 || aIdx + 1 >= (NSInteger)lane.keyposes.count)
    return;
  KKKeyPose *a = lane.keyposes[aIdx];
  KKKeyPose *b = lane.keyposes[aIdx + 1];
  KKInterval *iv = a.outgoing ?: [[KKInterval alloc] init];

  NSArray<KKLane *> *anim = [self _animatableLanes];
  NSInteger animIdx = -1;
  for (NSInteger i = 0; i < (NSInteger)anim.count; i++)
    if ([anim[i].label isEqualToString:label]) {
      animIdx = i;
      break;
    }
  if (animIdx < 0)
    return;
  NSRect tracks = [self _tracksRect];
  NSRect row = [self _rowRectForIndex:animIdx count:anim.count];
  CGFloat xA = [self _xForFrac:a.time inLane:anim[animIdx] inTracks:tracks];
  CGFloat xB = [self _xForFrac:b.time inLane:anim[animIdx] inTracks:tracks];
  // When zoomed + scrolled, the gap's mathematical midpoint may sit outside
  // the visible scroll region OR under the label gutter (left of tracks).
  // NSPopover refuses to anchor to an offscreen view, and anchoring under
  // the labels makes the arrow point at "Position"/"Rotation" instead of
  // the gap. Confine the anchor to the visible portion of the tracks rect
  // (tracks ∩ visibleRect) intersected with the gap's own span - the arrow
  // lands in the centre of what the user can actually see of the gap.
  NSRect vis = self.visibleRect;
  CGFloat leftBound = MAX(NSMinX(tracks), NSMinX(vis));
  CGFloat rightBound = MIN(NSMaxX(tracks), NSMaxX(vis));
  CGFloat visStart = MAX(xA, leftBound);
  CGFloat visEnd = MIN(xB, rightBound);
  if (visStart >= visEnd) {
    // Gap is entirely outside the visible tracks region. Park the anchor
    // on whichever tracks edge the gap is closest to so the popover at
    // least appears next to the row.
    visStart = visEnd = (xB < leftBound)
                            ? leftBound
                            : ((xA > rightBound) ? rightBound : leftBound);
  }
  CGFloat anchorX = (visStart + visEnd) * 0.5;
  if (!_popoverAnchor) {
    _popoverAnchor = [[NSView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_popoverAnchor positioned:NSWindowBelow relativeTo:nil];
  }
  _popoverAnchor.frame = NSMakeRect(anchorX - 1.0, NSMidY(row) - 1.0, 2.0, 2.0);

  __weak typeof(self) weak = self;
  void (^onDragBegin)(void) = ^{
    __strong typeof(weak) s = weak;
    if (s && s.onDragBegin)
      s.onDragBegin();
  };
  void (^onDragEnd)(void) = ^{
    __strong typeof(weak) s = weak;
    if (s && s.onDragEnd)
      s.onDragEnd();
  };

  if (KKAdvValuesEqual(a.values, b.values)) {
    if (!self.onHoldModulationPopover)
      return;
    void (^onModulation)(KKIntervalModulation) = ^(KKIntervalModulation m) {
      [weak _mutateIntervalInLaneLabel:label
                                 kpIdx:aIdx
                                  with:^(KKInterval *iv2) {
                                    iv2.modulation = m;
                                  }];
    };
    void (^onIntensity)(double) = ^(double v) {
      [weak _mutateIntervalInLaneLabel:label
                                 kpIdx:aIdx
                                  with:^(KKInterval *iv2) {
                                    iv2.modulationIntensity = v;
                                  }];
    };
    void (^onFrequency)(double) = ^(double v) {
      [weak _mutateIntervalInLaneLabel:label
                                 kpIdx:aIdx
                                  with:^(KKInterval *iv2) {
                                    iv2.modulationFrequency = v;
                                  }];
    };
    void (^onSeed)(uint32_t) = ^(uint32_t s) {
      [weak _mutateIntervalInLaneLabel:label
                                 kpIdx:aIdx
                                  with:^(KKInterval *iv2) {
                                    iv2.modulationSeed = s;
                                  }];
    };
    NSArray<NSString *> *compLabels = KKLaneComponentLabels(lane);
    NSUInteger compCount = lane.keyposes.firstObject.values.count;
    BOOL multiComp = (compLabels.count > 1 && compCount > 1);
    BOOL laneModActive = iv.modulation != KKIntervalModulationNone;
    NSMutableArray<NSString *> *segLabels =
        [NSMutableArray arrayWithObject:label];
    NSMutableArray<NSNumber *> *segStates =
        [NSMutableArray arrayWithObject:@(laneModActive)];
    if (multiComp) {
      NSIndexSet *mask = iv.modulationComponents;
      for (NSUInteger c = 0; c < compCount; c++) {
        NSString *cn =
            (c < compLabels.count)
                ? compLabels[c]
                : [NSString stringWithFormat:@"%lu", (unsigned long)c];
        [segLabels addObject:cn];
        BOOL on = laneModActive && (!mask || [mask containsIndex:c]);
        [segStates addObject:@(on)];
      }
    }
    NSArray<NSArray<NSString *> *> *partCompoundLabels = @[ segLabels ];
    NSArray<NSArray<NSNumber *> *> *partCompoundStates = @[ segStates ];
    void (^onParticipation)(NSInteger, BOOL) = ^(NSInteger idx, BOOL on) {
      [weak
          _mutateIntervalInLaneLabel:label
                               kpIdx:aIdx
                                with:^(KKInterval *iv2) {
                                  if (idx == 0) {
                                    iv2.modulation =
                                        on ? (iv2.modulation !=
                                                      KKIntervalModulationNone
                                                  ? iv2.modulation
                                                  : KKIntervalModulationWiggle)
                                           : KKIntervalModulationNone;
                                    return;
                                  }
                                  NSUInteger c = (NSUInteger)(idx - 1);
                                  NSUInteger n =
                                      lane.keyposes.firstObject.values.count;
                                  NSMutableIndexSet *m =
                                      iv2.modulationComponents
                                          ? [iv2.modulationComponents
                                                    mutableCopy]
                                          : ({
                                              NSMutableIndexSet *all =
                                                  [NSMutableIndexSet indexSet];
                                              [all
                                                  addIndexesInRange:NSMakeRange(
                                                                        0, n)];
                                              all;
                                            });
                                  if (on)
                                    [m addIndex:c];
                                  else
                                    [m removeIndex:c];
                                  iv2.modulationComponents = m;
                                }];
    };
    BOOL showsModLinked = multiComp;
    void (^onLinked)(BOOL) = ^(BOOL on) {
      [weak _mutateIntervalInLaneLabel:label
                                 kpIdx:aIdx
                                  with:^(KKInterval *iv2) {
                                    iv2.modulationLinked = on;
                                  }];
    };
    NSString *capturedLabel = label;
    NSInteger capturedAIdx = aIdx;
    NSArray<NSArray<NSNumber *> *> * (^partRebuilder)(void) =
        ^NSArray<NSArray<NSNumber *> *> * {
      __strong typeof(weak) strong = weak;
      if (!strong)
        return nil;
      KKLane *l2 = nil;
      for (KKLane *cand in strong->_timeline.lanes)
        if ([cand.label isEqualToString:capturedLabel] && cand.enabled) {
          l2 = cand;
          break;
        }
      if (!l2 || capturedAIdx < 0 ||
          capturedAIdx >= (NSInteger)l2.keyposes.count)
        return nil;
      KKInterval *iv2 = l2.keyposes[capturedAIdx].outgoing;
      BOOL active = iv2 && iv2.modulation != KKIntervalModulationNone;
      NSArray<NSString *> *cl2 = KKLaneComponentLabels(l2);
      NSUInteger cc2 = l2.keyposes.firstObject.values.count;
      NSMutableArray<NSNumber *> *segStates2 =
          [NSMutableArray arrayWithObject:@(active)];
      if (cl2.count > 1 && cc2 > 1) {
        NSIndexSet *mask = iv2.modulationComponents;
        for (NSUInteger c = 0; c < cc2; c++) {
          BOOL on = active && (!mask || [mask containsIndex:c]);
          [segStates2 addObject:@(on)];
        }
      }
      return @[ segStates2 ];
    };
    NSString *capLabelMut = label;
    NSInteger capIdxMut = aIdx;
    KKGapIntervalReader reader = ^KKInterval *(void) {
      __strong typeof(weak) s = weak;
      if (!s)
        return nil;
      for (KKLane *l in s->_timeline.lanes)
        if ([l.label isEqualToString:capLabelMut] && l.enabled &&
            capIdxMut >= 0 && capIdxMut < (NSInteger)l.keyposes.count)
          return l.keyposes[capIdxMut].outgoing;
      return nil;
    };
    KKGapIntervalMutator mutator =
        ^(void (^_Nonnull mutate)(KKInterval *_Nonnull)) {
          [weak _mutateIntervalInLaneLabel:capLabelMut
                                     kpIdx:capIdxMut
                                      with:mutate];
        };
    self.onHoldModulationPopover(
        _popoverAnchor, a.time, b.time, iv.modulation, iv.modulationIntensity,
        iv.modulationFrequency, iv.modulationSeed, iv.modulationLinked,
        showsModLinked, partCompoundLabels, partCompoundStates, partRebuilder,
        onModulation, onIntensity, onFrequency, onSeed, onLinked,
        onParticipation, onDragBegin, onDragEnd, label, iv, reader, mutator);
    return;
  }
  // animateOut mirrors the pill glyphs when the interval descends so the
  // glyph reads the same way the lane graph does.
  if (!self.onGapPopover)
    return;
  double meanA = 0.0, meanB = 0.0;
  NSUInteger n = MIN(a.values.count, b.values.count);
  for (NSUInteger c = 0; c < n; c++) {
    meanA += KKAdvNormComponent(a.values[c].doubleValue, lane.componentMin,
                                lane.componentMax, c);
    meanB += KKAdvNormComponent(b.values[c].doubleValue, lane.componentMin,
                                lane.componentMax, c);
  }
  BOOL descending = (n > 0) && (meanB < meanA);
  void (^onCurve)(KKIntervalCurve) = ^(KKIntervalCurve c) {
    [weak _mutateIntervalInLaneLabel:label
                               kpIdx:aIdx
                                with:^(KKInterval *iv2) {
                                  iv2.curve = c;
                                }];
  };
  void (^onIntensity)(double) = ^(double v) {
    [weak _mutateIntervalInLaneLabel:label
                               kpIdx:aIdx
                                with:^(KKInterval *iv2) {
                                  iv2.intensity = v;
                                }];
  };
  void (^onFrequency)(double) = ^(double v) {
    [weak _mutateIntervalInLaneLabel:label
                               kpIdx:aIdx
                                with:^(KKInterval *iv2) {
                                  iv2.frequency = v;
                                }];
  };
  NSString *capturedLabel = label;
  NSInteger capturedIdx = aIdx;
  KKGapIntervalReader reader = ^KKInterval *(void) {
    __strong typeof(weak) s = weak;
    if (!s)
      return nil;
    for (KKLane *l in s->_timeline.lanes)
      if ([l.label isEqualToString:capturedLabel] && l.enabled &&
          capturedIdx >= 0 && capturedIdx < (NSInteger)l.keyposes.count)
        return l.keyposes[capturedIdx].outgoing;
    return nil;
  };
  KKGapIntervalMutator mutator =
      ^(void (^_Nonnull mutate)(KKInterval *_Nonnull)) {
        [weak _mutateIntervalInLaneLabel:capturedLabel
                                   kpIdx:capturedIdx
                                    with:mutate];
      };
  self.onGapPopover(_popoverAnchor, descending, a.time, b.time, iv.curve,
                    iv.intensity, iv.frequency, @[], @[], nil, onCurve,
                    onIntensity, onFrequency,
                    ^(NSInteger _, BOOL __){
                    },
                    onDragBegin, onDragEnd, label, iv, reader, mutator);
}

// Ctrl+click on a gap → flip `endpointsLinked`. Linking ON collapses the
// second endpoint's values to match the first (matches Basic's
// _toggleHoldLink). Unlink leaves values alone but resets curve to Linear.
- (void)_toggleLinkForLabel:(NSString *)label kpIdx:(NSInteger)aIdx {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].label isEqualToString:label])
      continue;
    KKLane *src = lanes[i];
    if (aIdx < 0 || aIdx + 1 >= (NSInteger)src.keyposes.count)
      return;
    KKLane *nl = [src copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    KKKeyPose *a = kps[aIdx];
    KKKeyPose *b = kps[aIdx + 1];
    KKInterval *iv = [a.outgoing copy] ?: [[KKInterval alloc] init];
    BOOL newLinked = !iv.endpointsLinked;
    iv.endpointsLinked = newLinked;
    if (!newLinked)
      iv.curve = KKIntervalCurveLinear;
    KKKeyPose *newA = [KKKeyPose keyposeAtTime:a.time values:a.values];
    newA.outgoing = iv;
    kps[aIdx] = newA;
    if (newLinked) {
      KKKeyPose *newB = [KKKeyPose keyposeAtTime:b.time values:a.values];
      newB.outgoing = b.outgoing;
      kps[aIdx + 1] = newB;
    }
    nl.keyposes = kps;
    lanes[i] = nl;
    changed = YES;
    break;
  }
  if (!changed)
    return;
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Bulk-edit fan-out: if the clicked gap is in the multi-select, apply the
// mutation to every selected gap; otherwise it's a single-target edit.
- (void)_mutateIntervalInLaneLabel:(NSString *)label
                             kpIdx:(NSInteger)aIdx
                              with:(void (^)(KKInterval *iv))mut {
  NSString *clickedKey = [self _gapKeyForLabel:label aIdx:aIdx];
  NSArray<NSString *> *targetKeys = [_selectedGaps containsObject:clickedKey]
                                        ? _selectedGaps.allObjects
                                        : @[ clickedKey ];

  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *byLabel =
      [NSMutableDictionary dictionary];
  for (NSString *key in targetKeys) {
    NSString *kLabel;
    NSInteger kIdx;
    if (![self _decodeSelectionKey:key label:&kLabel kpIdx:&kIdx])
      continue;
    NSMutableArray *arr = byLabel[kLabel];
    if (!arr) {
      arr = [NSMutableArray array];
      byLabel[kLabel] = arr;
    }
    [arr addObject:@(kIdx)];
  }
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    NSMutableArray<NSNumber *> *indices = byLabel[lanes[i].label];
    if (indices.count == 0)
      continue;
    KKLane *nl = [lanes[i] copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    BOOL laneChanged = NO;
    for (NSNumber *n in indices) {
      NSInteger idx = n.integerValue;
      if (idx < 0 || idx + 1 >= (NSInteger)kps.count)
        continue;
      KKKeyPose *src = kps[idx];
      KKKeyPose *newKP = [KKKeyPose keyposeAtTime:src.time values:src.values];
      KKInterval *iv = [src.outgoing copy] ?: [[KKInterval alloc] init];
      mut(iv);
      newKP.outgoing = iv;
      kps[idx] = newKP;
      laneChanged = YES;
    }
    if (laneChanged) {
      nl.keyposes = kps;
      lanes[i] = nl;
      changed = YES;
    }
  }
  if (!changed)
    return;
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

@end
