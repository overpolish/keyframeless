/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineLanesView.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKTimelineBasicView.h"
#import "KKTimelineLanesView_Popovers.h"
#import "KKTimelineLanesView_Private.h"
#import <KeyframelessKit/KKLog.h>

@implementation KKTimelineLanesView

- (instancetype)initWithAvailableLanes:(NSArray<KKLane *> *)availableLanes
                              timeline:(KKTimeline *)timeline {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _availableLanes = [availableLanes
        sortedArrayUsingComparator:^NSComparisonResult(KKLane *a, KKLane *b) {
          return [a.label localizedCaseInsensitiveCompare:b.label];
        }];
    _timeline = [self _timelineSeededFrom:timeline];
    _miniCanvasClipAspect = 16.0 / 9.0;
    _laneRows = [NSMutableDictionary dictionary];
    [self _buildUI];
    [self _refresh];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)_buildUI {
  _laneStack = [NSStackView stackViewWithViews:@[]];
  _laneStack.translatesAutoresizingMaskIntoConstraints = NO;
  _laneStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  _laneStack.alignment = NSLayoutAttributeLeading;
  _laneStack.spacing = 0;
  _laneStack.edgeInsets = NSEdgeInsetsZero;
  [_laneStack setContentHuggingPriority:NSLayoutPriorityRequired
                         forOrientation:NSLayoutConstraintOrientationVertical];
  [self addSubview:_laneStack];

  NSView *footerRow = [[NSView alloc] init];
  footerRow.translatesAutoresizingMaskIntoConstraints = NO;
  _footerRow = footerRow;
  [self addSubview:footerRow];

  NSTextField *animatedLabel = [NSTextField labelWithString:@"Animated"];
  animatedLabel.translatesAutoresizingMaskIntoConstraints = NO;
  animatedLabel.font = [NSFont systemFontOfSize:KKFontSizeSM
                                         weight:NSFontWeightMedium];
  animatedLabel.textColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.5];
  [footerRow addSubview:animatedLabel];

  _dropdownTrigger = [[_KKDropdownTrigger alloc] init];
  _dropdownTrigger.translatesAutoresizingMaskIntoConstraints = NO;
  [footerRow addSubview:_dropdownTrigger];

  __weak typeof(self) weak = self;
  __weak _KKDropdownTrigger *weakTrigger = _dropdownTrigger;
  _dropdownTrigger.onTapped = ^{
    __strong typeof(weak) s = weak;
    __strong _KKDropdownTrigger *trigger = weakTrigger;
    if (!s || !trigger)
      return;
    // Defer by one run-loop cycle so any in-flight mouseDown event (e.g. from
    // sendEvent: during joyride click forwarding) is fully consumed before
    // NSPopoverBehaviorTransient installs its outside-click monitor.
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong typeof(weak) s2 = weak;
      __strong _KKDropdownTrigger *t2 = weakTrigger;
      if (s2 && t2)
        [s2 _showManagePopoverFromView:t2];
    });
  };

  _centeredArea = [[NSView alloc] init];
  _centeredArea.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_centeredArea];

  _hintLabel = [NSTextField labelWithString:@"No animated properties"];
  _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
  _hintLabel.font = [NSFont systemFontOfSize:KKFontSizeSM
                                      weight:NSFontWeightRegular];
  _hintLabel.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.4];
  _hintLabel.alignment = NSTextAlignmentCenter;
  [_centeredArea addSubview:_hintLabel];

  [NSLayoutConstraint activateConstraints:@[
    [_laneStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_laneStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_laneStack.topAnchor constraintEqualToAnchor:self.topAnchor],

    [footerRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [footerRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [footerRow.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    [footerRow.heightAnchor constraintEqualToConstant:kFooterH],

    [animatedLabel.leadingAnchor constraintEqualToAnchor:footerRow.leadingAnchor
                                                constant:KKPaddingLG],
    [animatedLabel.centerYAnchor
        constraintEqualToAnchor:footerRow.centerYAnchor],

    [_dropdownTrigger.leadingAnchor
        constraintEqualToAnchor:animatedLabel.trailingAnchor
                       constant:KKSpacingMD],
    [_dropdownTrigger.trailingAnchor
        constraintEqualToAnchor:footerRow.trailingAnchor
                       constant:-KKPaddingLG],
    [_dropdownTrigger.topAnchor constraintEqualToAnchor:footerRow.topAnchor],
    [_dropdownTrigger.bottomAnchor
        constraintEqualToAnchor:footerRow.bottomAnchor],

    [_centeredArea.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_centeredArea.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_centeredArea.topAnchor constraintEqualToAnchor:_laneStack.bottomAnchor],
    [_centeredArea.bottomAnchor constraintEqualToAnchor:footerRow.topAnchor],

    [_hintLabel.centerXAnchor
        constraintEqualToAnchor:_centeredArea.centerXAnchor],
    [_hintLabel.centerYAnchor
        constraintEqualToAnchor:_centeredArea.centerYAnchor],
  ]];

  _basicGraph =
      [[KKTimelineBasicView alloc] initWithAvailableLanes:_availableLanes
                                                 timeline:_timeline];
  _basicGraph.translatesAutoresizingMaskIntoConstraints = NO;
  _basicGraph.hidden = YES;
  [_centeredArea addSubview:_basicGraph
                 positioned:NSWindowBelow
                 relativeTo:_hintLabel];
  [NSLayoutConstraint activateConstraints:@[
    [_basicGraph.leadingAnchor
        constraintEqualToAnchor:_centeredArea.leadingAnchor],
    [_basicGraph.trailingAnchor
        constraintEqualToAnchor:_centeredArea.trailingAnchor],
    [_basicGraph.topAnchor constraintEqualToAnchor:_centeredArea.topAnchor],
    [_basicGraph.bottomAnchor
        constraintEqualToAnchor:_centeredArea.bottomAnchor],
  ]];

  __weak typeof(self) weakSelf = self;
  _basicGraph.onTimelineMutated = ^(KKTimeline *updated) {
    __strong typeof(weakSelf) s = weakSelf;
    if (!s)
      return;
    s->_timeline = updated;
    [s _refresh];
    if (s->_onTimelineMutated)
      s->_onTimelineMutated(updated);
  };
  _basicGraph.onDragBegin = ^{
    __strong typeof(weakSelf) s = weakSelf;
    if (s && s->_onDragBegin)
      s->_onDragBegin();
  };
  _basicGraph.onDragEnd = ^{
    __strong typeof(weakSelf) s = weakSelf;
    if (s && s->_onDragEnd)
      s->_onDragEnd();
  };
  _basicGraph.onScrub = ^(double frac) {
    __strong typeof(weakSelf) s = weakSelf;
    if (s && s->_onScrub)
      s->_onScrub(frac);
  };
  _basicGraph.onZoomChanged = ^(BOOL zoomed) {
    __strong typeof(weakSelf) s = weakSelf;
    if (s && s->_onZoomChanged)
      s->_onZoomChanged(zoomed);
  };
  _basicGraph.onBoundaryValuePopover =
      ^(NSView *anchor, NSArray<KKLane *> *displayLanes, double frac,
        NSArray<NSString *> *excludedLabels,
        void (^onValue)(NSString *, NSArray<NSNumber *> *),
        void (^onAnimate)(NSString *), void (^onDragBegin)(void),
        void (^onDragEnd)(void)) {
        __strong typeof(weakSelf) s = weakSelf;
        [s _presentBoundaryValuePopoverFromAnchor:anchor
                                     displayLanes:displayLanes
                                         fraction:frac
                                   excludedLabels:excludedLabels
                                          onValue:onValue
                                        onAnimate:onAnimate
                                      onDragBegin:onDragBegin
                                        onDragEnd:onDragEnd];
      };
  _basicGraph.onGapPopover =
      ^(NSView *anchor, BOOL animateOut, KKIntervalCurve curve,
        double intensity, double frequency, NSArray<NSString *> *partLabels,
        NSArray<NSNumber *> *partStates, void (^onCurve)(KKIntervalCurve),
        void (^onIntensity)(double), void (^onFrequency)(double),
        void (^onParticipation)(NSInteger, BOOL), void (^onDragBegin)(void),
        void (^onDragEnd)(void)) {
        __strong typeof(weakSelf) s = weakSelf;
        [s _presentGapPopoverFromAnchor:anchor
                             animateOut:animateOut
                                  curve:curve
                              intensity:intensity
                              frequency:frequency
                             partLabels:partLabels
                             partStates:partStates
                                onCurve:onCurve
                            onIntensity:onIntensity
                            onFrequency:onFrequency
                        onParticipation:onParticipation
                            onDragBegin:onDragBegin
                              onDragEnd:onDragEnd];
      };
  _basicGraph.onHoldModulationPopover =
      ^(NSView *anchor, KKIntervalModulation modulation, double intensity,
        double frequency, uint32_t seed, BOOL linked, BOOL showsLinked,
        NSArray<NSString *> *partLabels, NSArray<NSNumber *> *partStates,
        void (^onModulation)(KKIntervalModulation), void (^onIntensity)(double),
        void (^onFrequency)(double), void (^onSeed)(uint32_t),
        void (^onLinked)(BOOL), void (^onParticipation)(NSInteger, BOOL),
        void (^onDragBegin)(void), void (^onDragEnd)(void)) {
        __strong typeof(weakSelf) s = weakSelf;
        [s _presentHoldModulationPopoverFromAnchor:anchor
                                        modulation:modulation
                                         intensity:intensity
                                         frequency:frequency
                                              seed:seed
                                            linked:linked
                                       showsLinked:showsLinked
                                        partLabels:partLabels
                                        partStates:partStates
                                      onModulation:onModulation
                                       onIntensity:onIntensity
                                       onFrequency:onFrequency
                                            onSeed:onSeed
                                          onLinked:onLinked
                                   onParticipation:onParticipation
                                       onDragBegin:onDragBegin
                                         onDragEnd:onDragEnd];
      };
}

- (void)_refresh {
  NSMutableArray<NSString *> *toRemove = [NSMutableArray array];
  for (NSString *label in _laneRows) {
    if (![self _isAnimatableLabel:label])
      [toRemove addObject:label];
  }
  for (NSString *label in toRemove) {
    _KKLaneRow *row = _laneRows[label];
    [_laneStack removeArrangedSubview:row];
    [row removeFromSuperview];
    [_laneRows removeObjectForKey:label];
  }

  // Basic mode shows one shared motion graph (not per-property rows): the
  // graph fills the content area whenever ≥1 property is animatable.
  BOOL anyOptedIn = NO;
  for (KKLane *tmpl in _availableLanes) {
    if ([self _isAnimatableLabel:tmpl.label]) {
      anyOptedIn = YES;
      break;
    }
  }
  _hintLabel.hidden = anyOptedIn;
  _basicGraph.hidden = !anyOptedIn;
  [_basicGraph applyTimeline:_timeline];

  NSMutableArray<NSString *> *opted = [NSMutableArray array];
  for (KKLane *tmpl in _availableLanes)
    if ([self _isAnimatableLabel:tmpl.label])
      [opted addObject:tmpl.label];
  _dropdownTrigger.selectedLabels = opted;
  [_dropdownTrigger setNeedsDisplay:YES];

  if (_openManageView)
    [_openManageView updateCheckedLabels:[self _optedInLabelsSet]];
  // Only the constants popover tracks the un-opted set. A boundary-value
  // popover has caller-supplied display lanes; clobbering them here is what
  // made Radius (the un-opted lane) replace Crop after a crop edit.
  if (_openStaticView && !_openStaticIsBoundary)
    [_openStaticView updateUnoptedLanes:[self _unoptedLanes]];
}

- (nullable KKLane *)_laneForLabel:(NSString *)label {
  for (KKLane *lane in _timeline.lanes)
    if ([lane.label isEqualToString:label])
      return lane;
  return nil;
}

- (nullable KKLane *)_templateForLabel:(NSString *)label {
  for (KKLane *tmpl in _availableLanes)
    if ([tmpl.label isEqualToString:label])
      return tmpl;
  return nil;
}

// Every available property ALWAYS has a lane (single keypose at t=0 is its
// constant value). `lane.enabled` means "animatable" (shown in the sequencer,
// checked in the dropdown) and is toggled ONLY by the dropdown — editing a
// value never changes it. This returns `src` with any missing lanes added as
// disabled (constant) lanes seeded to the template default.
- (KKTimeline *)_timelineSeededFrom:(KKTimeline *)src {
  KKTimeline *out = [src copy] ?: [KKTimeline timeline];
  NSMutableArray<KKLane *> *lanes =
      [out.lanes mutableCopy] ?: [NSMutableArray array];
  for (KKLane *tmpl in _availableLanes) {
    NSInteger presentIdx = NSNotFound;
    for (NSInteger i = 0; i < (NSInteger)lanes.count; i++)
      if ([lanes[i].label isEqualToString:tmpl.label]) {
        presentIdx = i;
        break;
      }
    if (presentIdx != NSNotFound) {
      // valueType / component bounds are canonical (defined by the plugin
      // template, not user-editable). Re-assert them so lanes from older
      // blobs that didn't serialize these still render correctly.
      KKLane *fixed = [lanes[presentIdx] copy];
      fixed.valueType = tmpl.valueType;
      fixed.componentMin = tmpl.componentMin;
      fixed.componentMax = tmpl.componentMax;
      lanes[presentIdx] = fixed;
      continue;
    }
    KKLane *lane = [KKLane laneWithLabel:tmpl.label];
    lane.valueType = tmpl.valueType;
    lane.componentMin = tmpl.componentMin;
    lane.componentMax = tmpl.componentMax;
    lane.enabled = NO; // constant until the dropdown makes it animatable
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                          values:[self _defaultValuesForLabel:
                                                           tmpl.label]]];
    [lanes addObject:lane];
  }
  out.lanes = lanes;
  return out;
}

// Animatable == the lane exists and is enabled (dropdown-controlled).
- (BOOL)_isAnimatableLabel:(NSString *)label {
  KKLane *lane = [self _laneForLabel:label];
  return lane != nil && lane.enabled;
}

- (NSSet<NSString *> *)_optedInLabelsSet {
  NSMutableSet<NSString *> *set = [NSMutableSet set];
  for (KKLane *lane in _timeline.lanes)
    if (lane.enabled)
      [set addObject:lane.label];
  return [set copy];
}

// The constants editor shows every non-animatable property's lane (with its
// current value, so the editor reflects/edits the real constant).
- (NSArray<KKLane *> *)_unoptedLanes {
  NSMutableArray<KKLane *> *result = [NSMutableArray array];
  for (KKLane *tmpl in _availableLanes) {
    KKLane *lane = [self _laneForLabel:tmpl.label];
    if (lane && !lane.enabled)
      [result addObject:lane];
  }
  return result;
}

- (NSView *)footerView {
  return _footerRow;
}

- (nullable NSView *)laneRowViewForLabel:(NSString *)label {
  return _laneRows[label];
}

- (KKTimeline *)currentTimeline {
  return _timeline;
}

- (NSArray<NSNumber *> *)_defaultValuesForLabel:(NSString *)label {
  KKLane *tmpl = [self _templateForLabel:label];
  if (!tmpl)
    return @[ @0.0 ];
  NSArray<NSNumber *> *tmplDefault = tmpl.keyposes.firstObject.values;
  if (tmplDefault.count)
    return tmplDefault;
  if (tmpl.valueType == KKLaneValueTypeCrop)
    return @[ @1.0, @1.0, @0.0, @0.0 ];
  double def =
      tmpl.componentMin.firstObject ? tmpl.componentMin[0].doubleValue : 0.0;
  return @[ @(def) ];
}

// Replace the lane for `label` with `lane` (always present after seeding),
// persist, and refresh. Single funnel for both animatable + value edits.
- (void)_replaceLane:(KKLane *)lane forLabel:(NSString *)label {
  KKTimeline *updated = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [updated.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([lanes[i].label isEqualToString:label]) {
      lanes[i] = lane;
      break;
    }
  }
  updated.lanes = lanes;
  _timeline = updated;
  [self _refresh];
  if (_onTimelineMutated)
    _onTimelineMutated(updated);
}

// The settled (Hold) value of a lane, independent of which phases it has.
// Mirrors KKTimelineBasicView's _holdValuesForLane: without the shape struct.
- (NSArray<NSNumber *> *)_holdValuesOfLane:(KKLane *)lane
                                  forLabel:(NSString *)label {
  NSArray<KKKeyPose *> *k = lane.keyposes;
  if (k.count == 0)
    return [self _defaultValuesForLabel:label];
  if (k.count == 1)
    return k.firstObject.values;
  static const double kE = 1.0e-4;
  BOOL inEnabled = k.firstObject.time < kE;
  return k[inEnabled ? 1 : 0].values; // the hold-start keypose
}

// Dropdown only: flip a property between animatable and constant. Never
// changes the value — but it does (re)shape the keyposes: turning animatable
// seeds the always-present 2-keypose Hold pair (both = the current constant,
// so every phase starts at the constant, not a stray 0); turning it off
// collapses back to a single constant keypose at the Hold value.
- (void)_setLaneAnimatable:(BOOL)animatable forLabel:(NSString *)label {
  KKLane *lane = [[self _laneForLabel:label] copy];
  if (!lane || lane.enabled == animatable)
    return;
  lane.enabled = animatable;
  if (animatable) {
    // Keep in sync with KKTimelineBasicView's kDefaultInEnd/kDefaultOutStart.
    static const double kDefInEnd = 0.22, kDefOutStart = 0.78;
    NSArray<NSNumber *> *v = [self _holdValuesOfLane:lane forLabel:label];
    KKKeyPose *hs = [KKKeyPose keyposeAtTime:kDefInEnd values:v];
    hs.outgoing = [[KKInterval alloc] init]; // the always-present Hold gap
    KKKeyPose *he = [KKKeyPose keyposeAtTime:kDefOutStart values:v];
    lane.keyposes = @[ hs, he ];
  } else {
    NSArray<NSNumber *> *v = [self _holdValuesOfLane:lane forLabel:label];
    lane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:v] ];
    _KKLaneRow *row = _laneRows[label];
    if (row) {
      [_laneStack removeArrangedSubview:row];
      [row removeFromSuperview];
      [_laneRows removeObjectForKey:label];
    }
  }
  [self _replaceLane:lane forLabel:label];
}

// Value editor (mini canvas / fields): set the property's constant value
// without changing its animatable status.
- (void)_setLaneValues:(NSArray<NSNumber *> *)values
              forLabel:(NSString *)label {
  KKLane *existing = [self _laneForLabel:label];
  if (!existing)
    return;
  KKLane *lane = [KKLane laneWithLabel:label];
  lane.valueType = existing.valueType;
  lane.componentMin = existing.componentMin;
  lane.componentMax = existing.componentMax;
  lane.enabled = existing.enabled;
  [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:values]];
  [self _replaceLane:lane forLabel:label];
}

- (BOOL)hasUnoptedLanes {
  return [self _unoptedLanes].count > 0;
}

- (void)applyTimeline:(KKTimeline *)timeline {
  _timeline = [self _timelineSeededFrom:timeline];
  [self _refresh];
}

- (void)setClipDurationSeconds:(double)seconds {
  [_basicGraph setClipDurationSeconds:seconds];
}

- (void)setPlayheadFraction:(double)frac {
  [_basicGraph setPlayheadFraction:frac];
}

- (void)resetZoom {
  [_basicGraph resetZoom];
}

@end
