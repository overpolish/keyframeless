/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineLanesView.h"
#import "KKCheckboxRowView.h"
#import "KKLaneCategoryNav.h"
#import "KKLaneFilterBar.h"
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
    // Keep the plugin's declared order - it's the authoritative default for the
    // sequencer, constants/keypose popovers, category pills, and the parameter-
    // order list (all of which rank by availableLanes index). Sorting it here
    // alphabetically would override that and is what made categories appear in
    // the wrong order.
    _availableLanes = [availableLanes copy];
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

  // Lane-visibility filter bar at the very top of the timeline content (below
  // the inspector's Basic/Advanced toggle row). Hidden until there are >=2
  // opted-in lanes in Advanced; pushes its hidden set to the Advanced graph.
  _laneFilterBar = [[KKLaneFilterBar alloc] initWithLanes:@[]];
  _laneFilterBar.hidden = YES;
  __weak typeof(self) weakFilter = self;
  _laneFilterBar.onVisibilityChanged = ^(NSSet<NSString *> *hidden) {
    __strong typeof(weakFilter) s = weakFilter;
    [s _applyLaneFilterHidden:hidden];
  };
  _laneFilterBar.onUserToggled = ^{
    __strong typeof(weakFilter) s = weakFilter;
    if (s->_onGuideLaneFilterToggled)
      s->_onGuideLaneFilterToggled();
  };
  // Present the filter checklist through the companion-capable popover path so
  // Canvas's layer list can attach beside it (kind "filter"). Also fire the
  // guide hooks (onFilterPopoverWillOpen/Closed) so a guide can make the
  // checklist interactive, mirroring the Animated manage popover.
  _laneFilterBar.popoverPresenter =
      ^NSPopover *(NSView *content, NSView *anchor, void (^onClose)(void)) {
        __strong typeof(weakFilter) s = weakFilter;
        if (!s)
          return nil;
        NSPopover *pop = [s showCompanionPopover:content
                                        fromView:anchor
                                            kind:@"filter"
                                         onClose:^{
                                           __strong typeof(weakFilter) s2 =
                                               weakFilter;
                                           if (onClose)
                                             onClose();
                                           if (s2.onFilterPopoverClosed)
                                             s2.onFilterPopoverClosed();
                                         }];
        if (s.onFilterPopoverWillOpen) {
          __weak NSView *weakContent = content;
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                __strong typeof(weakFilter) s3 = weakFilter;
                NSView *c = weakContent;
                if (s3.onFilterPopoverWillOpen && c)
                  s3.onFilterPopoverWillOpen(c);
              });
        }
        return pop;
      };
  // The filter cluster is NOT a row here - it's surfaced as a header accessory
  // button (see -accessoryButtons) alongside Dynamic / zoom / Maintain Timing.

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
    [s _graphDidMutateTimeline:updated];
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
                                  initialCategory:nil
                                remembersCategory:YES
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
  _advancedGraph.onKeyposeLayerActivated = ^(NSString *layerKey) {
    __strong typeof(weakSelf) s = weakSelf;
    if (s && s->_onKeyposeLayerActivated)
      s->_onKeyposeLayerActivated(layerKey);
  };
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
    [s _graphDidMutateTimeline:updated];
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
        NSArray<NSString *> *excludedLabels, NSString *primaryCategory,
        void (^onValue)(NSString *, NSArray<NSNumber *> *),
        void (^onAnimate)(NSString *), void (^onRemove)(NSString *),
        void (^onDragBegin)(void), void (^onDragEnd)(void)) {
        __strong typeof(weakSelf) s = weakSelf;
        [s _presentBoundaryValuePopoverFromAnchor:anchor
                                     displayLanes:displayLanes
                                         fraction:frac
                                   excludedLabels:excludedLabels
                                  initialCategory:primaryCategory
                                remembersCategory:NO
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
  _basicGraph.onKeyposeLayerActivated = ^(NSString *layerKey) {
    __strong typeof(weakSelf) s = weakSelf;
    if (s && s->_onKeyposeLayerActivated)
      s->_onKeyposeLayerActivated(layerKey);
  };
}

// Push the lane-filter's hidden set to the Advanced graph and update the
// graph/empty-state hint. Called from _refresh AND from the bar's live
// onVisibilityChanged (a pill toggle doesn't run a full _refresh), so the
// "All lanes hidden" message appears the moment the last lane is hidden.
- (void)_applyLaneFilterHidden:(NSSet<NSString *> *)hidden {
  [_advancedGraph applyHiddenLaneLabels:hidden];
  KKTimeline *gt = [self _graphTimeline];
  NSSet<NSString *> *condVisible =
      KKConditionalVisibleLaneLabels(gt.lanes, nil);
  NSInteger optedIn = 0;
  for (KKLane *l in gt.lanes)
    if (l.enabled && [condVisible containsObject:l.label])
      optedIn++;
  BOOL anyOptedIn = optedIn > 0;
  BOOL showAdvanced = anyOptedIn && _activeTab == 1;
  BOOL allFiltered =
      showAdvanced && optedIn >= 2 && (NSInteger)hidden.count >= optedIn;
  _advancedGraph.hidden = !showAdvanced || allFiltered;
  if (!anyOptedIn)
    _hintLabel.stringValue = KKLoc(@"No animated properties",
                                   @"Empty state: no animated properties.");
  else if (allFiltered)
    _hintLabel.stringValue =
        KKLoc(@"All lanes hidden",
              @"Empty state: every animated lane is hidden by the filter bar.");
  _hintLabel.hidden = anyOptedIn && !allFiltered;
}

- (void)_refresh {
  // Opted-in lanes in parameter order (_timeline.lanes is already sorted),
  // filtered by the Mode-gating visibleWhen rule - a lane hidden by the current
  // Mode doesn't count as animated, so the empty state shows when it's the only
  // one. The graph fills the content area whenever >=1 property is animated AND
  // visible.
  NSSet<NSString *> *condVisible =
      KKConditionalVisibleLaneLabels(_timeline.lanes, nil);
  // The graphs render/gate off the all-layers graphTimeline (when set), so the
  // graph fills the area whenever ANY layer animates a property - never empties
  // just because the selected layer (which drives the dropdown below) doesn't.
  KKTimeline *gt = [self _graphTimeline];
  NSSet<NSString *> *condVisibleGraph =
      KKConditionalVisibleLaneLabels(gt.lanes, nil);
  NSMutableArray<KKLane *> *optedIn = [NSMutableArray array];
  for (KKLane *l in gt.lanes)
    if (l.enabled && [condVisibleGraph containsObject:l.label])
      [optedIn addObject:l];
  BOOL anyOptedIn = optedIn.count > 0;
  BOOL showBasic = anyOptedIn && _activeTab == 0;
  BOOL showAdvanced = anyOptedIn && _activeTab == 1;
  _basicGraph.hidden = !showBasic;
  [_basicGraph applyTimeline:gt];
  [_advancedGraph applyTimeline:gt];

  // Shown in Advanced when there are >=2 lanes worth filtering; the bar's
  // hidden set drives which rows the graph draws.
  [_laneFilterBar applyLanes:optedIn];
  // Scope + size the filter checklist like the Animated dropdown: per active
  // layer (multi-owner), matching the companion layer panel's height.
  _laneFilterBar.minimumPopoverHeight = self.minimumManagePopoverHeight;
  _laneFilterBar.activeLayerKey = _activeLayerKey;
  BOOL showFilter = showAdvanced && optedIn.count >= 2;
  _laneFilterBar.hidden = !showFilter;
  // Graph visibility + empty-state hint (also driven live by the bar's
  // onVisibilityChanged, which doesn't run a full _refresh).
  [self
      _applyLaneFilterHidden:showFilter ? [_laneFilterBar hiddenLabels] : nil];

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
  for (KKLane *tmpl in [self _ownerScopedAvailableLanes])
    if ([self _isAnimatableLabel:tmpl.label] &&
        [condVisible containsObject:tmpl.label])
      [opted addObject:tmpl.label];
  _dropdownTrigger.selectedLabels = opted;
  // Hierarchical summary (layer > group > lane | …) from the opted-in KKLanes,
  // which carry the layerKey/categoryKey grouping; "All" only when nothing is
  // left un-animated. `hasUnoptedLanes` covers both the selected owner's
  // constants AND (multi-owner) any other layer's constants - the merged
  // graphTimeline only carries already-animated lanes, so a plain count of it
  // would always read "All" for Canvas. Supersedes the legacy truncated-label +
  // per-owner layerTitles paths.
  BOOL allOpted = optedIn.count > 0 && ![self hasUnoptedLanes];
  _dropdownTrigger.summaryOverride =
      allOpted
          ? KKLoc(@"All", @"Dropdown summary: every animatable property is "
                          @"animated.")
          : KKHierarchicalLaneSummary(optedIn);
  [_dropdownTrigger setNeedsDisplay:YES];

  if (_openManageView) {
    // Re-scope the open dropdown ONLY when the lane set actually changed (a
    // companion-panel layer switch image<->path, or a mode-gate). Rebuilding
    // every refresh would flicker rows mid-toggle and is pure overhead for
    // single-owner plugins. The checked boxes always re-sync (cheap).
    NSArray<KKLane *> *scoped = [self _manageVisibleLanes];
    NSArray<NSString *> *newLabels = [scoped valueForKey:@"label"];
    if (![newLabels isEqualToArray:[_openManageView currentLaneLabels]])
      [_openManageView setLanes:scoped];
    [_openManageView updateCheckedLabels:[self _optedInLabelsSet]];
  }
  // Only the constants popover tracks the un-opted set. A boundary-value
  // popover has caller-supplied display lanes; clobbering them here is what
  // made Radius (the un-opted lane) replace Crop after a crop edit.
  if (_openStaticView && !_openStaticIsBoundary) {
    [_openStaticView updateUnoptedLanes:[self _unoptedLanes]];
    // Re-apply per-lane state (values + smooth + LINK) to the existing
    // constants rows from the current selected-layer timeline. A same-structure
    // selection change (e.g. drawing another constant-stroke path) reuses the
    // rows and previously never re-read aspectLinked, so the link toggle + its
    // coupling stayed stale from the prior layer. applyValues is focus-safe
    // (skips an in-progress field edit), so this won't clobber active editing.
    [_openStaticView rebindLanes:_timeline.lanes];
  }

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
    // A timeline re-feed re-scopes the open popover to the SAME layer it's
    // already on - it must not fire the activation callback (which would drive
    // the host selection back to that layer, ping-ponging against a selection
    // the user just changed). Only a user graph-click/nav moves selection.
    if (_activeTab == 1)
      [_advancedGraph requestValuePopoverAtFraction:f fireActivation:NO];
    else
      [_basicGraph requestValuePopoverAtFraction:f fireActivation:NO];
  }
}

- (nullable KKLane *)_laneForLabel:(NSString *)label {
  for (KKLane *lane in _timeline.lanes)
    if ([lane.label isEqualToString:label])
      return lane;
  return nil;
}

- (NSArray<KKLane *> *)_ownerScopedAvailableLanes {
  NSMutableSet<NSString *> *present =
      [NSMutableSet setWithCapacity:_timeline.lanes.count];
  for (KKLane *l in _timeline.lanes)
    if (l.label)
      [present addObject:l.label];
  NSMutableArray<KKLane *> *out =
      [NSMutableArray arrayWithCapacity:_availableLanes.count];
  for (KKLane *t in _availableLanes)
    if ([present containsObject:t.label])
      [out addObject:t];
  return out;
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
      fixed.componentsScaleWithMedia = tmpl.componentsScaleWithMedia;
      // codeString is user data (a code lane's text), so keep the saved value;
      // only fall back to the template default when it's missing (older blob).
      if (!fixed.codeString.length)
        fixed.codeString = tmpl.codeString;
      // codeTabs (Common / Buffer A sections) are user data too; keep the saved
      // sections, falling back to the template's tab scaffold for a blob that
      // predates them.
      if (fixed.codeTabs.count == 0)
        fixed.codeTabs = tmpl.codeTabs;
      fixed.codeTabCatalog =
          tmpl.codeTabCatalog; // static config, not persisted
      fixed.codeValidator =
          tmpl.codeValidator;                 // static config, never persisted
      fixed.codeSavable = tmpl.codeSavable;   // static config, never persisted
      [fixed kkApplyPickerMetadataFrom:tmpl]; // category / animatable / seed
      lanes[presentIdx] = fixed;
      continue;
    }
    // Per-owner opt-in lanes are included in the applied timeline only for the
    // layers that support them (a vector path's Points / stroke, not an image
    // or group). Don't re-seed one the source timeline deliberately omitted -
    // otherwise its whole category (e.g. "Core" / "Stroke") shows as a constant
    // for every owner. Geometry lanes get this via `oscEditedOnly`; other lanes
    // declare it explicitly with `ownerScoped`.
    if (tmpl.oscEditedOnly || tmpl.ownerScoped)
      continue;
    KKLane *lane = [KKLane laneWithLabel:tmpl.label];
    lane.valueType = tmpl.valueType;
    lane.componentMin = tmpl.componentMin;
    lane.componentMax = tmpl.componentMax;
    lane.componentUnits = tmpl.componentUnits;
    lane.componentLabels = tmpl.componentLabels;
    lane.componentLabelColors = tmpl.componentLabelColors;
    lane.componentsScaleWithMedia = tmpl.componentsScaleWithMedia;
    // Build-time metadata the template defines. A fresh lane must inherit these
    // or it loses the template's defaults - e.g. `aspectLinked` (so an
    // aspect-linkable lane like Radius/Scale starts LOCKED when the template
    // says so), spatial-curve capability, and whole-number rounding.
    lane.aspectLinkable = tmpl.aspectLinkable;
    lane.aspectLinked = tmpl.aspectLinked;
    lane.spatialCurvable = tmpl.spatialCurvable;
    lane.integerValued = tmpl.integerValued;
    lane.isToggle = tmpl.isToggle;
    lane.codeString = tmpl.codeString; // seed a code lane with its default text
    lane.codeTabs = tmpl.codeTabs; // any added extra sections (empty default)
    lane.codeTabCatalog = tmpl.codeTabCatalog; // the "+" menu catalog
    lane.codeValidator = tmpl.codeValidator;
    lane.codeSavable = tmpl.codeSavable;
    [lane kkApplyPickerMetadataFrom:tmpl]; // category / animatable / seed
    lane.enabled = NO; // constant until the dropdown makes it animatable
    [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                          values:[self _defaultValuesForLabel:
                                                           tmpl.label]]];
    [lanes addObject:lane];
  }
  // Display order: the user's drag-to-reorder list if set, else the plugin's
  // declared `availableLanes` order (the author's intended default), with
  // alphabetical only as a final tiebreaker for stray labels in neither. This
  // is the single chokepoint every view + popover inherits (they all iterate
  // _timeline.lanes in order). Labels present in paramOrder lead in that order.
  NSArray<NSString *> *order = out.paramOrder;
  NSMutableDictionary<NSString *, NSNumber *> *rank =
      [NSMutableDictionary dictionaryWithCapacity:order.count];
  for (NSInteger i = 0; i < (NSInteger)order.count; i++)
    if (!rank[order[i]])
      rank[order[i]] = @(i);
  NSMutableDictionary<NSString *, NSNumber *> *tmplRank =
      [NSMutableDictionary dictionaryWithCapacity:_availableLanes.count];
  for (NSInteger i = 0; i < (NSInteger)_availableLanes.count; i++)
    if (!tmplRank[_availableLanes[i].label])
      tmplRank[_availableLanes[i].label] = @(i);
  [lanes sortUsingComparator:^NSComparisonResult(KKLane *a, KKLane *b) {
    NSNumber *ra = rank[a.label];
    NSNumber *rb = rank[b.label];
    if (ra && rb)
      return [ra compare:rb];
    if (ra)
      return NSOrderedAscending;
    if (rb)
      return NSOrderedDescending;
    NSNumber *ta = tmplRank[a.label];
    NSNumber *tb = tmplRank[b.label];
    if (ta && tb)
      return [ta compare:tb];
    if (ta)
      return NSOrderedAscending;
    if (tb)
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
  // Mode-gated lanes drop out of the reorder list too (e.g. no "Gradient" row
  // while Mode = Solid). Computed over the timeline so the controller resolves.
  NSSet<NSString *> *condVisible =
      KKConditionalVisibleLaneLabels(_timeline.lanes, nil);
  // _timeline.lanes is already in display order (sorted in
  // _timelineSeededFrom:) and - post-seed - contains every available property,
  // so its order is the source of truth for the reorder list.
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (KKLane *l in _timeline.lanes)
    if ([avail containsObject:l.label] && ![out containsObject:l.label] &&
        [condVisible containsObject:l.label])
      [out addObject:l.label];
  for (KKLane *l in _availableLanes)
    if (![out containsObject:l.label] && [condVisible containsObject:l.label])
      [out addObject:l.label];
  return out;
}

- (NSArray<NSString *> *)allOrderedParamLabels {
  // Every available lane label, sorted the same way _timelineSeededFrom: sorts
  // lanes (paramOrder first, then template order, then alphabetical) but
  // WITHOUT the per-timeline / conditional-visibility filtering
  // orderedParamLabels does. The reorder popover edits one global ordering, so
  // it must list the full parameter set even when the selected layer doesn't
  // carry those lanes.
  NSArray<NSString *> *order = _timeline.paramOrder;
  NSMutableDictionary<NSString *, NSNumber *> *rank =
      [NSMutableDictionary dictionaryWithCapacity:order.count];
  for (NSInteger i = 0; i < (NSInteger)order.count; i++)
    if (!rank[order[i]])
      rank[order[i]] = @(i);
  NSMutableDictionary<NSString *, NSNumber *> *tmplRank =
      [NSMutableDictionary dictionaryWithCapacity:_availableLanes.count];
  NSMutableArray<NSString *> *labels =
      [NSMutableArray arrayWithCapacity:_availableLanes.count];
  for (NSInteger i = 0; i < (NSInteger)_availableLanes.count; i++) {
    NSString *label = _availableLanes[i].label;
    if (!tmplRank[label])
      tmplRank[label] = @(i);
    if (![labels containsObject:label])
      [labels addObject:label];
  }
  [labels sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
    NSNumber *ra = rank[a];
    NSNumber *rb = rank[b];
    if (ra && rb)
      return [ra compare:rb];
    if (ra)
      return NSOrderedAscending;
    if (rb)
      return NSOrderedDescending;
    NSNumber *ta = tmplRank[a];
    NSNumber *tb = tmplRank[b];
    if (ta && tb)
      return [ta compare:tb];
    if (ta)
      return NSOrderedAscending;
    if (tb)
      return NSOrderedDescending;
    return [a localizedCaseInsensitiveCompare:b];
  }];
  return labels;
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
  // Multi-owner: another (non-selected) layer may still have constants even
  // when the selected one is fully animated - the host sets
  // ownerConstantsAvailable so the Constants button stays reachable (you open
  // it, then pick that layer in the panel).
  return [self _unoptedLanes].count > 0 || _ownerConstantsAvailable;
}

- (void)applyTimeline:(KKTimeline *)timeline {
  _timeline = [self _timelineSeededFrom:timeline];
  [self _refresh];
}

// A graph (Basic or Advanced) committed an edit. In multi-owner mode the edit
// is on the all-layers graphTimeline, so route it to onGraphTimelineMutated and
// let the host split it back per owner (then reload re-feeds both timelines);
// _timeline (the single selected owner) must NOT be overwritten with the tagged
// all-layers set. Single-owner mode keeps the original flow.
- (void)_graphDidMutateTimeline:(KKTimeline *)updated {
  if (_graphTimeline) {
    if (_onGraphTimelineMutated)
      _onGraphTimelineMutated(updated);
    return;
  }
  _timeline = updated;
  [self _refresh];
  [self _republishBoundaryRequestIfOpen];
  if (_onTimelineMutated)
    _onTimelineMutated(updated);
}

// The lane set the GRAPHS render/edit: the multi-owner graphTimeline when set,
// else the single-owner _timeline.
- (KKTimeline *)_graphTimeline {
  return _graphTimeline ?: _timeline;
}

- (void)setGraphTimeline:(KKTimeline *)graphTimeline {
  _graphTimeline = graphTimeline;
  [self _refresh];
}
- (KKTimeline *)graphTimeline {
  return _graphTimeline;
}

- (void)retargetKeyposePopoverToLayerKey:(NSString *)layerKey {
  // Only meaningful while a keypose (boundary) popover is open. Route to
  // whichever graph is active (Basic tab vs Advanced tab).
  if (!_openStaticView || !_openStaticIsBoundary)
    return;
  if (_activeTab == 0)
    [_basicGraph retargetKeyposePopoverToLayerKey:layerKey];
  else
    [_advancedGraph retargetKeyposePopoverToLayerKey:layerKey];
}

- (void)setActiveLayerKey:(NSString *)activeLayerKey {
  _activeLayerKey = [activeLayerKey copy];
  _basicGraph.activeLayerKey =
      activeLayerKey; // scopes the Basic keypose popover
  // Keep the Advanced graph's active layer in sync too, so its "opened a
  // keypose for a different layer" test compares against the CURRENT selection
  // (stale here meant the keypose-owner highlight/selection sync silently
  // skipped).
  _advancedGraph.activeLayerKey = activeLayerKey;
  // Re-scope an open lane-filter checklist to the newly-selected layer (the
  // companion layer list drove the switch), like the Animated dropdown.
  _laneFilterBar.activeLayerKey = activeLayerKey;
}
- (NSString *)activeLayerKey {
  return _activeLayerKey;
}

- (void)setDropdownLayerTitles:(NSArray<NSString *> *)dropdownLayerTitles {
  _dropdownTrigger.layerTitles = dropdownLayerTitles;
  [_dropdownTrigger setNeedsDisplay:YES];
}
- (NSArray<NSString *> *)dropdownLayerTitles {
  return _dropdownTrigger.layerTitles;
}

- (void)setLayerOrder:(NSArray<NSString *> *)layerOrder {
  _advancedGraph.layerOrder = layerOrder;
  [_advancedGraph setNeedsDisplay:YES];
}
- (NSArray<NSString *> *)layerOrder {
  return _advancedGraph.layerOrder;
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

- (double)playheadFraction {
  return _basicGraph.playheadFraction;
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
  if (!_dynamicButton) {
    _dynamicButton = [[KKDynamicButton alloc] init];
    _dynamicButton.translatesAutoresizingMaskIntoConstraints = NO;
    _dynamicButton.toolTip =
        KKLoc(@"Dynamic",
              @"Toggle: non-linear timeline display so short transitions stay "
              @"grabbable.");
    __weak typeof(self) weakSelf = self;
    _dynamicButton.onToggled = ^(BOOL isOn) {
      __strong typeof(weakSelf) s = weakSelf;
      if (!s)
        return;
      s->_advancedGraph.dynamicDisplay = isOn;
      if (s->_onGuideDynamicToggled)
        s->_onGuideDynamicToggled(isOn);
    };
  }
  _dynamicButton.on = _advancedGraph.dynamicDisplay;
  _clearSelectionButton.enabled = (_advancedGraph.selectionCount > 0);
  return @[ _dynamicButton, _clearSelectionButton ];
}

// The lane-filter cluster is hosted centered in the inspector's header row (its
// own slot, separate from the right-aligned accessory stack). -_refresh toggles
// its hidden flag (Advanced + >=2 lanes).
- (NSView *)filterAccessory {
  return _laneFilterBar;
}

- (NSRect)guideDynamicButtonScreenRect {
  NSWindow *w = _dynamicButton.window;
  if (!_dynamicButton || !w)
    return NSZeroRect;
  NSRect inWindow = [_dynamicButton convertRect:_dynamicButton.bounds
                                         toView:nil];
  return [w convertRectToScreen:inWindow];
}

- (void)guideSetDynamicDisplay:(BOOL)on {
  _advancedGraph.dynamicDisplay = on; // persists + marks the timeline dirty
  _dynamicButton.on = on;             // keep the toolbar glyph in sync
  [_advancedGraph setNeedsDisplay:YES];
}

- (void)setRenderMode:(KKMiniViewerRenderMode)mode {
  _renderMode = mode;
}

@end
