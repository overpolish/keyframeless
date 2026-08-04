/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKFloatingPanel.h"
#import "KKLocalized.h"
#import "KKMiniViewerRenderer.h"
#import "KKMiniViewerView.h"
#import "KKPopoverHeaderView.h"
#import "KKPopoverKeepAlive.h"
#import "KKTimelineLanesView+Guide.h"
#import "KKTimelineLanesView_Popovers.h"
#import "KKTokens.h"
#import <KeyframelessKit/KKCurveDefaults.h>
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKSegmentEditView.h>
#import <KeyframelessKit/KKTimeline.h> // KKLane / KKTimeline

@interface KKTimelineLanesView (SegmentPopoversPrivate)
- (nullable NSArray<KKLane *> *)_partLanesForLabels:
    (NSArray<NSString *> *)labels;
- (nullable NSArray<KKLane *> *)_compoundLanesForCompounds:
    (NSArray<NSArray<NSString *> *> *)compounds;
- (void)_resizeOpenSegmentPopoverToEditor:(KKSegmentEditView *)edit;
- (NSButton *)_makePopoverCloseButton;
- (KKPopoverPeekButton *)_makePopoverPeekButton;
- (KKPopoverSidebarButton *)_makePopoverSidebarButton;
- (KKPopoverSidebarButton *)_makePopoverRightPanelButton;
- (void)_wireSegmentEditor:(KKSegmentEditView *)edit
           onParticipation:(void (^)(NSInteger, BOOL))onParticipation
               onDragBegin:(void (^)(void))onDragBegin
                 onDragEnd:(void (^)(void))onDragEnd;
- (void)_presentSegmentEditor:(KKSegmentEditView *)edit
                       header:(KKPopoverHeaderView *)header
                        phase:(KKGapPopoverPhase)phase
                    laneLabel:(NSString *)laneLabel
               representative:(KKInterval *)representativeInterval
               intervalReader:(KKGapIntervalReader)intervalReader
              intervalMutator:(KKGapIntervalMutator)intervalMutator
                       anchor:(NSView *)anchor
                  postApplies:(BOOL)postApplies
                      onClose:(void (^)(void))onClose;
@end

@implementation KKTimelineLanesView (SegmentPopovers)

// Resolve flat participation labels to their live lanes (which carry the
// category / layer metadata the checklist groups by), preserving `labels`
// order so the toggle index still lines up. Returns nil if any label is
// unresolved or the set is empty - the caller then falls back to flat pills.
- (nullable NSArray<KKLane *> *)_partLanesForLabels:
    (NSArray<NSString *> *)labels {
  if (labels.count == 0)
    return nil;
  NSArray<KKLane *> *all = self.currentTimeline.lanes;
  NSMutableDictionary<NSString *, KKLane *> *byLabel =
      [NSMutableDictionary dictionaryWithCapacity:all.count];
  for (KKLane *lane in all)
    byLabel[lane.key] = lane;
  NSMutableArray<KKLane *> *out =
      [NSMutableArray arrayWithCapacity:labels.count];
  for (NSString *label in labels) {
    // A label that can't be resolved (shouldn't happen - they come from the
    // same timeline) gets a category-less placeholder so the checklist still
    // renders rather than silently falling back to a pill bar.
    KKLane *lane = byLabel[label] ?: [KKLane laneWithKey:label label:label];
    // The display name is template-canonical: re-apply it from the template so
    // the applies-to checklist shows the user's current label, not a stale
    // persisted one (or the raw key on the placeholder above).
    for (KKLane *t in _availableLanes)
      if ([t.key isEqualToString:lane.key] && t.label.length) {
        lane = [lane copy];
        lane.label = t.label;
        break;
      }
    [out addObject:lane];
  }
  return out;
}

// After an in-place re-scope (different layer = different checklist row count),
// grow/shrink the open popover by the editor's height delta so the checklist
// isn't clipped / leaves a gap.
- (void)_resizeOpenSegmentPopoverToEditor:(KKSegmentEditView *)edit {
  if (!_openSegEditHeightConstraint || ![self _editorPanelIsVisible] ||
      _openEditorIsStaticFamily)
    return;
  CGFloat newH = [edit contentHeight];
  CGFloat delta = newH - _openSegEditHeightConstraint.constant;
  if (fabs(delta) < 0.5)
    return;
  _openSegEditHeightConstraint.constant = newH;
  // Grow/shrink the container too, else its old fixed height fights the
  // wrapper-edge constraints and the header is pushed out of view.
  _openSegContainerHeightConstraint.constant += delta;
  // Hold the editor panel's top edge while its body changes height. The shared
  // panel host clamps the result fully inside the active screen.
  NSSize sz = _openEditorPanel.frame.size;
  [self _setOpenEditorContentSize:NSMakeSize(sz.width, sz.height + delta)];
}

// The modulate popover's participation is COMPOUND (one entry per lane: master
// label then its component labels). Resolve each compound's lane (its first
// label) to the live lane for the category pill nav. A label that can't resolve
// (e.g. a gradient compound that displays "Angle") gets a label-only
// placeholder so the array stays parallel and that row just shows
// uncategorised.
- (nullable NSArray<KKLane *> *)_compoundLanesForCompounds:
    (NSArray<NSArray<NSString *> *> *)compounds {
  if (compounds.count == 0)
    return nil;
  NSArray<KKLane *> *all = self.currentTimeline.lanes;
  NSMutableDictionary<NSString *, KKLane *> *byLabel =
      [NSMutableDictionary dictionaryWithCapacity:all.count];
  for (KKLane *lane in all)
    byLabel[lane.key] = lane;
  NSMutableArray<KKLane *> *out =
      [NSMutableArray arrayWithCapacity:compounds.count];
  for (NSArray<NSString *> *compound in compounds) {
    NSString *master = compound.firstObject ?: @"";
    KKLane *lane = byLabel[master] ?: [KKLane laneWithKey:master label:master];
    [out addObject:lane];
  }
  return out;
}

// Wire the callbacks shared by the curve + modulation editors: participation
// toggle and the two drag brackets (participation sweep + slider drag both
// coalesce into the host's undo group). The kind-specific curve / seed / linked
// callbacks stay with each caller.
- (void)_wireSegmentEditor:(KKSegmentEditView *)edit
           onParticipation:(void (^)(NSInteger, BOOL))onParticipation
               onDragBegin:(void (^)(void))onDragBegin
                 onDragEnd:(void (^)(void))onDragEnd {
  edit.onParticipationToggled = ^(NSInteger idx, BOOL on) {
    if (onParticipation)
      onParticipation(idx, on);
  };
  edit.onParticipationDragBegin = ^{
    if (onDragBegin)
      onDragBegin();
  };
  edit.onParticipationDragEnd = ^{
    if (onDragEnd)
      onDragEnd();
  };
  edit.onSliderDragBegin = ^{
    if (onDragBegin)
      onDragBegin();
  };
  edit.onSliderDragEnd = ^{
    if (onDragEnd)
      onDragEnd();
  };
}

// Assemble the popover container (header + sized editor + plugin extras),
// present it, and post the "appliesTo" open signal. Shared by the curve and
// modulation popovers - the caller builds + wires the editor, stashes its own
// open-editor ivars, and supplies the header + an onClose that clears them.
- (void)_presentSegmentEditor:(KKSegmentEditView *)edit
                       header:(KKPopoverHeaderView *)header
                        phase:(KKGapPopoverPhase)phase
                    laneLabel:(NSString *)laneLabel
               representative:(KKInterval *)representativeInterval
               intervalReader:(KKGapIntervalReader)intervalReader
              intervalMutator:(KKGapIntervalMutator)intervalMutator
                       anchor:(NSView *)anchor
                  postApplies:(BOOL)postApplies
                      onClose:(void (^)(void))onClose {
  CGFloat w = [KKSegmentEditView contentWidth];
  // Instance height, not the class method: the checklist "Applies to" section's
  // height depends on its (filtered) row count, so only the built view knows
  // it.
  CGFloat editH = [edit contentHeight];
  edit.translatesAutoresizingMaskIntoConstraints = NO;

  // Plugin-supplied extras (toggles, sliders) appended below the editor. Each
  // row gets its own intrinsic height; container height grows.
  NSArray<NSView *> *extras = nil;
  if (self.gapPopoverExtraRows && representativeInterval && intervalMutator)
    extras = self.gapPopoverExtraRows(phase, laneLabel, representativeInterval,
                                      intervalReader ?: ^KKInterval *{
                                        return representativeInterval;
                                      },
                                      intervalMutator);

  CGFloat headerH = [KKPopoverHeaderView height];
  CGFloat extrasH = 0;
  for (NSView *v in extras)
    extrasH += v.intrinsicContentSize.height;
  // When the "Applies to" checklist is the last element, its scroll fade marks
  // the bottom edge - drop the container's bottom padding so the fade meets the
  // popover edge instead of floating above a gap.
  CGFloat bottomPad =
      (edit.hasChecklistParticipation && extras.count == 0) ? 0.0 : KKPaddingMD;
  CGFloat totalH =
      KKPaddingMD + headerH + KKSpacingSM + editH + extrasH + bottomPad;
  NSView *container =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, totalH)];
  KKPanelDragHandleView *dragHandle =
      [[KKPanelDragHandleView alloc] initWithFrame:NSZeroRect];
  dragHandle.translatesAutoresizingMaskIntoConstraints = NO;
  [container addSubview:dragHandle];
  // Close button top-left, before the header - same affordance as the keypose /
  // constants popover so a fixed-position companion is easy to dismiss (the
  // default close-on-focus-loss still applies).
  NSButton *closeButton = [self _makePopoverCloseButton];
  KKPopoverPeekButton *peekButton = [self _makePopoverPeekButton];
  KKPopoverSidebarButton *sidebarButton = [self _makePopoverSidebarButton];
  KKPopoverSidebarButton *rightPanelButton =
      self.editorRightPanelToggleSupported &&
              self.editorRightPanelToggleAvailable
          ? [self _makePopoverRightPanelButton]
          : nil;
  [container addSubview:closeButton];
  [container addSubview:peekButton];
  [container addSubview:sidebarButton];
  if (rightPanelButton)
    [container addSubview:rightPanelButton];
  [container addSubview:header];
  // Trailing end of the title row: the segment's own [Reset][Make Default]
  // actions.
  // The editor can shrink itself (the Frequency row collapses on a curve that
  // has none) - resize the open popover to match, same path a layer re-scope
  // takes.
  __weak typeof(self) weakHeight = self;
  __weak KKSegmentEditView *weakEditH = edit;
  edit.onContentHeightChanged = ^{
    __strong typeof(weakHeight) sh = weakHeight;
    __strong KKSegmentEditView *eh = weakEditH;
    if (sh && eh)
      [sh _resizeOpenSegmentPopoverToEditor:eh];
  };
  NSView *defaults = [edit defaultsAccessoryView];
  [container addSubview:defaults];
  [container addSubview:edit];
  _openSegEditHeightConstraint =
      [edit.heightAnchor constraintEqualToConstant:editH];
  [NSLayoutConstraint activateConstraints:@[
    [dragHandle.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
    [dragHandle.trailingAnchor
        constraintEqualToAnchor:container.trailingAnchor],
    [dragHandle.topAnchor constraintEqualToAnchor:container.topAnchor],
    [dragHandle.heightAnchor
        constraintEqualToConstant:KKPaddingMD + headerH + KKSpacingSM],
    [closeButton.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                              constant:KKPaddingMD],
    [closeButton.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    // Match the keypose / constants popover close button (22pt square).
    [closeButton.widthAnchor constraintEqualToConstant:22.0],
    [closeButton.heightAnchor constraintEqualToConstant:22.0],
    [peekButton.leadingAnchor constraintEqualToAnchor:closeButton.trailingAnchor
                                             constant:KKPaddingSM],
    [peekButton.centerYAnchor
        constraintEqualToAnchor:closeButton.centerYAnchor],
    [peekButton.widthAnchor constraintEqualToConstant:22.0],
    [peekButton.heightAnchor constraintEqualToConstant:22.0],
    [sidebarButton.leadingAnchor
        constraintEqualToAnchor:peekButton.trailingAnchor
                       constant:KKPaddingSM],
    [sidebarButton.centerYAnchor
        constraintEqualToAnchor:peekButton.centerYAnchor],
    [sidebarButton.widthAnchor constraintEqualToConstant:22.0],
    [sidebarButton.heightAnchor constraintEqualToConstant:22.0],
    [header.topAnchor constraintEqualToAnchor:container.topAnchor
                                     constant:KKPaddingMD],
    [header.trailingAnchor
        constraintLessThanOrEqualToAnchor:defaults.leadingAnchor
                                 constant:-KKSpacingSM],
    [defaults.trailingAnchor constraintEqualToAnchor:container.trailingAnchor
                                            constant:-KKPaddingMD],
    [defaults.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
    [edit.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
    [edit.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    [edit.topAnchor constraintEqualToAnchor:header.bottomAnchor
                                   constant:KKSpacingSM],
    _openSegEditHeightConstraint,
    [container.widthAnchor constraintEqualToConstant:w],
    (_openSegContainerHeightConstraint =
         [container.heightAnchor constraintEqualToConstant:totalH]),
  ]];
  NSLayoutXAxisAnchor *headerLead = sidebarButton.trailingAnchor;
  if (rightPanelButton) {
    [NSLayoutConstraint activateConstraints:@[
      [rightPanelButton.leadingAnchor
          constraintEqualToAnchor:sidebarButton.trailingAnchor
                         constant:KKPaddingSM],
      [rightPanelButton.centerYAnchor
          constraintEqualToAnchor:sidebarButton.centerYAnchor],
      [rightPanelButton.widthAnchor constraintEqualToConstant:22.0],
      [rightPanelButton.heightAnchor constraintEqualToConstant:22.0],
    ]];
    headerLead = rightPanelButton.trailingAnchor;
  }
  [header.leadingAnchor constraintEqualToAnchor:headerLead constant:KKSpacingMD]
      .active = YES;
  NSView *prev = edit;
  for (NSView *extra in extras) {
    extra.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:extra];
    [NSLayoutConstraint activateConstraints:@[
      // Match KKSegmentEditView's internal kHPadding (10) so the extras row
      // aligns with the segment editor's Linked-toggle row above it.
      [extra.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                          constant:10.0],
      [extra.trailingAnchor constraintEqualToAnchor:container.trailingAnchor
                                           constant:-10.0],
      // First extra anchors to edit.bottom which already includes the editor's
      // internal kVPadding (~10pt); zero gap here lands at roughly the same
      // spacing as the editor's internal kRowGap rows. Subsequent extras stack
      // with no extra gap; rows that need separation bake it into their own
      // intrinsicContentSize.
      [extra.topAnchor constraintEqualToAnchor:prev.bottomAnchor],
    ]];
    prev = extra;
  }

  _openExtraRows = extras;
  __weak typeof(self) weak = self;
  // Anchor beside the inspector's timeline area (whichever side has more screen
  // space), NOT at the clicked gap - a companion that switches content in
  // place, sitting in one consistent spot out of the work area. Matches the
  // static-values / keypose popover. The graph tints the active gap instead
  // (see the Basic / Advanced views' _gapPopoverShowing highlight). The
  // presenter swaps content on the live window when already shown (gap-to-gap,
  // or coming from any other popover), so the buttons inside never go dead from
  // a reopen.
  KKFloatingPanel *panel = [self
      _showEditorPanelWithContent:container
                         fromView:self
                     staticFamily:NO
                          onClose:^{
                            if (onClose)
                              onClose();
                            __strong typeof(weak) s = weak;
                            if (!s)
                              return;
                            s->_openExtraRows = nil;
                            // Signal close so the graphs clear their
                            // active-gap highlight (same companion signal the
                            // static-values / manage popovers post).
                            [NSNotificationCenter.defaultCenter
                                postNotificationName:
                                    KKStaticValuesPopoverDidCloseNotification
                                              object:s];
                          }];
  panel.dragHandleView = dragHandle;
  // Signal the open so a multi-layer host (Canvas) can attach its layer-list
  // companion beside the "Applies to" checklist (Basic only - Advanced's
  // popover is opened on one lane that already lives on a single layer).
  if (postApplies) {
    _openEditorSidebarKind = @"appliesTo";
    _openEditorSidebarIsBoundary = NO;
    _openEditorSidebarFraction = 0.0;
    KKPostStaticValuesEditorDidOpen(panel, container, self, @"appliesTo", NO,
                                    0.0);
  }
}

- (void)_presentGapPopoverFromAnchor:(NSView *)anchor
                          animateOut:(BOOL)animateOut
                       startFraction:(double)startFraction
                         endFraction:(double)endFraction
                               curve:(KKIntervalCurve)curve
                           intensity:(double)intensity
                           frequency:(double)frequency
                          partLabels:(NSArray<NSString *> *)partLabels
                          partStates:(NSArray<NSNumber *> *)partStates
                       partRebuilder:
                           (NSArray<NSNumber *> * (^)(void))partRebuilder
                             onCurve:(void (^)(KKIntervalCurve))onCurve
                         onIntensity:(void (^)(double))onIntensity
                         onFrequency:(void (^)(double))onFrequency
                     onParticipation:(void (^)(NSInteger, BOOL))onParticipation
                         onDragBegin:(void (^)(void))onDragBegin
                           onDragEnd:(void (^)(void))onDragEnd
                               phase:(KKGapPopoverPhase)phase
                           laneLabel:(NSString *)laneLabel
                      representative:(KKInterval *)representativeInterval
                      intervalReader:(KKGapIntervalReader)intervalReader
                     intervalMutator:(KKGapIntervalMutator)intervalMutator {
  // The "Applies to" section renders as the Animated dropdown's checklist (so
  // many grouped properties scroll vertically instead of a horizontal pill
  // bar). The checklist needs each lane's category / layer metadata, which the
  // flat `partLabels` lack - resolve them from the live timeline in the same
  // order (nil only when there are no participating lanes at all).
  NSArray<KKLane *> *partLanes = [self _partLanesForLabels:partLabels];

  // Layer re-scope: a popover is already open for this (gap) editor and the
  // host just switched layers - update the open checklist + curve in place
  // instead of building a new popover (no close/reopen flicker).
  if (_rescopingGapPopover && _openGapEditor) {
    if (partLanes) {
      [_openGapEditor rescopeParticipationLanes:partLanes states:partStates];
      [_openGapEditor
          selectParticipationLayerKey:[self _hostSelectedLayerKeyIn:partLanes]];
    }
    // Re-wire the toggle to the NEW layer's callback - it captures this layer's
    // (tagged) labels, so without this a tick writes to the old layer.
    [self _wireSegmentEditor:_openGapEditor
             onParticipation:onParticipation
                 onDragBegin:onDragBegin
                   onDragEnd:onDragEnd];
    _openGapEditor.curveType = (NSInteger)curve;
    _openGapEditor.intensity = intensity;
    _openGapEditor.frequency = frequency;
    _openGapRebuilder = [partRebuilder copy];
    _openGapIntervalReader = [intervalReader copy];
    [self _resizeOpenSegmentPopoverToEditor:_openGapEditor];
    return;
  }
  KKSegmentEditView *edit =
      [[KKSegmentEditView alloc] initWithKind:KKSegmentEditKindTransition
                                  showsLinked:NO
                                   bulkHeader:NO
                           participationLanes:partLanes
                          participationStates:partStates];
  // A multi-owner list opens on the owner the host has selected (the rack entry
  // / layer the user came from), not on the first one. Before presenting, so
  // the popover is sized to that owner's row count.
  [edit selectParticipationLayerKey:[self _hostSelectedLayerKeyIn:partLanes]];
  [self _wireSegmentEditor:edit
           onParticipation:onParticipation
               onDragBegin:onDragBegin
                 onDragEnd:onDragEnd];
  edit.animateOut = animateOut;
  edit.curveType = (NSInteger)curve;
  edit.intensity = intensity;
  edit.frequency = frequency;
  // A curve pick is discrete → commits immediately (its own undo entry).
  // Intensity/frequency are continuous → KKSegmentEditView brackets the drag
  // via onSliderDragBegin/End (wired above) into the host's undo group.
  __weak typeof(self) weakGap = self;
  edit.onCurveTypeChanged = ^(NSInteger ct) {
    if (onCurve)
      onCurve((KKIntervalCurve)ct);
    __strong typeof(weakGap) sg = weakGap;
    if (sg && sg->_onGapPopoverCurveChanged)
      sg->_onGapPopoverCurveChanged(ct);
  };
  edit.onIntensityChanged = ^(double v) {
    if (onIntensity)
      onIntensity(v);
  };
  edit.onFrequencyChanged = ^(double v) {
    if (onFrequency)
      onFrequency(v);
  };

  // Wrap the editor with a "Curve <start>–<end>" header (the editor itself is
  // shared with the hold-modulation popover).
  NSString *range = [NSString
      stringWithFormat:@"%@ → %@", [self _timeStringForFraction:startFraction],
                       [self _timeStringForFraction:endFraction]];
  KKPopoverHeaderView *header = [[KKPopoverHeaderView alloc]
      initWithTitle:KKLoc(@"Curve", @"Section: easing curve.")
             detail:range
         symbolName:@"point.topleft.down.to.point.bottomright.curvepath"];

  // Track the editor + rebuilders so _refresh can push fresh state on cmd-Z
  // without reopening; the onClose clears them.
  _openGapEditor = edit;
  _openGapRebuilder = [partRebuilder copy];
  _openGapIntervalReader = [intervalReader copy];
  __weak typeof(self) weakClose = self;
  [self _presentSegmentEditor:edit
                       header:header
                        phase:phase
                    laneLabel:laneLabel
               representative:representativeInterval
               intervalReader:intervalReader
              intervalMutator:intervalMutator
                       anchor:anchor
                  postApplies:(partLanes != nil && _activeTab != 1)
                      onClose:^{
                        __strong typeof(weakClose) sc = weakClose;
                        if (!sc)
                          return;
                        sc->_openGapEditor = nil;
                        sc->_openGapRebuilder = nil;
                        sc->_openGapIntervalReader = nil;
                      }];

  // Guide hook: same settle delay as the static-values popover so the
  // segment editor is in a window and laid out before the guide reads pill
  // rects. content == editor for this popover.
  if (self.onGapPopoverWillOpen) {
    __weak KKSegmentEditView *weakEdit = edit;
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong typeof(weakSelf) s = weakSelf;
          __strong KKSegmentEditView *e = weakEdit;
          if (s && e && s.onGapPopoverWillOpen)
            s.onGapPopoverWillOpen(e, e);
        });
  }
}

- (void)
    _presentHoldModulationPopoverFromAnchor:(NSView *)anchor
                              startFraction:(double)startFraction
                                endFraction:(double)endFraction
                                 modulation:(KKIntervalModulation)modulation
                                  intensity:(double)intensity
                                  frequency:(double)frequency
                                       seed:(uint32_t)seed
                                     linked:(BOOL)linked
                                showsLinked:(BOOL)showsLinked
                                 partLabels:(NSArray<NSArray<NSString *> *> *)
                                                partCompoundLabels
                                 partStates:(NSArray<NSArray<NSNumber *> *> *)
                                                partCompoundStates
                                  partLanes:
                                      (NSArray<KKLane *> *)partCompoundLanesIn
                              partRebuilder:
                                  (NSArray<NSArray<NSNumber *> *> *_Nullable (
                                      ^)(void))partRebuilder
                               onModulation:
                                   (void (^)(KKIntervalModulation))onModulation
                                onIntensity:(void (^)(double))onIntensity
                                onFrequency:(void (^)(double))onFrequency
                                     onSeed:(void (^)(uint32_t))onSeed
                                   onLinked:(void (^)(BOOL))onLinked
                            onParticipation:(void (^)(NSInteger,
                                                      BOOL))onParticipation
                                onDragBegin:(void (^)(void))onDragBegin
                                  onDragEnd:(void (^)(void))onDragEnd
                                      phase:(KKGapPopoverPhase)phase
                                  laneLabel:(NSString *)laneLabel
                             representative:(KKInterval *)representativeInterval
                             intervalReader:(KKGapIntervalReader)intervalReader
                            intervalMutator:
                                (KKGapIntervalMutator)intervalMutator {
  // "Applies to" as the Animated-style checklist (master + indented component
  // rows) instead of the compound pill bar - see the Transition path. The graph
  // hands over the live lane behind each compound (its category + owner drive
  // the two pill navs); the label-matched fallback only covers a caller that
  // passes none.
  NSArray<KKLane *> *partCompoundLanes =
      (partCompoundLanesIn.count == partCompoundLabels.count)
          ? partCompoundLanesIn
          : [self _compoundLanesForCompounds:partCompoundLabels];

  // Layer re-scope: update the open modulation editor's checklist + state in
  // place instead of building a new popover (see the gap popover for the rate).
  if (_rescopingGapPopover && _openHoldModEditor) {
    [_openHoldModEditor rescopeCompoundParticipationLanes:partCompoundLanes
                                                compounds:partCompoundLabels
                                                   states:partCompoundStates];
    [_openHoldModEditor selectParticipationLayerKey:
                            [self _hostSelectedLayerKeyIn:partCompoundLanes]];
    // Re-wire the toggle to this layer's callback (captures its tagged labels).
    [self _wireSegmentEditor:_openHoldModEditor
             onParticipation:onParticipation
                 onDragBegin:onDragBegin
                   onDragEnd:onDragEnd];
    _openHoldModEditor.curveType = KKModulationToPill(modulation);
    _openHoldModEditor.intensity = intensity;
    _openHoldModEditor.frequency = frequency;
    _openHoldModEditor.seed = seed;
    _openHoldModEditor.linked = linked;
    _openHoldModRebuilder = [partRebuilder copy];
    _openHoldModIntervalReader = [intervalReader copy];
    [self _resizeOpenSegmentPopoverToEditor:_openHoldModEditor];
    return;
  }

  KKSegmentEditView *edit =
      [[KKSegmentEditView alloc] initWithKind:KKSegmentEditKindHold
                                  showsLinked:showsLinked
                                   bulkHeader:NO
                   participationCompoundLanes:partCompoundLanes
                       participationCompounds:partCompoundLabels
                  participationCompoundStates:partCompoundStates];
  // Open on the host's selected owner (see the Transition path), before the
  // popover is sized to the row count.
  [edit selectParticipationLayerKey:
            [self _hostSelectedLayerKeyIn:partCompoundLanes]];
  [self _wireSegmentEditor:edit
           onParticipation:onParticipation
               onDragBegin:onDragBegin
                 onDragEnd:onDragEnd];
  edit.curveType = KKModulationToPill(modulation);
  edit.intensity = intensity;
  edit.frequency = frequency;
  edit.seed = seed;
  edit.linked = linked;
  edit.onCurveTypeChanged = ^(NSInteger ct) {
    if (onModulation)
      onModulation(KKPillToModulation(ct));
  };
  edit.onIntensityChanged = ^(double v) {
    if (onIntensity)
      onIntensity(v);
  };
  edit.onFrequencyChanged = ^(double v) {
    if (onFrequency)
      onFrequency(v);
  };
  edit.onSeedChanged = ^(uint32_t s) {
    if (onSeed)
      onSeed(s);
  };
  edit.onLinkedChanged = ^(BOOL l) {
    if (onLinked)
      onLinked(l);
  };

  // Same header treatment as the curve popover (the editor is shared).
  NSString *range = [NSString
      stringWithFormat:@"%@ → %@", [self _timeStringForFraction:startFraction],
                       [self _timeStringForFraction:endFraction]];
  KKPopoverHeaderView *header = [[KKPopoverHeaderView alloc]
      initWithTitle:KKLoc(@"Modulation", @"Section: modulation settings.")
             detail:range
         symbolName:@"waveform"];

  // Stash for external refresh on applyTimeline (cmd-Z etc); onClose clears.
  _openHoldModEditor = edit;
  _openHoldModRebuilder = [partRebuilder copy];
  _openHoldModIntervalReader = [intervalReader copy];
  __weak typeof(self) weakClose = self;
  [self _presentSegmentEditor:edit
                       header:header
                        phase:phase
                    laneLabel:laneLabel
               representative:representativeInterval
               intervalReader:intervalReader
              intervalMutator:intervalMutator
                       anchor:anchor
                  postApplies:(partCompoundLanes != nil && _activeTab != 1)
                      onClose:^{
                        __strong typeof(weakClose) sc = weakClose;
                        if (!sc)
                          return;
                        sc->_openHoldModEditor = nil;
                        sc->_openHoldModRebuilder = nil;
                        sc->_openHoldModIntervalReader = nil;
                      }];
}

- (NSButton *)_makePopoverCloseButton {
  NSImage *img = [NSImage imageWithSystemSymbolName:@"xmark"
                           accessibilityDescription:nil];
  NSButton *b =
      [NSButton buttonWithImage:img ?: [[NSImage alloc] init]
                         target:self
                         action:@selector(_segmentCloseButtonClicked:)];
  b.translatesAutoresizingMaskIntoConstraints = NO;
  b.bordered = NO;
  b.bezelStyle = NSBezelStyleShadowlessSquare;
  b.imageScaling = NSImageScaleProportionallyDown;
  // Fire on mouseDOWN so the close survives a popover reopen (FCP forwards the
  // mouseDown but not the matching mouseUp to a reused-then-reopened window).
  [b.cell sendActionOn:NSEventMaskLeftMouseDown];
  return b;
}

- (KKPopoverPeekButton *)_makePopoverPeekButton {
  __weak typeof(self) weak = self;
  return KKCreateCompositionPeekButton(^(BOOL held) {
    [weak _setCompositionPeekHeld:held keyboard:NO];
  });
}

- (KKPopoverSidebarButton *)_makePopoverSidebarButton {
  __weak typeof(self) weak = self;
  return KKCreateSidebarVisibilityButton(
      self.editorSidebarVisible, ^(BOOL visible) {
        [weak _setEditorSidebarVisible:visible];
      });
}

- (KKPopoverSidebarButton *)_makePopoverRightPanelButton {
  __weak typeof(self) weak = self;
  return KKCreateRightPanelVisibilityButton(
      self.editorRightPanelVisible, ^(BOOL visible) {
        [weak _setEditorRightPanelVisible:visible];
      });
}

- (void)_segmentCloseButtonClicked:(id)sender {
  [self _closeEditorPanel];
}

// Unified static-values popover presenter. Constants AND keypose (boundary)
// modes flow through here - whatever feature lives in this method is in BOTH
// popovers automatically. New popover features go here, NOT into either
// caller, so the two never drift apart again.

@end
