/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKMiniViewerRenderer.h"
#import "KKMiniViewerView.h"
#import "KKPopoverHeaderView.h"
#import "KKPopoverKeepAlive.h"
#import "KKTimelineLanesView+Guide.h"
#import "KKTimelineLanesView_Popovers.h"
#import "KKTokens.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKSegmentEditView.h>

@implementation KKTimelineLanesView (StaticValuesPresent)

- (void)_presentStaticValuesPopoverFromAnchor:(NSView *)anchor
                                       config:
                                           (_KKStaticValuesPopoverConfig *)cfg {
  // Boundary-only preamble: in-place rebind / defer-if-other-popover-open /
  // mini-viewer state setup / boundary-request publish + render nudge.
  if (cfg.isBoundary) {
    if (_openContentPopover.isShown && _openStaticIsBoundary &&
        _openStaticView) {
      [self _updateBoundaryPopoverInPlaceWithLanes:cfg.lanes
                                          fraction:cfg.fraction
                                    excludedLabels:cfg.excludedLabels];
      return;
    }
    if (_openContentPopover.isShown) {
      [_openContentPopover close];
      __weak typeof(self) wself = self;
      _KKStaticValuesPopoverConfig *capturedCfg = cfg;
      dispatch_async(dispatch_get_main_queue(), ^{
        [wself _presentStaticValuesPopoverFromAnchor:anchor config:capturedCfg];
      });
      return;
    }
    [_openContentPopover close];

    KKSetBoundaryEditing(self.miniViewerDelegate, YES, cfg.fraction);
    KKSetSuppressedHandles(self.miniViewerDelegate, cfg.excludedLabels);
    _openStaticBoundaryFraction = cfg.fraction;
    _openStaticBoundaryLanes = [cfg.lanes copy];
    _openStaticBoundaryExcluded = [cfg.excludedLabels copy];
    [self _publishBoundaryRequestForFraction:cfg.fraction];
    // Static playhead → no render → -scheduleInputs: never sees the request
    // just written. Nudge one render so the boundary frame resolves now.
    if (self.onBoundaryPreviewNeedsRender)
      self.onBoundaryPreviewNeedsRender();
  }

  __weak typeof(self) weak = self;

  // Per-tick commit + drag-end re-commit pattern (shared by both modes). The
  // drag-undo bracket (caller-supplied onDragBegin/onDragEnd) coalesces all
  // per-tick writes into a single undo entry.
  __block NSString *pendingLabel = nil;
  __block NSArray<NSNumber *> *pendingValues = nil;
  __block BOOL dragging = NO;
  BOOL isBoundary = cfg.isBoundary;
  void (^suppressBoundaryRedrive)(void) = ^{
    __strong typeof(weak) s = weak;
    if (s && isBoundary)
      s->_boundaryRedriveSuppressUntil =
          [NSDate timeIntervalSinceReferenceDate] + 0.4;
  };
  void (^commit)(NSString *, NSArray<NSNumber *> *) =
      ^(NSString *label, NSArray<NSNumber *> *values) {
        __strong typeof(weak) s = weak;
        if (cfg.onValue)
          cfg.onValue(label, values);
        else
          [s _setLaneValues:values forLabel:label];
      };

  // During drag we push live values into the mini viewer renderer (which
  // applies the real plugin shader in-process) bound to the popover's
  // edit fraction - in filmstrip/onion mode each cell encodes at its own
  // editFraction, so binding the override to cfg.fraction keeps the neighbour
  // cells on their own keypose values. No FxPlug param round-trip, no Flexo
  // write-lock contention, no deadlock. The single real commit happens on
  // drag end, coalescing into one undo entry.
  __weak _KKStaticValuesPopoverView *weakStaticContent = nil;
  void (^pushLive)(NSString *, NSArray<NSNumber *> *) = ^(
      NSString *label, NSArray<NSNumber *> *values) {
    __strong typeof(weak) s = weak;
    // Read the live fraction at push time, not capture - boundary
    // navigation (cell click / arrows) updates _openStaticBoundaryFraction
    // without rebuilding the popover, so capturing cfg.fraction would
    // leave the override pinned to the original keypose.
    // Snap to the representative collapsed-slot fraction: when the popover
    // is on the second KP of a tied-hold pair, _openStaticBoundaryFraction
    // points past the slot's tag and the renderer's per-slot editFraction
    // (slot tag) wouldn't match. Use the largest collapsed frac <= want so
    // both halves of a linked pair push into the same slot.
    double liveFraction = 0.0;
    if (cfg.isBoundary) {
      double want = s->_openStaticBoundaryFraction;
      liveFraction = want;
      NSArray<NSNumber *> *fracs = [s _animatableKPFractions];
      for (NSNumber *f in fracs) {
        if (f.doubleValue <= want + 1e-6)
          liveFraction = f.doubleValue;
        else
          break;
      }
    }
    id<KKMiniViewerDelegate> del = s.miniViewerDelegate;
    if ([(NSObject *)del
            respondsToSelector:@selector(setLiveValues:forLabel:atFraction:)]) {
      NSMethodSignature *sig = [(NSObject *)del
          methodSignatureForSelector:@selector(
                                         setLiveValues:forLabel:atFraction:)];
      NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
      [inv setSelector:@selector(setLiveValues:forLabel:atFraction:)];
      [inv setTarget:del];
      [inv setArgument:&values atIndex:2];
      [inv setArgument:&label atIndex:3];
      [inv setArgument:&liveFraction atIndex:4];
      [inv invoke];
    }
    __strong _KKStaticValuesPopoverView *sv = weakStaticContent;
    [sv.miniViewer setNeedsDisplay:YES];
  };

  void (^onHandleValue)(NSString *, NSArray<NSNumber *> *) =
      ^(NSString *label, NSArray<NSNumber *> *values) {
        __strong typeof(weak) s = weak;
        suppressBoundaryRedrive();
        if (dragging) {
          // Live preview only - no FxPlug write. Stash for drag-end commit.
          pushLive(label, values);
          pendingLabel = label;
          pendingValues = values;
        } else {
          // Discrete edit (text field, no drag) - commit immediately.
          commit(label, values);
        }
        if (s.onStaticValueChanged)
          s.onStaticValueChanged(label, values);
      };

  void (^onDragBeginBlock)(void) = ^{
    suppressBoundaryRedrive();
    dragging = YES;
    if (cfg.onDragBegin)
      cfg.onDragBegin();
  };

  void (^onDragEndBlock)(void) = ^{
    __strong typeof(weak) s = weak;
    NSString *endedLabel = pendingLabel;
    NSArray<NSNumber *> *endedValues = pendingValues;
    if (pendingLabel && pendingValues) {
      // The one real commit per drag goes through FxPlug here.
      commit(pendingLabel, pendingValues);
      pendingLabel = nil;
      pendingValues = nil;
    }
    // Drop the live overrides so the renderer reads from the just-committed
    // timeline on the next draw. Without this, stale live values would keep
    // winning over the freshly persisted blob.
    id<KKMiniViewerDelegate> del = s.miniViewerDelegate;
    if ([(NSObject *)del respondsToSelector:@selector(clearLiveValues)])
      [(NSObject *)del performSelector:@selector(clearLiveValues)];
    dragging = NO;
    if (cfg.onDragEnd)
      cfg.onDragEnd();
    if (endedLabel && endedValues && s.onStaticValueDragEnded)
      s.onStaticValueDragEnded(endedLabel, endedValues);
  };

  _KKStaticValuesPopoverView *staticView = [[_KKStaticValuesPopoverView alloc]
        initWithLanes:cfg.lanes
       descriptorPath:self.miniViewerDescriptorPath
           clipAspect:self.miniViewerClipAspect
          headerTitle:cfg.headerTitle
         headerDetail:cfg.headerDetail
           headerIcon:cfg.headerIcon
       canvasDelegate:self.miniViewerDelegate
           renderMode:cfg.renderMode
        onModeChanged:cfg.onModeChanged
           onNavigate:cfg.onNavigate
        onHandleValue:onHandleValue
          onDragBegin:onDragBeginBlock
            onDragEnd:onDragEndBlock
         editsKeypose:cfg.isBoundary
      initialCategory:cfg.initialCategory];
  staticView.onCategoryChanged = cfg.onCategoryChanged;

  _openStaticView = staticView;
  _openStaticIsBoundary = cfg.isBoundary;
  weakStaticContent = staticView;

  // Per-keypose smooth toggle (spatialCurvable lanes): discrete write routed
  // to whichever graph owns the open keypose. Advanced keys by fraction, Basic
  // by its diamond mapping - each resolves the keypose internally.
  __weak typeof(self) weakSmooth = self;
  [staticView setOnSmoothToggled:^(NSString *label, BOOL on) {
    __strong typeof(weakSmooth) s = weakSmooth;
    if (!s)
      return;
    s->_boundaryRedriveSuppressUntil =
        [NSDate timeIntervalSinceReferenceDate] + 0.4;
    double frac = s->_openStaticBoundaryFraction;
    if (s->_activeTab == 1)
      [s->_advancedGraph writeSpatialSmoothForLabel:label atFrac:frac isOn:on];
    else
      [s->_basicGraph writeSpatialSmoothForLabel:label atFrac:frac isOn:on];
  }];

  // Aspect link is a global per-lane toggle (no fraction), routed to whichever
  // graph owns the open popover.
  __weak typeof(self) weakLink = self;
  [staticView setOnLinkToggled:^(NSString *label, BOOL on) {
    __strong typeof(weakLink) s = weakLink;
    if (!s)
      return;
    s->_boundaryRedriveSuppressUntil =
        [NSDate timeIntervalSinceReferenceDate] + 0.4;
    if (s->_activeTab == 1)
      [s->_advancedGraph writeAspectLinkedForLabel:label isOn:on];
    else
      [s->_basicGraph writeAspectLinkedForLabel:label isOn:on];
  }];

  // Gradient type (radial/linear): a single non-animated property, so editing
  // it in the keypose editor rewrites every keypose of the lane. Only wired for
  // the keypose (boundary) popover; the constants editor commits it per-row.
  if (cfg.isBoundary) {
    __weak typeof(self) weakType = self;
    [staticView setOnGradientTypeChanged:^(NSString *label, NSInteger type) {
      __strong typeof(weakType) s = weakType;
      if (!s)
        return;
      s->_boundaryRedriveSuppressUntil =
          [NSDate timeIntervalSinceReferenceDate] + 0.4;
      if (s->_activeTab == 1)
        [s->_advancedGraph writeGradientTypeForLabel:label type:type];
      else
        [s->_basicGraph writeGradientTypeForLabel:label type:type];
    }];
  }

  if (cfg.isBoundary) {
    [staticView
        setHeaderLinked:[self _anyLinkedKeyposeAtFraction:cfg.fraction]];
    [self _refreshBoundaryPopoverNavEnabled];
    // Onion-skin filmstrip: clicking an inactive cell asks the active tab's
    // graph to swap the popover to that KP. Advanced rebinds in place;
    // Basic re-opens.
    __weak KKTimelineAdvancedView *weakAdv = _advancedGraph;
    __weak KKTimelineBasicView *weakBasic = _basicGraph;
    __weak typeof(self) weakSelf = self;
    staticView.miniViewer.onFilmstripCellActivated = ^(double newFrac) {
      __strong typeof(weakSelf) s = weakSelf;
      if (!s)
        return;
      if (s->_activeTab == 1)
        [weakAdv requestValuePopoverAtFraction:newFrac];
      else
        [weakBasic requestValuePopoverAtFraction:newFrac];
      if (s.onGuideFilmstripCellActivated)
        s.onGuideFilmstripCellActivated(newFrac);
    };
  }

  [staticView applyDefaultsProvider:^NSArray<NSNumber *> *(NSString *l) {
    __strong typeof(weak) s = weak;
    return s ? [s _defaultValuesForLabel:l] : nil;
  }];

  if (cfg.isBoundary) {
    // Advanced is per-property ("no keypose here"); Basic shares one phase
    // across properties ("excluded from this phase"). Same widget, different
    // copy.
    NSString *excludedMsg =
        (_activeTab == 1)
            ? KKLoc(@"No keypose here", @"Keypose popover empty state.")
            : KKLoc(@"Excluded from this phase",
                    @"Keypose popover: excluded from phase.");
    [staticView applyExcludedLabels:cfg.excludedLabels
                            message:excludedMsg
                          onAnimate:^(NSString *label) {
                            suppressBoundaryRedrive();
                            if (cfg.onAnimate)
                              cfg.onAnimate(label);
                          }];
    // Advanced supplies onRemove → editable rows get a leading "−" gutter.
    // Set the handler then rebuild once so the gutter shows on init rows.
    if (cfg.onRemove) {
      [staticView setRowRemoveHandler:^(NSString *label) {
        suppressBoundaryRedrive();
        cfg.onRemove(label);
      }];
      [staticView rebuildRowsWithLanes:cfg.lanes
                        excludedLabels:cfg.excludedLabels];
    }
  }
  // Constants popover (non-boundary) supplies onAddToAnimated → leading
  // curve-glyph gutter. Set the handler then rebuild so the gutter shows
  // on init rows. Lives OUTSIDE the isBoundary block because the constants
  // popover by definition has isBoundary == NO.
  if (cfg.onAddToAnimated) {
    [staticView setRowAddToAnimatedHandler:^(NSString *label) {
      cfg.onAddToAnimated(label);
    }];
    [staticView rebuildRowsWithLanes:cfg.lanes
                      excludedLabels:cfg.excludedLabels];
  }

  NSPopover *popover = [self
      _showPopoverWithContent:staticView
                     fromView:anchor
                      onClose:^{
                        __strong typeof(weak) s = weak;
                        if (!s)
                          return;
                        [NSNotificationCenter.defaultCenter
                            postNotificationName:
                                KKStaticValuesPopoverDidCloseNotification
                                          object:s];
                        s->_openStaticView = nil;
                        if (isBoundary) {
                          s->_openStaticIsBoundary = NO;
                          KKSetBoundaryEditing(s.miniViewerDelegate, NO, 0.0);
                          KKSetSuppressedHandles(s.miniViewerDelegate, nil);
                          KKWriteBoundaryRequest(s.miniViewerRequestPath, 0.0,
                                                 NO);
                        } else {
                          // Constants popover previewed at the live playhead
                          // (set in -showStaticValuesPopoverFromView:); restore
                          // the t=0 default so a later non-popover draw isn't
                          // pinned to a stale playhead fraction.
                          id del = s.miniViewerDelegate;
                          if ([del respondsToSelector:NSSelectorFromString(
                                                          @"setEditFraction:")])
                            [del setValue:@0 forKey:@"editFraction"];
                        }
                        if (s.onStaticValuesPopoverClosed)
                          s.onStaticValuesPopoverClosed();
                      }];
  staticView.popover = popover;

  // Companion-panel signal: a plugin (e.g. Canvas's layer list) observes this
  // to show a panel beside the popover. Scoped to this lanes view via `object`.
  // `contentRect` is the VISIBLE card's screen rect (the window frame includes
  // shadow + arrow padding, so it's taller/wider than the card) - a companion
  // panel aligns to this, not the window frame.
  NSView *contentView = popover.contentViewController.view;
  NSWindow *popoverWindow = contentView.window;
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  if (popoverWindow) {
    info[@"window"] = popoverWindow;
    info[@"contentView"] = contentView; // so a companion can re-align on flip
    NSRect cardScreen = [popoverWindow
        convertRectToScreen:[contentView convertRect:contentView.bounds
                                              toView:nil]];
    info[@"contentRect"] = [NSValue valueWithRect:cardScreen];
  }
  // A keypose (boundary) popover edits one moment in time: a companion layer
  // list uses `isBoundary` + `fraction` to gray layers that have no keypose at
  // that time. A constants popover sets isBoundary NO (every layer selectable).
  info[@"isBoundary"] = @(isBoundary);
  info[@"fraction"] = @(cfg.fraction);
  info[@"kind"] = isBoundary ? @"keypose" : @"constants";
  [NSNotificationCenter.defaultCenter
      postNotificationName:KKStaticValuesPopoverDidOpenNotification
                    object:self
                  userInfo:info];

  if (self.onStaticValuesPopoverWillOpen) {
    __weak _KKStaticValuesPopoverView *weakStatic = staticView;
    // Settle delay: let the entrance animation finish + window attach
    // before a guide reads frames / spotlights the handle.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong typeof(weak) strong = weak;
          __strong _KKStaticValuesPopoverView *sv = weakStatic;
          if (!strong || !sv || !strong.onStaticValuesPopoverWillOpen)
            return;
          strong.onStaticValuesPopoverWillOpen(sv, KKFindMiniViewer(sv));
        });
  }
}

@end
