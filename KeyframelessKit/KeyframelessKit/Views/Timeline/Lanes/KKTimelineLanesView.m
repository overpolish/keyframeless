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

// Basic and Advanced graphs request the SAME shared popover presenters
// (`_presentGapPopoverFromAnchor:` /
// `_presentHoldModulationPopoverFromAnchor:`). The only thing that differs is
// the KKGapPopoverPhase, which the presenter uses solely to pick the
// plugin-supplied extras slot. So the two graphs' callbacks are one forwarder
// each, parameterised by phase.
typedef void (^KKGapForwardBlock)(
    NSView *anchor, BOOL animateOut, double startFraction, double endFraction,
    KKIntervalCurve curve, double intensity, double frequency,
    NSArray<NSString *> *partLabels, NSArray<NSNumber *> *partStates,
    NSArray<NSNumber *> * (^partRebuilder)(void),
    void (^onCurve)(KKIntervalCurve), void (^onIntensity)(double),
    void (^onFrequency)(double), void (^onParticipation)(NSInteger, BOOL),
    void (^onDragBegin)(void), void (^onDragEnd)(void), NSString *laneLabel,
    KKInterval *representative, KKGapIntervalReader reader,
    KKGapIntervalMutator mutator);

typedef void (^KKHoldForwardBlock)(
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
    KKGapIntervalMutator mutator);

// `inPhase` is used for the In ramp / start side, `outPhase` for the Out ramp
// (Basic distinguishes them; Advanced passes the same phase for both).
static KKGapForwardBlock KKMakeGapForwarder(KKTimelineLanesView *owner,
                                            KKGapPopoverPhase inPhase,
                                            KKGapPopoverPhase outPhase) {
  __weak KKTimelineLanesView *weak = owner;
  return ^(
      NSView *anchor, BOOL animateOut, double startFraction, double endFraction,
      KKIntervalCurve curve, double intensity, double frequency,
      NSArray<NSString *> *partLabels, NSArray<NSNumber *> *partStates,
      NSArray<NSNumber *> * (^partRebuilder)(void),
      void (^onCurve)(KKIntervalCurve), void (^onIntensity)(double),
      void (^onFrequency)(double), void (^onParticipation)(NSInteger, BOOL),
      void (^onDragBegin)(void), void (^onDragEnd)(void), NSString *laneLabel,
      KKInterval *representative, KKGapIntervalReader reader,
      KKGapIntervalMutator mutator) {
    [weak _presentGapPopoverFromAnchor:anchor
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
                                 phase:(animateOut ? outPhase
                                                   : inPhase)laneLabel:laneLabel
                        representative:representative
                        intervalReader:reader
                       intervalMutator:mutator];
  };
}

static KKHoldForwardBlock KKMakeHoldForwarder(KKTimelineLanesView *owner) {
  __weak KKTimelineLanesView *weak = owner;
  return ^(NSView *anchor, double startFraction, double endFraction,
           KKIntervalModulation modulation, double intensity, double frequency,
           uint32_t seed, BOOL linked, BOOL showsLinked,
           NSArray<NSArray<NSString *> *> *partLabels,
           NSArray<NSArray<NSNumber *> *> *partStates,
           NSArray<NSArray<NSNumber *> *> * (^partRebuilder)(void),
           void (^onModulation)(KKIntervalModulation),
           void (^onIntensity)(double), void (^onFrequency)(double),
           void (^onSeed)(uint32_t), void (^onLinked)(BOOL),
           void (^onParticipation)(NSInteger, BOOL), void (^onDragBegin)(void),
           void (^onDragEnd)(void), NSString *laneLabel,
           KKInterval *representative, KKGapIntervalReader reader,
           KKGapIntervalMutator mutator) {
    [weak
        _presentHoldModulationPopoverFromAnchor:anchor
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
    _miniViewerClipAspect = 16.0 / 9.0;
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
  _basicGraph.onGapPopover = KKMakeGapForwarder(self, KKGapPopoverPhaseBasicIn,
                                                KKGapPopoverPhaseBasicOut);
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
  _advancedGraph.onGapPopover = KKMakeGapForwarder(
      self, KKGapPopoverPhaseAdvanced, KKGapPopoverPhaseAdvanced);
  _advancedGraph.onHoldModulationPopover = KKMakeHoldForwarder(self);
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

  _basicGraph.onHoldModulationPopover = KKMakeHoldForwarder(self);
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
  // Template lookup for the metadata re-injection below.
  NSMutableDictionary<NSString *, KKLane *> *tmplByLabel =
      [NSMutableDictionary dictionaryWithCapacity:_availableLanes.count];
  for (KKLane *tmpl in _availableLanes)
    tmplByLabel[tmpl.label] = tmpl;
  // Iterate _timeline.lanes, NOT _availableLanes: _timeline.lanes is already in
  // display order (sorted by paramOrder in _timelineSeededFrom:) and post-seed
  // contains every available property, so the constants popover inherits the
  // same parameter ordering as the timeline and reorder list.
  NSMutableArray<KKLane *> *result = [NSMutableArray array];
  for (KKLane *tlLane in _timeline.lanes) {
    KKLane *tmpl = tmplByLabel[tlLane.label];
    if (!tmpl || tlLane.enabled)
      continue; // only available, non-animatable (constant) properties
    KKLane *lane = tlLane;
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

- (void)setRenderMode:(KKMiniViewerRenderMode)mode {
  _renderMode = mode;
}

@end
