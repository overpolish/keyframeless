/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineLanesView.h"
#import "KKCheckboxRowView.h"
#import "KKLocalized.h"
#import "KKSegmentEditView.h"
#import "KKTimelineAdvancedView.h"
#import "KKTimelineBasicView.h"
#import "KKTimelineLanesView_Popovers.h"
#import "KKTimelineLanesView_Private.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
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

  NSTextField *animatedLabel = [NSTextField
      labelWithString:KKLoc(@"Animated", @"Header: animated properties.")];
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

  _hintLabel = [NSTextField
      labelWithString:KKLoc(@"No animated properties",
                            @"Empty state: no animated properties.")];
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
    [s _republishBoundaryRequestIfOpen];
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
    if (!s)
      return;
    s->_basicZoomed = zoomed;
    if (s->_activeTab == 0 && s->_onZoomChanged)
      s->_onZoomChanged(zoomed);
  };
  _basicGraph.onBoundaryValuePopover =
      ^(NSView *anchor, NSArray<KKLane *> *displayLanes, double frac,
        NSArray<NSString *> *excludedLabels,
        void (^onValue)(NSString *, NSArray<NSNumber *> *),
        void (^onAnimate)(NSString *), void (^onRemove)(NSString *),
        void (^onDragBegin)(void), void (^onDragEnd)(void)) {
        __strong typeof(weakSelf) s = weakSelf;
        [s _presentBoundaryValuePopoverFromAnchor:anchor
                                     displayLanes:displayLanes
                                         fraction:frac
                                   excludedLabels:excludedLabels
                                          onValue:onValue
                                        onAnimate:onAnimate
                                         onRemove:onRemove
                                      onDragBegin:onDragBegin
                                        onDragEnd:onDragEnd];
      };
  _basicGraph.onRequestClosePopover = ^{
    __strong typeof(weakSelf) s = weakSelf;
    if (s->_openContentPopover.isShown)
      [s->_openContentPopover close];
  };
  _basicGraph.onGapPopover = ^(
      NSView *anchor, BOOL animateOut, double startFraction, double endFraction,
      KKIntervalCurve curve, double intensity, double frequency,
      NSArray<NSString *> *partLabels, NSArray<NSNumber *> *partStates,
      NSArray<NSNumber *> * (^partRebuilder)(void),
      void (^onCurve)(KKIntervalCurve), void (^onIntensity)(double),
      void (^onFrequency)(double), void (^onParticipation)(NSInteger, BOOL),
      void (^onDragBegin)(void), void (^onDragEnd)(void), NSString *laneLabel,
      KKInterval *representative, KKGapIntervalReader reader,
      KKGapIntervalMutator mutator) {
    __strong typeof(weakSelf) s = weakSelf;
    KKGapPopoverPhase phase =
        animateOut ? KKGapPopoverPhaseBasicOut : KKGapPopoverPhaseBasicIn;
    [s _presentGapPopoverFromAnchor:anchor
                         animateOut:animateOut
                      startFraction:startFraction
                        endFraction:endFraction
                              curve:curve
                          intensity:intensity
                          frequency:frequency
                         partLabels:partLabels
                         partStates:partStates
                      partRebuilder:partRebuilder
                            onCurve:onCurve
                        onIntensity:onIntensity
                        onFrequency:onFrequency
                    onParticipation:onParticipation
                        onDragBegin:onDragBegin
                          onDragEnd:onDragEnd
                              phase:phase
                          laneLabel:laneLabel
                     representative:representative
                     intervalReader:reader
                    intervalMutator:mutator];
  };
  _advancedGraph =
      [[KKTimelineAdvancedView alloc] initWithAvailableLanes:_availableLanes
                                                    timeline:_timeline];
  _advancedGraph.translatesAutoresizingMaskIntoConstraints = NO;
  _advancedGraph.hidden = YES;
  [_centeredArea addSubview:_advancedGraph
                 positioned:NSWindowBelow
                 relativeTo:_hintLabel];
  [NSLayoutConstraint activateConstraints:@[
    [_advancedGraph.leadingAnchor
        constraintEqualToAnchor:_centeredArea.leadingAnchor],
    [_advancedGraph.trailingAnchor
        constraintEqualToAnchor:_centeredArea.trailingAnchor],
    [_advancedGraph.topAnchor constraintEqualToAnchor:_centeredArea.topAnchor],
    [_advancedGraph.bottomAnchor
        constraintEqualToAnchor:_centeredArea.bottomAnchor],
  ]];
  _advancedGraph.onZoomChanged = ^(BOOL zoomed) {
    __strong typeof(weakSelf) s = weakSelf;
    if (!s)
      return;
    s->_advancedZoomed = zoomed;
    if (s->_activeTab == 1 && s->_onZoomChanged)
      s->_onZoomChanged(zoomed);
  };
  _advancedGraph.onSelectionChanged = ^{
    __strong typeof(weakSelf) s = weakSelf;
    if (!s)
      return;
    if (s->_clearSelectionButton)
      s->_clearSelectionButton.enabled = (s->_advancedGraph.selectionCount > 0);
    if (s->_onAdvancedSelectionChanged)
      s->_onAdvancedSelectionChanged(s->_advancedGraph.selectedPillKeys,
                                     s->_advancedGraph.selectedGapKeys);
  };
  _advancedGraph.onTimelineMutated = ^(KKTimeline *updated) {
    __strong typeof(weakSelf) s = weakSelf;
    if (!s)
      return;
    s->_timeline = updated;
    [s _refresh];
    [s _republishBoundaryRequestIfOpen];
    if (s->_onTimelineMutated)
      s->_onTimelineMutated(updated);
  };
  _advancedGraph.onDragBegin = ^{
    __strong typeof(weakSelf) s = weakSelf;
    if (s && s->_onDragBegin)
      s->_onDragBegin();
  };
  _advancedGraph.onDragEnd = ^{
    __strong typeof(weakSelf) s = weakSelf;
    if (s && s->_onDragEnd)
      s->_onDragEnd();
  };
  _advancedGraph.onScrub = ^(double frac) {
    __strong typeof(weakSelf) s = weakSelf;
    if (s && s->_onScrub)
      s->_onScrub(frac);
  };
  _advancedGraph.onGapPopover = ^(
      NSView *anchor, BOOL animateOut, double startFraction, double endFraction,
      KKIntervalCurve curve, double intensity, double frequency,
      NSArray<NSString *> *partLabels, NSArray<NSNumber *> *partStates,
      NSArray<NSNumber *> * (^partRebuilder)(void),
      void (^onCurve)(KKIntervalCurve), void (^onIntensity)(double),
      void (^onFrequency)(double), void (^onParticipation)(NSInteger, BOOL),
      void (^onDragBegin)(void), void (^onDragEnd)(void), NSString *laneLabel,
      KKInterval *representative, KKGapIntervalReader reader,
      KKGapIntervalMutator mutator) {
    __strong typeof(weakSelf) s = weakSelf;
    [s _presentGapPopoverFromAnchor:anchor
                         animateOut:animateOut
                      startFraction:startFraction
                        endFraction:endFraction
                              curve:curve
                          intensity:intensity
                          frequency:frequency
                         partLabels:partLabels
                         partStates:partStates
                      partRebuilder:partRebuilder
                            onCurve:onCurve
                        onIntensity:onIntensity
                        onFrequency:onFrequency
                    onParticipation:onParticipation
                        onDragBegin:onDragBegin
                          onDragEnd:onDragEnd
                              phase:KKGapPopoverPhaseAdvanced
                          laneLabel:laneLabel
                     representative:representative
                     intervalReader:reader
                    intervalMutator:mutator];
  };
  _advancedGraph.onHoldModulationPopover = ^(
      NSView *anchor, double startFraction, double endFraction,
      KKIntervalModulation modulation, double intensity, double frequency,
      uint32_t seed, BOOL linked, BOOL showsLinked,
      NSArray<NSArray<NSString *> *> *partLabels,
      NSArray<NSArray<NSNumber *> *> *partStates,
      NSArray<NSArray<NSNumber *> *> * (^partRebuilder)(void),
      void (^onModulation)(KKIntervalModulation), void (^onIntensity)(double),
      void (^onFrequency)(double), void (^onSeed)(uint32_t),
      void (^onLinked)(BOOL), void (^onParticipation)(NSInteger, BOOL),
      void (^onDragBegin)(void), void (^onDragEnd)(void), NSString *laneLabel,
      KKInterval *representative, KKGapIntervalReader reader,
      KKGapIntervalMutator mutator) {
    __strong typeof(weakSelf) s = weakSelf;
    [s _presentHoldModulationPopoverFromAnchor:anchor
                                 startFraction:startFraction
                                   endFraction:endFraction
                                    modulation:modulation
                                     intensity:intensity
                                     frequency:frequency
                                          seed:seed
                                        linked:linked
                                   showsLinked:showsLinked
                                    partLabels:partLabels
                                    partStates:partStates
                                 partRebuilder:partRebuilder
                                  onModulation:onModulation
                                   onIntensity:onIntensity
                                   onFrequency:onFrequency
                                        onSeed:onSeed
                                      onLinked:onLinked
                               onParticipation:onParticipation
                                   onDragBegin:onDragBegin
                                     onDragEnd:onDragEnd
                                         phase:KKGapPopoverPhaseHoldModulation
                                     laneLabel:laneLabel
                                representative:representative
                                intervalReader:reader
                               intervalMutator:mutator];
  };
  _advancedGraph.onValuePopover =
      ^(NSView *anchor, NSArray<KKLane *> *displayLanes, double frac,
        NSArray<NSString *> *excludedLabels,
        void (^onValue)(NSString *, NSArray<NSNumber *> *),
        void (^onAnimate)(NSString *), void (^onRemove)(NSString *),
        void (^onDragBegin)(void), void (^onDragEnd)(void)) {
        __strong typeof(weakSelf) s = weakSelf;
        [s _presentBoundaryValuePopoverFromAnchor:anchor
                                     displayLanes:displayLanes
                                         fraction:frac
                                   excludedLabels:excludedLabels
                                          onValue:onValue
                                        onAnimate:onAnimate
                                         onRemove:onRemove
                                      onDragBegin:onDragBegin
                                        onDragEnd:onDragEnd];
      };
  _advancedGraph.onRequestClosePopover = ^{
    __strong typeof(weakSelf) s = weakSelf;
    if (s->_openContentPopover.isShown)
      [s->_openContentPopover close];
  };

  _basicGraph.onHoldModulationPopover = ^(
      NSView *anchor, double startFraction, double endFraction,
      KKIntervalModulation modulation, double intensity, double frequency,
      uint32_t seed, BOOL linked, BOOL showsLinked,
      NSArray<NSArray<NSString *> *> *partLabels,
      NSArray<NSArray<NSNumber *> *> *partStates,
      NSArray<NSArray<NSNumber *> *> * (^partRebuilder)(void),
      void (^onModulation)(KKIntervalModulation), void (^onIntensity)(double),
      void (^onFrequency)(double), void (^onSeed)(uint32_t),
      void (^onLinked)(BOOL), void (^onParticipation)(NSInteger, BOOL),
      void (^onDragBegin)(void), void (^onDragEnd)(void), NSString *laneLabel,
      KKInterval *representative, KKGapIntervalReader reader,
      KKGapIntervalMutator mutator) {
    __strong typeof(weakSelf) s = weakSelf;
    [s _presentHoldModulationPopoverFromAnchor:anchor
                                 startFraction:startFraction
                                   endFraction:endFraction
                                    modulation:modulation
                                     intensity:intensity
                                     frequency:frequency
                                          seed:seed
                                        linked:linked
                                   showsLinked:showsLinked
                                    partLabels:partLabels
                                    partStates:partStates
                                 partRebuilder:partRebuilder
                                  onModulation:onModulation
                                   onIntensity:onIntensity
                                   onFrequency:onFrequency
                                        onSeed:onSeed
                                      onLinked:onLinked
                               onParticipation:onParticipation
                                   onDragBegin:onDragBegin
                                     onDragEnd:onDragEnd
                                         phase:KKGapPopoverPhaseHoldModulation
                                     laneLabel:laneLabel
                                representative:representative
                                intervalReader:reader
                               intervalMutator:mutator];
  };
}

- (void)_refresh {
  // Basic mode shows one shared motion graph (not per-property rows): the
  // graph fills the content area whenever ≥1 property is animatable.
  BOOL anyOptedIn = NO;
  for (KKLane *tmpl in _availableLanes) {
    if ([self _isAnimatableLabel:tmpl.label]) {
      anyOptedIn = YES;
      break;
    }
  }
  BOOL showBasic = anyOptedIn && _activeTab == 0;
  BOOL showAdvanced = anyOptedIn && _activeTab == 1;
  _hintLabel.hidden = anyOptedIn;
  _basicGraph.hidden = !showBasic;
  _advancedGraph.hidden = !showAdvanced;
  [_basicGraph applyTimeline:_timeline];
  [_advancedGraph applyTimeline:_timeline];

  // Now that the sub-views' _timeline ivars are fresh, refresh any open
  // hold-modulation popover's participation pills. The rebuilder closure
  // reads from those ivars - running it before applyTimeline pushed the
  // new blob downstream produced stale states (e.g. cmd-Z left the pill
  // bar showing the post-edit state instead of the undone one).
  if (_openHoldModEditor && _openHoldModRebuilder) {
    NSArray<NSArray<NSNumber *> *> *fresh = _openHoldModRebuilder();
    if (fresh)
      [_openHoldModEditor applyParticipationCompoundStates:fresh];
  }
  // Linked/seed/intensity/frequency live on KKSegmentEditView's ivars
  // (not extras) - push fresh state from the live interval so cmd-Z lands
  // in the checkbox / seed field / sliders.
  if (_openHoldModEditor && _openHoldModIntervalReader) {
    KKInterval *liveIv = _openHoldModIntervalReader();
    if (liveIv) {
      _openHoldModEditor.curveType = KKModulationToPill(liveIv.modulation);
      _openHoldModEditor.linked = liveIv.modulationLinked;
      _openHoldModEditor.seed = liveIv.modulationSeed;
      _openHoldModEditor.intensity = liveIv.modulationIntensity;
      _openHoldModEditor.frequency = liveIv.modulationFrequency;
    }
  }
  // Same for the In/Out curve (gap) popover's applies-to pills, so cmd-Z keeps
  // them in sync without the user closing and reopening the popover.
  if (_openGapEditor && _openGapRebuilder) {
    NSArray<NSNumber *> *fresh = _openGapRebuilder();
    if (fresh)
      [_openGapEditor applyParticipationStates:fresh];
  }
  // Curve / intensity / frequency live on KKSegmentEditView's ivars (not
  // extras) - push fresh state from the live interval so cmd-Z lands in
  // the visible pills and sliders.
  if (_openGapEditor && _openGapIntervalReader) {
    KKInterval *liveIv = _openGapIntervalReader();
    if (liveIv) {
      _openGapEditor.curveType = (NSInteger)liveIv.curve;
      _openGapEditor.intensity = liveIv.intensity;
      _openGapEditor.frequency = liveIv.frequency;
    }
  }
  // Re-pull state into any KKPopoverExtraRow-conforming extras (the
  // plugin-supplied checkbox/value rows) so cmd-Z lands in their visible
  // state without close/reopen.
  for (NSView *row in _openExtraRows) {
    if ([row respondsToSelector:@selector(popoverDidRefresh)])
      [(id<KKPopoverExtraRow>)row popoverDidRefresh];
  }

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

  // A boundary/value popover is built from a snapshot at open; an external
  // timeline change (cmd-Z / redo) reaches the graphs but not the popover, so
  // re-drive it from the active graph at its open fraction - the active/Animate
  // row split and values rebuild from the new state (e.g. cmd-Z re-adding a
  // keypose flips its row from "+ No keypose here" back to editable).
  // Suppressed briefly after a popover edit so the host's echo write doesn't
  // rebuild rows mid-interaction (add/remove already refresh synchronously).
  if (_openStaticView && _openStaticIsBoundary && _openContentPopover.isShown &&
      anyOptedIn &&
      [NSDate timeIntervalSinceReferenceDate] >=
          _boundaryRedriveSuppressUntil) {
    double f = _openStaticBoundaryFraction;
    if (_activeTab == 1)
      [_advancedGraph requestValuePopoverAtFraction:f];
    else
      [_basicGraph requestValuePopoverAtFraction:f];
  }
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
// checked in the dropdown) and is toggled ONLY by the dropdown - editing a
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
      fixed.componentUnits = tmpl.componentUnits;
      fixed.componentLabels = tmpl.componentLabels;
      fixed.componentLabelColors = tmpl.componentLabelColors;
      lanes[presentIdx] = fixed;
      continue;
    }
    KKLane *lane = [KKLane laneWithLabel:tmpl.label];
    lane.valueType = tmpl.valueType;
    lane.componentMin = tmpl.componentMin;
    lane.componentMax = tmpl.componentMax;
    lane.componentUnits = tmpl.componentUnits;
    lane.componentLabels = tmpl.componentLabels;
    lane.componentLabelColors = tmpl.componentLabelColors;
    lane.enabled = NO; // constant until the dropdown makes it animatable
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                          values:[self _defaultValuesForLabel:
                                                           tmpl.label]]];
    [lanes addObject:lane];
  }
  // Display order: the user's drag-to-reorder list if set, else alphabetical.
  // This is the single chokepoint every view + popover inherits (they all
  // iterate _timeline.lanes in order). Labels present in paramOrder lead in
  // that order; anything not listed (incl. the whole default) falls back to
  // alphabetical after them.
  NSArray<NSString *> *order = out.paramOrder;
  NSMutableDictionary<NSString *, NSNumber *> *rank =
      [NSMutableDictionary dictionaryWithCapacity:order.count];
  for (NSInteger i = 0; i < (NSInteger)order.count; i++)
    if (!rank[order[i]])
      rank[order[i]] = @(i);
  [lanes sortUsingComparator:^NSComparisonResult(KKLane *a, KKLane *b) {
    NSNumber *ra = rank[a.label];
    NSNumber *rb = rank[b.label];
    if (ra && rb)
      return [ra compare:rb];
    if (ra)
      return NSOrderedAscending;
    if (rb)
      return NSOrderedDescending;
    return [a.label localizedCaseInsensitiveCompare:b.label];
  }];
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
    if (lane && !lane.enabled) {
      // aspectLinkable is template metadata (an older persisted blob may lack
      // it), so source it from the template like the keypose popover does -
      // otherwise the constants popover hides the link glyph. aspectLinked is
      // user state and stays the lane's own. Copy so the shared persisted lane
      // isn't mutated.
      if ((tmpl.aspectLinkable && !lane.aspectLinkable) ||
          (tmpl.integerValued && !lane.integerValued)) {
        KKLane *l = [lane copy];
        l.aspectLinkable = tmpl.aspectLinkable;
        l.integerValued = tmpl.integerValued;
        lane = l;
      }
      [result addObject:lane];
    }
  }
  return result;
}

- (NSView *)footerView {
  return _footerRow;
}

- (nullable NSView *)laneRowViewForLabel:(NSString *)label {
  return nil;
}

- (KKTimeline *)currentTimeline {
  return _timeline;
}

- (NSArray<NSString *> *)orderedParamLabels {
  NSMutableSet<NSString *> *avail = [NSMutableSet set];
  for (KKLane *l in _availableLanes)
    [avail addObject:l.label];
  // _timeline.lanes is already in display order (sorted in
  // _timelineSeededFrom:) and - post-seed - contains every available property,
  // so its order is the source of truth for the reorder list.
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (KKLane *l in _timeline.lanes)
    if ([avail containsObject:l.label] && ![out containsObject:l.label])
      [out addObject:l.label];
  for (KKLane *l in _availableLanes)
    if (![out containsObject:l.label])
      [out addObject:l.label];
  return out;
}

- (void)applyParamOrder:(NSArray<NSString *> *)labels {
  KKTimeline *updated = [_timeline copy];
  updated.paramOrder = labels;
  // Re-seed re-sorts lanes through the display chokepoint by the new order.
  _timeline = [self _timelineSeededFrom:updated];
  [self _refresh];
  if (_onTimelineMutated)
    _onTimelineMutated(_timeline);
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
// changes the value - but it does (re)shape the keyposes: turning animatable
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

    // Inherit global In/Out state from existing animated lanes (OR - any
    // lane with In/Out means In/Out is globally on). Without this, a newly
    // animatable lane is always Hold-only even when other lanes have
    // active In/Out phases, which is jarring when the rest of the UI is
    // mid-transition.
    BOOL globalIn = NO, globalOut = NO;
    double tIn = kDefInEnd, tOut = kDefOutStart;
    BOOL tFound = NO;
    // Inherit interval params (curve, intensity, freq, modulation, link) from
    // the first animatable lane so a new lane joins the same In/Hold/Out
    // shape - particularly drift/link state.
    KKInterval *tmplIn = nil, *tmplHold = nil, *tmplOut = nil;
    // Align the new lane's end to whatever the existing animated lanes use, so
    // all lanes' end keyposes line up even if clip/frame duration wasn't known
    // yet when an earlier lane was seeded (which would leave it at 1.0 while a
    // later one lands at outEndFrac). NAN until an existing lane is found.
    double inheritedEndFrac = NAN;
    for (KKLane *l in _timeline.lanes) {
      if (!l.enabled || l.keyposes.count < 2)
        continue;
      NSArray<KKKeyPose *> *kk = l.keyposes;
      if (isnan(inheritedEndFrac))
        inheritedEndFrac = kk.lastObject.time;
      // New model: middle-KP time disambiguates In-only vs Out-only for
      // n==3 (under the old model the first KP's time did, but now both
      // start at t=0).
      NSInteger n = (NSInteger)kk.count;
      BOOL lInEn = NO, lOutEn = NO;
      if (n == 4) {
        lInEn = YES;
        lOutEn = YES;
      } else if (n == 3) {
        if (kk[1].time < 0.5)
          lInEn = YES;
        else
          lOutEn = YES;
      }
      if (lInEn)
        globalIn = YES;
      if (lOutEn)
        globalOut = YES;
      if (!tFound) {
        NSInteger holdStart = lInEn ? 1 : 0;
        NSInteger holdEnd = n - (lOutEn ? 2 : 1);
        if (holdEnd > holdStart) {
          // Inherit the Hold link state from the first existing animated lane -
          // pure-hold lanes included - so a new lane MATCHES the current
          // linked/unlinked choice (Basic: "auto-link iff the others are
          // linked"). Without this, a pure-hold source's link was ignored and
          // the new lane fell back to the fresh=linked default.
          tmplHold = [kk[holdStart].outgoing copy];
          // Boundary times + In/Out interval templates only when the source
          // actually has that phase (≥3 KPs) - pure hold-only lanes sit at
          // [0, outEnd] and would seed silly boundary defaults.
          if (lInEn) {
            tIn = kk[holdStart].time;
            tmplIn = [kk.firstObject.outgoing copy];
          }
          if (lOutEn) {
            tOut = kk[holdEnd].time;
            tmplOut = [kk[holdEnd].outgoing copy];
          }
          tFound = YES;
        }
      }
    }

    // Out-end / hold-end position - one frame before clipEnd so FCP playhead
    // can reach it. Read frame/clip dur off the basic graph.
    double outEndFrac = 1.0;
    double clipDur = _basicGraph.clipDurationSeconds;
    double frameDur = _basicGraph.frameDurationSeconds;
    if (clipDur > 0.0 && frameDur > 0.0 && frameDur < clipDur)
      outEndFrac = (clipDur - frameDur) / clipDur;
    // Prefer the existing lanes' end so a new lane lines up with them exactly,
    // regardless of whether duration was available when each was seeded.
    if (!isnan(inheritedEndFrac) && inheritedEndFrac > 0.5)
      outEndFrac = inheritedEndFrac;

    NSArray<NSNumber *> *v = [self _holdValuesOfLane:lane forLabel:label];
    NSMutableArray<KKKeyPose *> *kps = [NSMutableArray array];
    if (globalIn) {
      KKKeyPose *a = [KKKeyPose keyposeAtTime:0.0 values:v];
      a.outgoing = tmplIn ?: [[KKInterval alloc] init];
      [kps addObject:a];
    }
    // Hold-start: at 0 when In off, at tIn when In on. A freshly animatable
    // property's Hold pair starts linked (the two interior keyposes move
    // together) - "fresh = linked, then it's on the user". A second lane
    // joining an existing shape inherits that shape's link state via tmplHold.
    KKKeyPose *hs = [KKKeyPose keyposeAtTime:(globalIn ? tIn : 0.0) values:v];
    if (tmplHold) {
      hs.outgoing = tmplHold;
    } else {
      KKInterval *freshHold = [[KKInterval alloc] init];
      freshHold.endpointsLinked = YES;
      hs.outgoing = freshHold;
    }
    [kps addObject:hs];
    // Hold-end: at outEndFrac when Out off, at tOut when Out on.
    KKKeyPose *he =
        [KKKeyPose keyposeAtTime:(globalOut ? tOut : outEndFrac) values:v];
    [kps addObject:he];
    if (globalOut) {
      he.outgoing = tmplOut ?: [[KKInterval alloc] init];
      [kps addObject:[KKKeyPose keyposeAtTime:outEndFrac values:v]];
    }
    lane.keyposes = kps;
  } else {
    NSArray<NSNumber *> *v = [self _holdValuesOfLane:lane forLabel:label];
    lane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:v] ];
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
  // Copy the existing lane so every property survives a constant value edit -
  // aspectLinked in particular. Rebuilding a fresh lane (carrying only a subset
  // of fields) dropped aspectLinked, so editing the Scale constant cleared the
  // aspect lock. Just replace the single constant keypose.
  KKLane *lane = [existing copy];
  lane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:values] ];
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
  _clipDurationSeconds = seconds;
  [_basicGraph setClipDurationSeconds:seconds];
  [_advancedGraph setClipDurationSeconds:seconds];
}

- (void)setFrameDurationSeconds:(double)seconds {
  [_basicGraph setFrameDurationSeconds:seconds];
  [_advancedGraph setFrameDurationSeconds:seconds];
}

- (void)setPlayheadFraction:(double)frac {
  [_basicGraph setPlayheadFraction:frac];
  [_advancedGraph setPlayheadFraction:frac];
}

- (void)resetZoom {
  // Both tabs share one toolbar button - reset whichever is active.
  if (_activeTab == 1)
    [_advancedGraph resetZoom];
  else
    [_basicGraph resetZoom];
}

- (void)setActiveTab:(NSInteger)tab {
  if (_activeTab == tab)
    return;
  _activeTab = tab;
  [self _refresh];
  if (_onAccessoryButtonsChanged)
    _onAccessoryButtonsChanged();
  // The reset-zoom button reflects only the active tab - re-fire so it
  // tracks the new side's state immediately on tab change.
  if (_onZoomChanged)
    _onZoomChanged(tab == 1 ? _advancedZoomed : _basicZoomed);
}

- (void)applyAdvancedSelectionPillKeys:(NSSet<NSString *> *)pillKeys
                               gapKeys:(NSSet<NSString *> *)gapKeys {
  [_advancedGraph applySelectionPillKeys:pillKeys gapKeys:gapKeys];
}

- (void)setOverlayBlockingInteractions:(BOOL)blocked {
  _advancedGraph.interactionsBlocked = blocked;
}

- (NSArray<NSView *> *)accessoryButtons {
  if (_activeTab != 1)
    return @[];

  if (!_clearSelectionButton) {
    _clearSelectionButton = [[KKClearSelectionButton alloc] init];
    _clearSelectionButton.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    _clearSelectionButton.onTapped = ^{
      __strong typeof(weakSelf) s = weakSelf;
      if (s)
        [s->_advancedGraph clearSelection];
    };
  }
  _clearSelectionButton.enabled = (_advancedGraph.selectionCount > 0);
  return @[ _clearSelectionButton ];
}

- (void)setRenderMode:(KKMiniCanvasRenderMode)mode {
  _renderMode = mode;
}

@end
