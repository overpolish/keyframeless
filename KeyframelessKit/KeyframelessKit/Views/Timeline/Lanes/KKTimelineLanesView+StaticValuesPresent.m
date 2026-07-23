/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLinkBus.h"
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
  // An already-open static popover switches between constants and keypose mode
  // (and navigates) entirely IN PLACE - the popover window is never closed +
  // reopened, because rebuilding the mini-viewer into the recycled ViewBridge
  // window kills its OSC drag (FCP stops forwarding the drag session to a
  // reopened popover). See -reconfigureForEditsKeypose: and the reconfigure
  // branch at the view-create site below.
  BOOL popoverOpen = (_openContentPopover.isShown && _openStaticView != nil);

  // Constants edits lane constants, not a specific keypose/gap, so clear any
  // active graph highlight. A keypose->constants reconfigure switches in place
  // without firing the close notification the highlight otherwise clears on, so
  // it would linger; do it explicitly.
  if (!cfg.isBoundary) {
    [_basicGraph clearPopoverHighlights];
    [_advancedGraph clearPopoverHighlights];
  }
  // Light up (or dim) the Constants button: this present covers constants<->
  // keypose in both directions (fresh + in-place reconfigure).
  if (self.onConstantsPopoverActiveChanged)
    self.onConstantsPopoverActiveChanged(!cfg.isBoundary);

  if (cfg.isBoundary) {
    // Keypose->keypose navigation: optimized row-only in-place update.
    if (popoverOpen && _openStaticIsBoundary) {
      [self _updateBoundaryPopoverInPlaceWithLanes:cfg.lanes
                                          fraction:cfg.fraction
                                    excludedLabels:cfg.excludedLabels];
      return;
    }
    // Keypose-mode delegate setup (constants->keypose reconfigure OR fresh
    // open).
    [self _applyKeyposeEditStateWithLanes:cfg.lanes
                                 fraction:cfg.fraction
                           excludedLabels:cfg.excludedLabels];
    [self _publishBoundaryRequestForFraction:cfg.fraction];
    // Static playhead → no render → -scheduleInputs: never sees the request
    // just written. Nudge one render so the boundary frame resolves now.
    if (self.onBoundaryPreviewNeedsRender)
      self.onBoundaryPreviewNeedsRender();
  } else {
    // Keypose->constants: the fresh-constants path never turns boundary
    // editing on, so a reconfigure FROM keypose mode must run the full exit
    // (the close handler only exits when the CLOSING popover is keypose-mode,
    // which after this switch it no longer is).
    if (popoverOpen && _openStaticIsBoundary)
      [self _exitKeyposeEditState];
    // Constants previews at the LIVE playhead, not t=0: a property animated to
    // start off-canvas (e.g. flying in) would otherwise render its first-frame
    // pose, pushing the object + its handles out of the mini-viewer. Seeded
    // HERE - after the keypose exit above, which resets editFraction to 0 - so
    // the in-place keypose->constants switch shows the same frame a fresh
    // constants open does. Constant lanes are single-keypose so editFraction
    // doesn't move them, and the constants WRITE path ignores editFraction too
    // (it always replaces the t=0 keypose - see
    // -_timelineBySettingValues:forLabel:). boundaryEditing stays NO, so
    // handle gating / writes are unchanged. Reset to 0 on close.
    id constantsDel = self.miniViewerDelegate;
    if ([constantsDel
            respondsToSelector:NSSelectorFromString(@"setEditFraction:")]) {
      double playFrac = [self _activeGraph].playheadFraction;
      if (playFrac < 0.0)
        playFrac = 0.0; // render tick hasn't pushed a playhead yet
      [constantsDel setValue:@(playFrac) forKey:@"editFraction"];
    }
  }

  __weak typeof(self) weak = self;

  // Per-tick commit + drag-end re-commit pattern (shared by both modes). The
  // drag-undo bracket (caller-supplied onDragBegin/onDragEnd) coalesces all
  // per-tick writes into a single undo entry.
  __block NSString *pendingLabel = nil;
  __block NSArray<NSNumber *> *pendingValues = nil;
  __block BOOL dragging = NO;
  BOOL isBoundary = cfg.isBoundary;
  // Live-gated on the CURRENT mode (not the mode at wiring time): handlers
  // created by one present keep firing after an in-place mode switch.
  void (^suppressBoundaryRedrive)(void) = ^{
    __strong typeof(weak) s = weak;
    if (s && s->_openStaticIsBoundary)
      [s _suppressBoundaryRedrive];
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

  // Feed the popover's mini viewer the SAME corrected timeline the rows read
  // (template-seeded aspectLinked / aspectLinkable), so the mini's OSC overlay
  // agrees with the value rows instead of a stale applyTimeline copy.
  if ([self.miniViewerDelegate isKindOfClass:[KKMiniViewerRenderer class]])
    ((KKMiniViewerRenderer *)self.miniViewerDelegate).timeline = _timeline;

  _KKStaticValuesPopoverView *staticView;
  if (popoverOpen) {
    // Re-establish the mode-specific leading gutter handlers for the NEW mode:
    // they are set once at fresh-create and don't carry across an in-place
    // switch, so a keypose->constants switch would otherwise keep the keypose's
    // (nil) add-to-animated handler and the constant rows would show no
    // curve-glyph button. Constants supply onAddToAnimated; an Advanced keypose
    // supplies onRemove. Clear whichever the new mode doesn't use. Set BEFORE
    // reconfigure (it rebuilds the rows from these handlers).
    [_openStaticView
        setRowAddToAnimatedHandler:cfg.onAddToAnimated
                                       ? ^(NSString *label) {
                                           cfg.onAddToAnimated(label);
                                         }
                                       : nil];
    [_openStaticView
        setRowRemoveHandler:cfg.onRemove ? ^(NSString *label) {
          suppressBoundaryRedrive();
          cfg.onRemove(label);
        } : nil];
    // In-place mode switch (constants<->keypose, either direction) - the
    // mini-viewer/overlay is preserved, no close+reopen, no new popover shown.
    [_openStaticView reconfigureForEditsKeypose:cfg.isBoundary
                                      withLanes:cfg.lanes
                                 excludedLabels:cfg.excludedLabels
                                    headerTitle:cfg.headerTitle
                                   headerDetail:cfg.headerDetail
                                     headerIcon:cfg.headerIcon
                                     renderMode:cfg.renderMode
                                  onModeChanged:cfg.onModeChanged
                                  onHandleValue:onHandleValue
                                    onDragBegin:onDragBeginBlock
                                      onDragEnd:onDragEndBlock
                                     onNavigate:cfg.onNavigate];
    staticView = _openStaticView;
    // Falls through to the shared mode wiring below: reconfigure only
    // re-points value/drag/nav handlers, so every OTHER mode-routed handler
    // (aspect link, gradient type, filmstrip, palette batch) must be re-wired
    // here too or it keeps the OLD mode's routing - the popover-drift bug
    // class this presenter exists to prevent.
  } else {
    staticView = [[_KKStaticValuesPopoverView alloc]
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
  }
  _openStaticView = staticView;
  _openStaticIsBoundary = cfg.isBoundary;
  weakStaticContent = staticView;

  // Scope the expression reference picker to this clip's project: read the
  // clip's OWN manifest off the bus (the render process stamped it with the
  // project id; it can't push it across to this ViewBridge process). nil uuid /
  // no manifest yet = library-wide, the safe fallback.
  staticView.documentID = KKLinkDocumentIDForSelfUUID(_linkSelfUUID);
  staticView.onCategoryChanged = cfg.onCategoryChanged;
  // Code-lane edits (e.g. a shader source) are discrete text commits: write the
  // new string to the lane's codeString through the standard lane-replace path.
  staticView.onHandleCode = ^(NSString *label, NSString *code) {
    __strong typeof(weak) s = weak;
    [s _setLaneCode:code forLabel:label];
  };
  staticView.onHandleCodeSections =
      ^(NSString *label,
        NSArray<NSDictionary<NSString *, NSString *> *> *sections) {
        __strong typeof(weak) s = weak;
        [s _setLaneCodeSections:sections forLabel:label];
      };
  // Palette reroll: commit every changed swatch inside one drag-undo bracket so
  // the whole set persists as a single undo entry (the per-lane drag path only
  // commits one label per bracket, which is why the batch path exists).
  staticView.onCommitBatch = ^(NSArray<NSString *> *labels,
                               NSArray<NSArray<NSNumber *> *> *valuesList) {
    if (cfg.onDragBegin)
      cfg.onDragBegin();
    for (NSInteger i = 0; i < (NSInteger)labels.count; i++)
      commit(labels[i], valuesList[i]);
    if (cfg.onDragEnd)
      cfg.onDragEnd();
  };
  __weak typeof(self) weakSize = self;
  staticView.onSizeChanged = ^(NSInteger sizeIndex) {
    [weakSize _miniViewerSizeDidChange:sizeIndex];
  };
  __weak typeof(self) weakClose = self;
  staticView.onCloseTapped = ^{
    __strong typeof(weakClose) s = weakClose;
    [s->_openContentPopover close];
  };

  // Per-keypose smooth toggle (spatialCurvable lanes): discrete write routed
  // to whichever graph owns the open keypose. Advanced keys by fraction, Basic
  // by its diamond mapping - each resolves the keypose internally.
  __weak typeof(self) weakSmooth = self;
  [staticView setOnSmoothToggled:^(NSString *label, BOOL on) {
    __strong typeof(weakSmooth) s = weakSmooth;
    if (!s)
      return;
    [s _suppressBoundaryRedrive];
    [[s _activeGraph] writeSpatialSmoothForLabel:label
                                          atFrac:s->_openStaticBoundaryFraction
                                            isOn:on];
  }];

  // Aspect link is a global per-lane toggle (no fraction). The keypose popover
  // routes it to whichever graph owns the open keypose; the constants popover
  // edits the lanes view's own _timeline, so it persists there instead (else
  // the toggle never reached _timeline and the next constant scrub's _refresh
  // re-read the stale linked lane and relocked it).
  __weak typeof(self) weakLink = self;
  [staticView setOnLinkToggled:^(NSString *label, BOOL on) {
    __strong typeof(weakLink) s = weakLink;
    if (!s)
      return;
    if (!s->_openStaticIsBoundary) {
      [s _setLaneAspectLinked:on forLabel:label];
      return;
    }
    [s _suppressBoundaryRedrive];
    [[s _activeGraph] writeAspectLinkedForLabel:label isOn:on];
  }];

  // Parameter linking: the label's right-click Add/Remove Expression AND the
  // inline editor's typed commits. Lane-level (non-fractional) like the aspect
  // lock, so it persists against the lanes view's own _timeline for both the
  // constants and keypose popovers.
  __weak typeof(self) weakExpr = self;
  [staticView
      setOnSetLinkExpression:^(NSString *label, NSString *_Nullable expr) {
        __strong typeof(weakExpr) s = weakExpr;
        if (!s)
          return;
        // Suppress the boundary (keypose) popover re-drive, exactly like the
        // smooth / aspect-link toggles: an expression edit persists and FCP
        // echoes it back, and a full rebuild would tear down the FOCUSED inline
        // editor mid-type and cascade (rebuild -> echo -> rebuild, accelerating
        // -> crash). The inline editor already reflects the edit; structural
        // add/remove is handled in place by the popover, so no rebuild is
        // needed here.
        [s _suppressBoundaryRedrive];
        [s _setLaneLinkExpression:expr forLabel:label];
      }];

  // Gradient type (radial/linear): a single non-animated property, so editing
  // it in the keypose editor rewrites every keypose of the lane. Live-gated to
  // keypose mode (the constants editor commits it per-row).
  __weak typeof(self) weakType = self;
  [staticView setOnGradientTypeChanged:^(NSString *label, NSInteger type) {
    __strong typeof(weakType) s = weakType;
    if (!s || !s->_openStaticIsBoundary)
      return;
    [s _suppressBoundaryRedrive];
    [[s _activeGraph] writeGradientTypeForLabel:label type:type];
  }];

  // Onion-skin filmstrip: clicking an inactive cell asks the active tab's
  // graph to swap the popover to that KP. Advanced rebinds in place; Basic
  // re-opens. Wired in both modes (live-gated) so a constants-born popover
  // switched to keypose in place gets a working filmstrip.
  __weak typeof(self) weakSelf = self;
  staticView.miniViewer.onFilmstripCellActivated = ^(double newFrac) {
    __strong typeof(weakSelf) s = weakSelf;
    if (!s || !s->_openStaticIsBoundary)
      return;
    [[s _activeGraph] requestValuePopoverAtFraction:newFrac];
    if (s.onGuideFilmstripCellActivated)
      s.onGuideFilmstripCellActivated(newFrac);
  };

  if (cfg.isBoundary) {
    [staticView
        setHeaderLinked:[self _anyLinkedKeyposeAtFraction:cfg.fraction]];
    [self _refreshBoundaryPopoverNavEnabled];
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
    // Set the handler then rebuild once so the gutter shows on init rows
    // (the in-place path already set it BEFORE reconfigure's rebuild).
    if (cfg.onRemove && !popoverOpen) {
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
  // on init rows (in-place: already set before reconfigure). Lives OUTSIDE
  // the isBoundary block because the constants popover by definition has
  // isBoundary == NO.
  if (cfg.onAddToAnimated && !popoverOpen) {
    [staticView setRowAddToAnimatedHandler:^(NSString *label) {
      cfg.onAddToAnimated(label);
    }];
    [staticView rebuildRowsWithLanes:cfg.lanes
                      excludedLabels:cfg.excludedLabels];
  }

  // An in-place mode switch ends here - the popover is already shown and its
  // close handler (which reads the LIVE mode) is already installed.
  if (popoverOpen)
    return;

  // Clamp the initial popover height to the anchor's screen so a small /
  // low-resolution display doesn't push the bottom rows off-screen. The view's
  // internal rows scroller (under the sticky mini-viewer + category pill) takes
  // up the overflow; the popover self-clamps on every later re-fit. On a tall
  // screen this is a no-op (clamp == natural, no scroll).
  [staticView clampContentToScreenOfView:anchor];

  // Anchor the popover beside the inspector's timeline area (whichever side has
  // more screen space), NOT at the clicked marker/button. It's a companion that
  // switches content in place, so it should sit in one consistent spot out of
  // the work area instead of jumping around / covering the keyframes as you
  // move between keyposes.
  NSRectEdge sideEdge = [self _inspectorSidePreferredEdge];

  NSPopover *popover = [self
      _showPopoverWithContent:staticView
                     fromView:self
                preferredEdge:sideEdge
                      onClose:^{
                        __strong typeof(weak) s = weak;
                        if (!s)
                          return;
                        [NSNotificationCenter.defaultCenter
                            postNotificationName:
                                KKStaticValuesPopoverDidCloseNotification
                                          object:s];
                        s->_openStaticView = nil;
                        // Read the LIVE mode, not the fresh-create capture:
                        // an in-place constants<->keypose switch changes it,
                        // and closing after a switch must tear down the mode
                        // the popover ENDED in (a constants-born popover
                        // closed in keypose mode still needs the full keypose
                        // exit, or the render keeps publishing stale boundary
                        // slots).
                        BOOL wasBoundary = s->_openStaticIsBoundary;
                        s->_openStaticIsBoundary = NO;
                        if (wasBoundary) {
                          [s _exitKeyposeEditState];
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
                        // Dim the Constants button - the popover is gone (or
                        // swapped to a gap/option). A keypose/constants switch
                        // doesn't hit this (it's in-place); the present above
                        // drives the button for that.
                        if (s.onConstantsPopoverActiveChanged)
                          s.onConstantsPopoverActiveChanged(NO);
                        if (s.onStaticValuesPopoverClosed)
                          s.onStaticValuesPopoverClosed();
                      }];
  staticView.popover = popover;

  // Companion-panel signal: a plugin (e.g. Canvas's layer list) observes this
  // to show a panel beside the popover (scoped to this lanes view via
  // `object`). A keypose (boundary) popover passes its `fraction` so the
  // companion can gray layers with no keypose there; a constants popover leaves
  // every layer selectable.
  KKPostStaticValuesPopoverDidOpen(popover, self,
                                   isBoundary ? @"keypose" : @"constants",
                                   isBoundary, cfg.fraction);

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
