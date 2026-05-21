/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineAdvancedView_Private.h"

#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

@implementation KKTimelineAdvancedView (Popovers)

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
  CGFloat x = [self _xForFrac:frac inTracks:tracks];
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
  // *exactly* this time goes into the active zone (editable + mini-canvas
  // handle visible). Same-group lanes without a co-time KP go into
  // excludedLabels — shown as the "available zone" row with an "Animate"
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
    if (!match) {
      [excludedLabels addObject:l.label];
      continue;
    }
    KKLane *display = [KKLane laneWithLabel:l.label];
    display.valueType = l.valueType;
    display.componentMin = l.componentMin;
    display.componentMax = l.componentMax;
    display.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:match.values] ];
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
    [s _addKeyposeAtFrac:s->_currentPopoverFrac forLabel:lab];
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
                      onValue, onAnimate, onDragBegin, onDragEnd);
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

// Equal endpoints → modulation pills (Wiggle / Oscillate / Handheld) — curve
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
  CGFloat xA = [self _xForFrac:a.time inTracks:tracks];
  CGFloat xB = [self _xForFrac:b.time inTracks:tracks];
  CGFloat midX = (xA + xB) * 0.5;
  if (!_popoverAnchor) {
    _popoverAnchor = [[NSView alloc] initWithFrame:NSZeroRect];
    [self addSubview:_popoverAnchor positioned:NSWindowBelow relativeTo:nil];
  }
  _popoverAnchor.frame = NSMakeRect(midX - 1.0, NSMidY(row) - 1.0, 2.0, 2.0);

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
    self.onHoldModulationPopover(
        _popoverAnchor, iv.modulation, iv.modulationIntensity,
        iv.modulationFrequency, iv.modulationSeed, iv.modulationLinked,
        showsModLinked, partCompoundLabels, partCompoundStates, partRebuilder,
        onModulation, onIntensity, onFrequency, onSeed, onLinked,
        onParticipation, onDragBegin, onDragEnd);
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
  self.onGapPopover(_popoverAnchor, descending, iv.curve, iv.intensity,
                    iv.frequency, @[], @[], onCurve, onIntensity, onFrequency,
                    ^(NSInteger _, BOOL __){
                    },
                    onDragBegin, onDragEnd);
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
