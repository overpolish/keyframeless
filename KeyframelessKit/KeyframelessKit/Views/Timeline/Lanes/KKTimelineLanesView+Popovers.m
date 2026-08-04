/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKFloatingPanel.h"
#import "KKLaneCategoryNav.h" // KKLaneLayerKeysWithKeyposeNearFraction
#import "KKLaneFilterBar.h"
#import "KKLocalized.h"
#import "KKLog.h"
#import "KKMiniViewerRenderer.h"
#import "KKMiniViewerView.h"
#import "KKPopoverHeaderView.h"
#import "KKPopoverKeepAlive.h"
#import "KKRemoteWindowKeyHandlerView.h"
#import "KKTimelineLanesView+Guide.h"
#import "KKTimelineLanesView_Popovers.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKSegmentEditView.h>
#import <KeyframelessKit/KKTimelineAdvancedView.h>
#import <QuartzCore/QuartzCore.h>

// Implemented in KKTimelineStaticValuesPopover.m; called on popover close to
// free the mini-viewer's GPU memory even if the backing window shell lingers.
@interface _KKStaticValuesPopoverView (Teardown)
- (void)releaseMiniViewer;
@end

// The mini-viewer delegate is a KKMiniViewerRenderer (or subclass) but its
// header framework-imports KKMiniViewerView.h, which collides with the quote
// import above (path-dedup). Toggle its boundary-editing mode via KVC to
// avoid pulling that header in here.
void KKSetBoundaryEditing(id delegate, BOOL on, double fraction) {
  if ([delegate
          respondsToSelector:NSSelectorFromString(@"setBoundaryEditing:")]) {
    [delegate setValue:@(on) forKey:@"boundaryEditing"];
    [delegate setValue:@(fraction) forKey:@"editFraction"];
  }
}

// Hide the mini-viewer handle/box for properties excluded from this phase.
void KKSetSuppressedHandles(id delegate,
                            NSArray<NSString *> *_Nullable labels) {
  if ([delegate respondsToSelector:NSSelectorFromString(
                                       @"setSuppressedHandleLabels:")])
    [delegate setValue:labels forKey:@"suppressedHandleLabels"];
}

// Reverse channel: tell the render side which clip fraction the popover is
// previewing so it can pull that frame (via -scheduleInputs:).
void KKWriteBoundaryRequest(NSString *path, double frac, BOOL active) {
  if (!path)
    return;
  // Single-time payload. `frac` and `fracs` both written for backward
  // compatibility (older render readers only see `frac`; new readers prefer
  // `fracs` for onion-skin's N-time request).
  NSDictionary *d = @{
    @"frac" : @(frac),
    @"fracs" : @[ @(frac) ],
    @"active" : @(active ? 1 : 0),
    @"gen" : @((long long)(CACurrentMediaTime() * 1000.0))
  };
  NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
  [j writeToFile:path atomically:YES];
}

// Multi-time variant - writes the list of clip fractions the onion-skin
// filmstrip wants rendered. Render side honours all of them via
// -scheduleInputs:; renderDestinationImage matches delivered tiles by
// mediaTime back into one feed slot per fraction.
void KKWriteBoundaryRequestMulti(NSString *path, NSArray<NSNumber *> *fracs,
                                 BOOL active) {
  if (!path)
    return;
  if (fracs.count == 0) {
    KKWriteBoundaryRequest(path, 0.0, active);
    return;
  }
  NSDictionary *d = @{
    @"frac" : fracs.firstObject, // legacy field = slot 0's frac
    @"fracs" : fracs,
    @"active" : @(active ? 1 : 0),
    @"gen" : @((long long)(CACurrentMediaTime() * 1000.0))
  };
  NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
  [j writeToFile:path atomically:YES];
}

KKMiniViewerView *KKFindMiniViewer(NSView *root) {
  if ([root isKindOfClass:[KKMiniViewerView class]])
    return (KKMiniViewerView *)root;
  for (NSView *sub in root.subviews) {
    KKMiniViewerView *found = KKFindMiniViewer(sub);
    if (found)
      return found;
  }
  return nil;
}

// Config object for the unified static-values popover (constants AND keypose
// modes). Single source of truth: every knob lives here. The constants popover
// leaves the boundary-only fields nil/NO. New features go straight into
// _presentStaticValuesPopoverWithConfig: and are immediately available to
// both modes - no more drift between the two call sites.

@implementation _KKStaticValuesPopoverConfig
@end

@implementation KKTimelineLanesView (PopoversInternal)

// The lanes the Animated dropdown offers for the CURRENT owner: scoped to this
// layer's applicable params (a path's Points/Stroke aren't offered for an image
// / group) and with mode-gated lanes dropped (the whole "Color" group when Mode
// = Dynamic, the "Stroke" group when the stroke is off) via the visibleWhen
// cascade over the timeline so each controller resolves to its current value.
- (NSArray<KKLane *> *)_manageVisibleLanes {
  NSSet<NSString *> *condVisible =
      KKConditionalVisibleLaneKeys(_timeline.lanes, nil);
  NSMutableArray<KKLane *> *visibleLanes = [NSMutableArray array];
  for (KKLane *l in [self _ownerScopedAvailableLanes])
    // Only animatable lanes are offered (a structural toggle / enum can't be
    // animated), matching the manage view's own init filter.
    if (l.animatable && [condVisible containsObject:l.key])
      [visibleLanes addObject:l];
  return visibleLanes;
}

// The owner a dropdown should open on. `constantsLaneFilter` comes FIRST when a
// host supplies one: it is read live and answers YES for exactly the owner the
// host has selected right now (Mirage's rack strip), whereas `activeLayerKey`
// is our own stored copy, which a host that doesn't push its selection back to
// us can outrun. `activeLayerKey` then covers the hosts with no filter (and the
// keypose click that stored it).
- (nullable NSString *)_hostSelectedLayerKeyIn:(NSArray<KKLane *> *)lanes {
  BOOL (^filter)(KKLane *) = self.constantsLaneFilter;
  if (filter)
    for (KKLane *l in lanes)
      if (l.layerKey.length && filter(l))
        return l.layerKey;
  if (self.activeLayerKey.length)
    for (KKLane *l in lanes)
      if ([l.layerKey isEqualToString:self.activeLayerKey])
        return self.activeLayerKey;
  return nil;
}

- (void)_showManagePopoverFromView:(NSView *)anchorView {
  NSSet<NSString *> *checked = [self _optedInLabelsSet];
  __weak typeof(self) weak = self;

  NSArray<KKLane *> *visibleLanes = [self _manageVisibleLanes];

  __block _KKManagePopoverView *manageView = nil;
  manageView = [[_KKManagePopoverView alloc]
      initWithLanes:visibleLanes
      checkedLabels:checked
      minimumHeight:self.minimumManagePopoverHeight
           onToggle:^(NSString *label) {
             __strong typeof(weak) s = weak;
             if (!s)
               return;
             BOOL nowAnimatable = ![s _isAnimatableLabel:label];
             [s _setLaneAnimatable:nowAnimatable forLabel:label];
             if (nowAnimatable && s.onLaneOptedIn)
               s.onLaneOptedIn(label);
             [manageView updateCheckedLabels:[s _optedInLabelsSet]];
           }];

  // Multi-owner lane sets (Mirage's shader rack) get a layer nav above the
  // category pills, and it opens on the owner the host already has selected -
  // the user came from that entry's strip, so that is the list they mean.
  // `constantsLaneFilter` is the only live read of the host's selection the
  // lanes view has; it answers YES for exactly the selected owner's lanes, so
  // the first lane it accepts names the layer. There is no "all owners" page
  // to fall back to: an unresolvable key lands on the FIRST layer, and a
  // single-owner plugin gets no layer nav at all - today's flat list.
  [manageView selectLayerKey:[self _hostSelectedLayerKeyIn:visibleLanes]];

  _openManageView = manageView;

  // The Animated dropdown is an option picker (pick which lanes animate), so it
  // dismisses on any outside click - a click elsewhere in the inspector closes
  // it, unlike the companion editors that stay open to switch content.
  _nextPopoverIsOptionType = YES;
  NSPopover *pop =
      [self _showPopoverWithContent:manageView
                           fromView:anchorView
                      preferredEdge:NSRectEdgeMinX
                            onClose:^{
                              __strong typeof(weak) s = weak;
                              if (!s)
                                return;
                              s->_openManageView = nil;
                              [NSNotificationCenter.defaultCenter
                                  postNotificationName:
                                      KKStaticValuesPopoverDidCloseNotification
                                                object:s];
                              if (s.onManagePopoverClosed)
                                s.onManagePopoverClosed();
                            }];
  _openManagePopover = pop;
  manageView.popover = pop;

  // Companion-panel signal (same as the constants/keypose popovers): a
  // multi-owner host (Canvas) shows its layer list beside the dropdown so you
  // can pick which owner's animated properties to manage. kind=manage => every
  // layer is selectable (you can animate any layer's params).
  KKPostStaticValuesPopoverDidOpen(pop, self, @"manage", NO, 0.0);

  if (self.onManagePopoverWillOpen) {
    NSString *targetLabel =
        self.managePopoverSpotlightLabel
            ?: [self _ownerScopedAvailableLanes].firstObject.key;
    __weak _KKManagePopoverView *weakManage = _openManageView;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong typeof(weak) strong = weak;
          __strong _KKManagePopoverView *mv = weakManage;
          if (!strong || !mv || !targetLabel)
            return;
          NSView *targetRow = [mv rowViewForLabel:targetLabel];
          if (targetRow && strong.onManagePopoverWillOpen)
            strong.onManagePopoverWillOpen(targetRow);
        });
  }
}

// PID of the app owning the topmost normal window under `screenPoint`
// (NSEvent.mouseLocation coords). 0 if none/unknown. Used so an outside-click
// in ANOTHER app (e.g. clicking Finder to drag in a file) doesn't dismiss the
// popover - only a click within the host app should.
static pid_t KKWindowOwnerPIDAtScreenPoint(NSPoint screenPoint) {
  NSScreen *primary = NSScreen.screens.firstObject;
  if (!primary)
    return 0;
  // NSEvent.mouseLocation is bottom-left origin; CGWindow bounds are top-left
  // (y down from the primary display top).
  CGPoint cgPt =
      CGPointMake(screenPoint.x, NSMaxY(primary.frame) - screenPoint.y);
  CFArrayRef list = CGWindowListCopyWindowInfo(
      kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
      kCGNullWindowID);
  if (!list)
    return 0;
  pid_t owner = 0;
  CFIndex count = CFArrayGetCount(list); // front-to-back
  for (CFIndex i = 0; i < count; i++) {
    NSDictionary *win =
        (__bridge NSDictionary *)CFArrayGetValueAtIndex(list, i);
    if ([win[(__bridge id)kCGWindowLayer] intValue] != 0)
      continue; // normal app windows only
    CGRect bounds = CGRectZero;
    if (!CGRectMakeWithDictionaryRepresentation(
            (__bridge CFDictionaryRef)win[(__bridge id)kCGWindowBounds],
            &bounds))
      continue;
    if (CGRectContainsPoint(bounds, cgPt)) {
      owner = (pid_t)[win[(__bridge id)kCGWindowOwnerPID] intValue];
      break;
    }
  }
  CFRelease(list);
  return owner;
}

// Opaque cover + centred spinner, parked over a popover's content area while
// its controller is swapped. AppKit implements a controller change on a SHOWN
// popover as a cross-fade from a SNAPSHOT of the outgoing content scaled into
// the incoming frame, so a curve editor visibly stretched into the keypose
// editor's shape before the real rows appeared. Covering BOTH sides means the
// snapshot is of the loader and the cross-fade tweens loader->loader: the user
// sees one steady panel resizing, never the stretch.
static NSView *KKMakePopoverSwapCover(NSRect frame) {
  NSView *cover = [[NSView alloc] initWithFrame:frame];
  cover.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  cover.wantsLayer = YES;
  // Fully opaque (the popover's own fill is half-alpha over the glass chrome) -
  // anything less lets the outgoing rows read through the loader.
  cover.layer.backgroundColor = [NSColor inspectorBackground].CGColor;
  NSProgressIndicator *spinner = [[NSProgressIndicator alloc] init];
  spinner.style = NSProgressIndicatorStyleSpinning;
  spinner.controlSize = NSControlSizeSmall;
  spinner.indeterminate = YES;
  spinner.displayedWhenStopped = NO;
  spinner.translatesAutoresizingMaskIntoConstraints = NO;
  [cover addSubview:spinner];
  [NSLayoutConstraint activateConstraints:@[
    [spinner.centerXAnchor constraintEqualToAnchor:cover.centerXAnchor],
    [spinner.centerYAnchor constraintEqualToAnchor:cover.centerYAnchor],
  ]];
  [spinner startAnimation:nil];
  return cover;
}

// One display tick: the shortest the cover can possibly be up for and still
// have hidden the frame the controller change is committed on. There is no
// longer a fixed floor beyond it - the reveal is driven by the incoming
// content's own layout settling (below), so a swap that resizes by a little
// costs a little and one that doesn't resize at all costs nothing.
static const CFTimeInterval kPopoverSwapMinCoverTime = 1.0 / 60.0;

// How long the reveal will wait for the wrapper to stop moving before giving
// up and showing whatever is there. Only reached if the popover is animating
// unusually slowly - the stall detector below normally settles first.
static const CFTimeInterval kPopoverSwapDeadline = 0.35;

// Consecutive identical bounds samples that count as "the resize is over" for a
// popover that never reaches the size we asked for (clamped to the screen edge,
// or born at the target and never animated at all). Three ticks ~ 50ms, short
// enough not to be felt and long enough not to fire on the frame before the
// window animation starts.
static const NSInteger kPopoverSwapStableTicks = 3;

// Drop `cover` once the popover has finished resizing to `target`. The size
// signal is the WRAPPER's own bounds: AppKit drives the content view's frame as
// the popover window animates, so when it reaches the size we asked for, the
// incoming content is laid out at its final width and safe to reveal.
//
// The wrapper does NOT always get there: a popover clamped to the screen edge
// settles short of the requested size, and one whose incoming content is the
// same size as the outgoing never moves at all. Waiting out a fixed deadline in
// those cases was the whole of the swap's felt latency (0.6s + a 0.12s fade
// against a fresh open's zero), so a stalled wrapper reveals as soon as its
// bounds stop changing.
static void KKRevealAfterPopoverResize(NSView *cover, NSView *wrapper,
                                       NSSize target) {
  __weak NSView *weakCover = cover;
  __weak NSView *weakWrapper = wrapper;
  CFTimeInterval start = CACurrentMediaTime();
  CFTimeInterval deadline = start + kPopoverSwapDeadline;
  __block NSSize lastSize = NSMakeSize(-1.0, -1.0);
  __block NSInteger stableTicks = 0;
  __block void (^tick)(void) = nil;
  tick = ^{
    NSView *cv = weakCover;
    NSView *wr = weakWrapper;
    if (!cv || !wr) {
      tick = nil;
      return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    NSSize size = wr.bounds.size;
    BOOL atTarget = fabs(size.width - target.width) < 0.5 &&
                    fabs(size.height - target.height) < 0.5;
    BOOL unchanged = fabs(size.width - lastSize.width) < 0.5 &&
                     fabs(size.height - lastSize.height) < 0.5;
    stableTicks = unchanged ? stableTicks + 1 : 0;
    lastSize = size;
    CFTimeInterval elapsed = now - start;
    BOOL settled = elapsed >= kPopoverSwapMinCoverTime &&
                   (atTarget || stableTicks >= kPopoverSwapStableTicks);
    if (!settled && now < deadline) {
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 60)),
          dispatch_get_main_queue(), ^{
            if (tick)
              tick();
          });
      return;
    }
    KKLogDebug(@"[Keypose] popover swap revealed after %.0fms (atTarget=%d "
               @"stable=%ld deadline=%d)",
               elapsed * 1000.0, (int)atTarget, (long)stableTicks,
               (int)(now >= deadline));
    [NSAnimationContext
        runAnimationGroup:^(NSAnimationContext *ctx) {
          ctx.duration = 0.08;
          cv.animator.alphaValue = 0.0;
        }
        completionHandler:^{
          [cv removeFromSuperview];
        }];
    tick = nil;
  };
  tick();
}

// Primary editor panels ------------------------------------------------------

- (BOOL)_editorPanelIsVisible {
  return _openEditorPanel && _openEditorPanel.isVisible;
}

- (void)_removeEditorKeyMonitors {
  if (_editorKeyMonitor) {
    [NSEvent removeMonitor:_editorKeyMonitor];
    _editorKeyMonitor = nil;
  }
  if (_editorGlobalKeyDownMonitor) {
    [NSEvent removeMonitor:_editorGlobalKeyDownMonitor];
    _editorGlobalKeyDownMonitor = nil;
  }
  if (_editorGlobalKeyUpMonitor) {
    [NSEvent removeMonitor:_editorGlobalKeyUpMonitor];
    _editorGlobalKeyUpMonitor = nil;
  }
  if (_editorGlobalShortcutCapture) {
    KKRemoveGlobalKeyCapture(_editorGlobalShortcutCapture);
    _editorGlobalShortcutCapture = nil;
  }
}

- (void)_closeEditorPanel {
  KKFloatingPanel *panel = _openEditorPanel;
  if (!panel)
    return;
  // Any temporary option picker belongs to this editing session; do not leave
  // it floating after the primary panel closes.
  if (_openContentPopover.isShown)
    [_openContentPopover close];
  [self _cancelCompositionPeek];
  [self _removeEditorKeyMonitors];

  void (^onClose)(void) = _openEditorOnClose;
  NSView *closing = _openEditorContentView;
  _openEditorOnClose = nil;
  _openEditorContentView = nil;
  _openEditorMiniViewer = nil;
  _openEditorPanel = nil;
  _openEditorSidebarKind = nil;
  _openEditorSidebarFraction = 0.0;
  _openEditorSidebarIsBoundary = NO;
  _editorHostPID = 0;
  [panel hidePanel];

  // Run mode cleanup after the panel is no longer interactive but before its
  // content is released. Companion observers detach their own child panels in
  // this callback, so no orphaned window remains above the hidden editor.
  if (onClose)
    onClose();
  dispatch_async(dispatch_get_main_queue(), ^{
    if ([closing respondsToSelector:@selector(releaseMiniViewer)])
      [(id)closing releaseMiniViewer];
  });
}

- (void)_installEditorKeyMonitors {
  [self _removeEditorKeyMonitors];
  __weak typeof(self) weak = self;
  _editorKeyMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp
                                   handler:^NSEvent *(NSEvent *event) {
                                     __strong typeof(weak) s = weak;
                                     if (!s || ![s _editorPanelIsVisible])
                                       return event;
                                     NSString *ch =
                                         event.charactersIgnoringModifiers
                                             .lowercaseString;
                                     if (event.type == NSEventTypeKeyUp) {
                                       if (s->_compositionPeekKeyHeld &&
                                           [ch isEqualToString:@"p"]) {
                                         [s _setCompositionPeekHeld:NO
                                                           keyboard:YES];
                                         return nil;
                                       }
                                       if ([ch isEqualToString:@"l"])
                                         return nil;
                                       if (s.editorRightPanelToggleAvailable &&
                                           [ch isEqualToString:@"g"])
                                         return nil;
                                       if (s->_openEditorIsStaticFamily &&
                                           [ch isEqualToString:@"v"])
                                         return nil;
                                       return event;
                                     }

                                     // A temporary option/structural popover
                                     // above the persistent editor owns Esc and
                                     // its own key handling until it closes.
                                     if (s->_openContentPopover.isShown)
                                       return event;

                                     NSWindow *panel = s->_openEditorPanel;
                                     BOOL fieldEditing =
                                         [panel.firstResponder
                                             isKindOfClass:[NSText class]] ||
                                         [NSApp.keyWindow.firstResponder
                                             isKindOfClass:[NSText class]];
                                     NSEventModifierFlags mods =
                                         event.modifierFlags &
                                         NSEventModifierFlagDeviceIndependentFlagsMask;
                                     BOOL cmd =
                                         (mods & NSEventModifierFlagCommand) !=
                                         0;
                                     BOOL shift =
                                         (mods & NSEventModifierFlagShift) != 0;

                                     // NSPopover key events were forwarded by
                                     // ViewBridge through the inspector root,
                                     // where KKRemoteWindowKeyHandlerView sent
                                     // Space / Cmd-Z to FCP. A standalone panel
                                     // owns its events, so bridge those
                                     // commands explicitly. Focused text/code
                                     // editors keep their normal typing and
                                     // local undo.
                                     KKRemoteWindowKeyHandlerView *hostKeys =
                                         nil;
                                     Class hostKeyClass =
                                         [KKRemoteWindowKeyHandlerView class];
                                     for (NSView *v = s; v; v = v.superview)
                                       if ([v isKindOfClass:hostKeyClass]) {
                                         hostKeys =
                                             (KKRemoteWindowKeyHandlerView *)v;
                                         break;
                                       }
                                     if (!fieldEditing &&
                                         [event.charactersIgnoringModifiers
                                             isEqualToString:@" "] &&
                                         !cmd && hostKeys.onTogglePlayback) {
                                       hostKeys.onTogglePlayback();
                                       return nil;
                                     }
                                     if (!fieldEditing && cmd &&
                                         [ch isEqualToString:@"z"]) {
                                       void (^command)(void) =
                                           shift ? hostKeys.onRedo
                                                 : hostKeys.onUndo;
                                       if (command) {
                                         command();
                                         return nil;
                                       }
                                     }
                                     if ([ch isEqualToString:@"p"] &&
                                         !(mods &
                                           (NSEventModifierFlagCommand |
                                            NSEventModifierFlagControl |
                                            NSEventModifierFlagOption |
                                            NSEventModifierFlagShift |
                                            NSEventModifierFlagFunction)) &&
                                         !fieldEditing) {
                                       if (!event.isARepeat)
                                         [s _setCompositionPeekHeld:YES
                                                           keyboard:YES];
                                       return nil;
                                     }
                                     if ([ch isEqualToString:@"l"] &&
                                         !(mods &
                                           (NSEventModifierFlagCommand |
                                            NSEventModifierFlagControl |
                                            NSEventModifierFlagOption |
                                            NSEventModifierFlagShift |
                                            NSEventModifierFlagFunction)) &&
                                         !fieldEditing) {
                                       if (!event.isARepeat)
                                         [s _setEditorSidebarVisible:
                                                 !s.editorSidebarVisible];
                                       return nil;
                                     }
                                     if (s.editorRightPanelToggleAvailable &&
                                         [ch isEqualToString:@"g"] &&
                                         !(mods &
                                           (NSEventModifierFlagCommand |
                                            NSEventModifierFlagControl |
                                            NSEventModifierFlagOption |
                                            NSEventModifierFlagShift |
                                            NSEventModifierFlagFunction)) &&
                                         !fieldEditing) {
                                       if (!event.isARepeat)
                                         [s _setEditorRightPanelVisible:
                                                 !s.editorRightPanelVisible];
                                       return nil;
                                     }
                                     if (s->_openEditorIsStaticFamily &&
                                         [ch isEqualToString:@"v"] &&
                                         !(mods &
                                           (NSEventModifierFlagCommand |
                                            NSEventModifierFlagControl |
                                            NSEventModifierFlagOption |
                                            NSEventModifierFlagShift |
                                            NSEventModifierFlagFunction)) &&
                                         !fieldEditing) {
                                       if (!event.isARepeat)
                                         [s _setEditorCompactMode:
                                                 !s->_editorCompactMode];
                                       return nil;
                                     }
                                     if (event.keyCode == 53) { // Escape
                                       if (fieldEditing)
                                         return event;
                                       [s _closeEditorPanel];
                                       return nil;
                                     }
                                     if (!s->_openStaticIsBoundary ||
                                         fieldEditing)
                                       return event;
                                     if (event.keyCode != 123 &&
                                         event.keyCode != 124)
                                       return event;
                                     [s _navigateBoundaryPopoverDirection:
                                             (event.keyCode == 123 ? -1 : 1)];
                                     return nil;
                                   }];

  // Focus can cross back into FCP while P is down. The matching release then
  // arrives globally; always restore the parked editor panel.
  _editorGlobalKeyDownMonitor = [NSEvent
      addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                    handler:^(NSEvent *event) {
                                      __strong typeof(weak) s = weak;
                                      if (!s || event.keyCode != 53 ||
                                          ![s _editorPanelIsVisible] ||
                                          s->_openContentPopover.isShown)
                                        return;
                                      pid_t front = NSWorkspace.sharedWorkspace
                                                        .frontmostApplication
                                                        .processIdentifier;
                                      if (s->_editorHostPID == 0 ||
                                          front == s->_editorHostPID)
                                        [s _closeEditorPanel];
                                    }];
  _editorGlobalKeyUpMonitor = [NSEvent
      addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyUp
                                    handler:^(NSEvent *event) {
                                      __strong typeof(weak) s = weak;
                                      if (s && s->_compositionPeekKeyHeld &&
                                          [event.charactersIgnoringModifiers
                                                  .lowercaseString
                                              isEqualToString:@"p"])
                                        [s _setCompositionPeekHeld:NO
                                                          keyboard:YES];
                                    }];
  // Once focus returns to Final Cut, a normal global monitor can only observe
  // P and Final Cut would still act on it. The consuming capture preserves the
  // same ownership the local monitor has while our panel is key: P belongs to
  // the visible editor, including both halves of its hold gesture.
  _editorGlobalShortcutCapture =
      KKInstallGlobalKeyCapture(^BOOL(NSEvent *event) {
        __strong typeof(weak) s = weak;
        if (!s || ![s _editorPanelIsVisible] || s->_openContentPopover.isShown)
          return NO;
        pid_t front =
            NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        if (s->_editorHostPID == 0 || front != s->_editorHostPID)
          return NO;
        NSString *ch = event.charactersIgnoringModifiers.lowercaseString;
        BOOL peekKey = [ch isEqualToString:@"p"];
        BOOL sidebarKey = [ch isEqualToString:@"l"];
        BOOL rightPanelKey =
            s.editorRightPanelToggleAvailable && [ch isEqualToString:@"g"];
        BOOL compactKey =
            s->_openEditorIsStaticFamily && [ch isEqualToString:@"v"];
        if (!peekKey && !sidebarKey && !rightPanelKey && !compactKey)
          return NO;
        if (event.type == NSEventTypeKeyUp) {
          if (sidebarKey || rightPanelKey || compactKey)
            return YES;
          if (!s->_compositionPeekKeyHeld)
            return NO;
          [s _setCompositionPeekHeld:NO keyboard:YES];
          return YES;
        }
        NSEventModifierFlags mods =
            event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        if (mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl |
                    NSEventModifierFlagOption | NSEventModifierFlagShift |
                    NSEventModifierFlagFunction))
          return NO;
        BOOL fieldEditing =
            [s->_openEditorPanel.firstResponder isKindOfClass:[NSText class]] ||
            [NSApp.keyWindow.firstResponder isKindOfClass:[NSText class]];
        if (fieldEditing)
          return NO;
        if (!event.isARepeat) {
          if (sidebarKey)
            [s _setEditorSidebarVisible:!s.editorSidebarVisible];
          else if (rightPanelKey)
            [s _setEditorRightPanelVisible:!s.editorRightPanelVisible];
          else if (compactKey)
            [s _setEditorCompactMode:!s->_editorCompactMode];
          else
            [s _setCompositionPeekHeld:YES keyboard:YES];
        }
        return YES;
      });
}

- (void)_setOpenEditorContentSize:(NSSize)size {
  if (!_openEditorPanel || size.width <= 0.0 || size.height <= 0.0)
    return;
  if (_openEditorIsStaticFamily && _openEditorPanel.userResizable &&
      [_openEditorContentView
          isKindOfClass:[_KKStaticValuesPopoverView class]]) {
    [(_KKStaticValuesPopoverView *)_openEditorContentView
        applyHostedContentSize:_openEditorPanel.frame.size];
    return;
  }
  [_openEditorPanel setContentSizeKeepingTopEdge:size];
}

- (KKFloatingPanel *)_showEditorPanelWithContent:(NSView *)content
                                        fromView:(NSView *)anchor
                                    staticFamily:(BOOL)staticFamily
                                         onClose:(void (^)(void))onClose {
  if (!content || !anchor.window)
    return nil;

  // A newly-opened primary editor replaces any temporary/structural popover.
  // Close synchronously so the outgoing popover's observer sees its own live
  // cleanup state before the panel session begins.
  if (_openContentPopover.isShown)
    [_openContentPopover close];
  if ([self _editorPanelIsVisible])
    [self _closeEditorPanel];

  NSSize size = content.bounds.size;
  if (size.width <= 0.0 || size.height <= 0.0)
    size = content.fittingSize;
  if (size.width <= 0.0 || size.height <= 0.0)
    return nil;

  KKFloatingPanel *panel =
      staticFamily ? _staticEditorPanel : _segmentEditorPanel;
  if (!panel) {
    NSString *positionKey = staticFamily
                                ? @"timeline.staticEditorPanel.origin"
                                : @"timeline.segmentEditorPanel.origin";
    panel = [[KKFloatingPanel alloc] initWithContentSize:size
                                             positionKey:positionKey];
    panel.allowsKeyWindow = YES;
    panel.keepsEntireFrameVisible = YES;
    panel.becomesKeyOnlyIfNeeded = NO;
    if (staticFamily)
      _staticEditorPanel = panel;
    else
      _segmentEditorPanel = panel;
  }
  panel.userMovable = YES;
  panel.userResizable = staticFamily;
  panel.onUserResized = nil;
  panel.dragHandleView = nil;
  [panel makeFirstResponder:nil];
  [panel setContentSizeKeepingTopEdge:size];
  [panel setPanelContentView:content];
  if (staticFamily &&
      [content isKindOfClass:[_KKStaticValuesPopoverView class]]) {
    _KKStaticValuesPopoverView *staticView =
        (_KKStaticValuesPopoverView *)content;
    panel.minSize = [staticView minimumHostedContentSize];
    panel.dragHandleView = staticView.panelDragHandleView;
    __weak _KKStaticValuesPopoverView *weakStatic = staticView;
    panel.onUserResized = ^(NSSize resized) {
      [weakStatic applyHostedContentSize:resized];
    };
  }
  panel.initialFirstResponder = panel.contentView;
  panel.appearance = anchor.window.appearance;

  _openEditorPanel = panel;
  _editorHostPID =
      NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
  _openEditorIsStaticFamily = staticFamily;
  _openEditorContentView = content;
  _openEditorMiniViewer = KKFindMiniViewer(content);
  _openEditorOnClose = [onClose copy];
  KKFindMiniViewer(content).grabsKeyFocusOnClick =
      self.miniGrabsKeyFocusOnClick;
  _openEditorMiniViewer.livePlaybackActive = _openPopoverLivePlaying;

  NSRect card = [anchor.window
      convertRectToScreen:[anchor convertRect:anchor.bounds toView:nil]];
  [panel showBesideCard:card ofWindow:anchor.window];
  if (staticFamily &&
      [content isKindOfClass:[_KKStaticValuesPopoverView class]])
    [(_KKStaticValuesPopoverView *)content
        applyHostedContentSize:panel.frame.size];
  // Match NSPopover: the editor becomes this XPC process's key window so its
  // bare-key shortcuts and field editor work immediately. The panel's
  // Nonactivating style means Final Cut itself remains the active app.
  [panel makeKeyWindow];
  [self _installEditorKeyMonitors];
  return panel;
}

- (NSPopover *)_showPopoverWithContent:(NSView *)content
                              fromView:(NSView *)anchor
                         preferredEdge:(NSRectEdge)preferredEdge
                               onClose:(void (^)(void))onClose {
  // Consume the one-shot option-type marker: an option picker (OSC / filter /
  // param-order / motion blur) dismisses on any outside click; a companion
  // editor keeps open on in-inspector clicks (mode switches). Captured locally
  // so the dismiss monitor below reads THIS popover's kind, not a later one's.
  BOOL optionType = _nextPopoverIsOptionType;
  _nextPopoverIsOptionType = NO;

  // A structural companion (Animated, layer-scoped filter/OSC, etc.) posts the
  // same open/close lifecycle used by template and colour side panels, so it
  // replaces the primary editor just as it did in the one-popover model. A
  // true option picker is temporary and can sit above the persistent editor;
  // closing it must not tear down the editor session beneath it.
  if (!optionType && [self _editorPanelIsVisible])
    [self _closeEditorPanel];

  // Capture the size the content WANTS before it is pinned into the wrapper.
  // Once pinned, `content.bounds` tracks the wrapper - which AppKit lays out to
  // the popover's CURRENT (outgoing) content size the moment the new controller
  // is installed. Reading bounds after that point fed the OLD width straight
  // back into -setContentSize:, so a swap between two differently-sized editors
  // settled at the wrong width. `fittingSize` covers a content view that was
  // handed to us with no frame at all.
  NSSize desiredContentSize = content.bounds.size;
  if (NSIsEmptyRect(content.bounds))
    desiredContentSize = content.fittingSize;

  _KKLVPopoverContentView *wrapper = [[_KKLVPopoverContentView alloc] init];
  wrapper.frame = content.bounds;
  content.translatesAutoresizingMaskIntoConstraints = NO;
  [wrapper addSubview:content];
  [NSLayoutConstraint activateConstraints:@[
    [content.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor],
    [content.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
    [content.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
    [content.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
  ]];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = wrapper;

  // Swap content on the LIVE window ONLY when the new popover targets the SAME
  // anchor+edge (same family / on-screen position, e.g.
  // keypose<->gap<->constants beside the inspector). A DIFFERENT anchor (a cog
  // popover at its button, or the reverse) needs a real close+reopen to
  // re-position - the buttons inside fire on mouseDown so they survive that
  // reopen.
  BOOL isShown = _openContentPopover.isShown;
  BOOL swapInPlace = isShown && anchor == _openPopoverAnchorView &&
                     preferredEdge == _openPopoverPreferredEdge;
  NSView *outgoingContent = _openContentView;
  void (^outgoingOnClose)(void) = _openContentOnClose;

  if (isShown && !swapInPlace) {
    // Cross-anchor reopen: close the old popover first so its WillClose runs
    // the OUTGOING cleanup (the closeObs reads the still-current
    // _openContentOnClose / _openContentView) and tears down the old monitors,
    // BEFORE we overwrite the live state and re-show at the new anchor.
    [_openContentPopover close];
  }

  // New live state the ONE persistent monitor set reads.
  _openContentView = content;
  _openContentMiniViewer = KKFindMiniViewer(content);
  _openPopoverIsOptionType = optionType;
  _openPopoverShownAt = CACurrentMediaTime();
  _openContentOnClose = [onClose copy];
  _openPopoverPreferredEdge = preferredEdge;
  _openPopoverAnchorView = anchor;
  KKFindMiniViewer(content).grabsKeyFocusOnClick =
      self.miniGrabsKeyFocusOnClick;
  // Seed the play state. -setOpenPopoverLivePlaying: only fires on a FLIP, so a
  // popover opened (or re-anchored, which rebuilds its content) mid-playback
  // would otherwise sit at NO for the whole run and paint every handle over the
  // moving preview.
  _openContentMiniViewer.livePlaybackActive = _openPopoverLivePlaying;

  if (swapInPlace) {
    // Never close+reopen for a same-anchor switch - the swap keeps the window
    // (and its event forwarding) alive. Run the OUTGOING content's cleanup
    // (onClose + mini-viewer release) here since its WillClose won't fire.
    if (outgoingOnClose)
      outgoingOnClose();
    // The loader exists ONLY to hide the stretch: AppKit implements a
    // controller change on a shown popover as a cross-fade from a snapshot of
    // the outgoing content scaled into the incoming frame, and the scaling is
    // what reads as a smear. Same size in and out = no scaling = nothing to
    // hide, so the swap runs bare and costs a plain cross-fade - which is what
    // a fresh open looks like anyway. This is the common case for keypose <->
    // constants and for curve <-> keypose at equal row counts, and covering it
    // was pure latency.
    NSSize outgoing = _openContentPopover.contentSize;
    BOOL resizes = desiredContentSize.width > 0.0 &&
                   desiredContentSize.height > 0.0 &&
                   (fabs(outgoing.width - desiredContentSize.width) >= 0.5 ||
                    fabs(outgoing.height - desiredContentSize.height) >= 0.5);
    // Hide both sides of the swap behind a loader BEFORE the controller change
    // so the snapshot AppKit tweens is of the cover, not of the outgoing rows.
    // The outgoing cover goes away with its view; the incoming one is dropped
    // once the popover has finished resizing (see KKRevealAfterPopoverResize).
    NSView *incomingCover = nil;
    if (resizes) {
      NSView *outgoingRoot = _openContentPopover.contentViewController.view;
      if (outgoingRoot) {
        NSView *outgoingCover = KKMakePopoverSwapCover(outgoingRoot.bounds);
        [outgoingRoot addSubview:outgoingCover
                      positioned:NSWindowAbove
                      relativeTo:nil];
        [outgoingRoot displayIfNeeded];
      }
      incomingCover = KKMakePopoverSwapCover(wrapper.bounds);
      [wrapper addSubview:incomingCover
               positioned:NSWindowAbove
               relativeTo:nil];
    }
    KKLogDebug(@"[Keypose] popover swap %.0fx%.0f -> %.0fx%.0f (%@)",
               outgoing.width, outgoing.height, desiredContentSize.width,
               desiredContentSize.height, resizes ? @"covered" : @"bare");
    // Controller FIRST, then contentSize, then force layout - setting size
    // first leaves the popover grown to the new size while the OLD content is
    // still installed, so a taller editor (curve -> modulation, gap -> keypose)
    // never repaints the exposed area.
    _openContentPopover.contentViewController = vc;
    if (desiredContentSize.width > 0.0 && desiredContentSize.height > 0.0)
      _openContentPopover.contentSize = desiredContentSize;
    [wrapper layoutSubtreeIfNeeded];
    if (incomingCover)
      KKRevealAfterPopoverResize(incomingCover, wrapper, desiredContentSize);
    __weak NSView *weakOutgoing = outgoingContent;
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong NSView *oc = weakOutgoing;
      if ([oc respondsToSelector:@selector(releaseMiniViewer)])
        [(id)oc releaseMiniViewer];
    });
    return _openContentPopover;
  }

  // First open (or after a real dismiss): create/show + install the persistent
  // monitors. Reuse one popover instance (and its remote-hosted backing window)
  // across opens - see _openContentPopover's declaration. ApplicationDefined,
  // not Transient: Transient closes on ANY event to a different window, but
  // ViewBridge-routed FCP clicks target the inspector window - we replicate
  // outside-click close with the local + global mouseDown monitors below.
  NSPopover *popover = _openContentPopover;
  if (!popover) {
    popover = [[NSPopover alloc] init];
    popover.behavior = NSPopoverBehaviorApplicationDefined;
  }
  popover.contentViewController = vc;
  if (desiredContentSize.width > 0.0 && desiredContentSize.height > 0.0)
    popover.contentSize = desiredContentSize;
  [popover showRelativeToRect:anchor.bounds
                       ofView:anchor
                preferredEdge:preferredEdge];

  NSWindow *popoverWindow = popover.contentViewController.view.window;
  // Don't let the popover steal app focus from the host (FCP): without this the
  // popover's window activates our ViewBridge process when it (or a click in
  // it) becomes key, deactivating FCP so its cursors / Cmd-Z / shortcuts stop
  // until the user clicks back. The companion layer-list panel avoids this by
  // being a NONACTIVATING panel; NSPopover's backing window is an NSPanel
  // subclass, so give it the same treatment - become key (for field editing /
  // bare keys) WITHOUT activating the process.
  if ([popoverWindow isKindOfClass:[NSPanel class]]) {
    NSPanel *popoverPanel = (NSPanel *)popoverWindow;
    popoverPanel.styleMask |= NSWindowStyleMaskNonactivatingPanel;
    popoverPanel.becomesKeyOnlyIfNeeded = NO;
  }
  // The event monitors below must NOT strong-capture the popover window:
  // NSEvent retains a monitor's block until -removeMonitor:, and during a guide
  // the popover can be torn down without NSPopoverWillCloseNotification firing
  // (so -removeMonitors never runs). A strong capture then pins the popover
  // window, its content view, and the mini-viewer (an MTKView) - leaking that
  // view's multi-MB CAMetalLayer drawables every guide run. Weak so a stranded
  // monitor can't keep the window (and the whole mini-viewer) alive.
  __weak NSWindow *weakPopoverWindow = popoverWindow;
  // Host app (FCP) is frontmost when the popover opens. Captured so an
  // outside-click in another app doesn't dismiss it.
  pid_t hostPID =
      NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
  __weak NSPopover *weakPopover = popover;
  __block id localMon = nil;
  __block id globalMon = nil;
  __block id magnifyLocalMon = nil;
  __block id magnifyGlobalMon = nil;
  __block id mouseLocalMon = nil;
  __block id mouseGlobalMon = nil;
  __block id keyMon = nil;
  __block id keyGlobalUpMon = nil;
  __weak typeof(self) navWeakSelf = self;

  void (^removeMonitors)(void) = ^{
    if (localMon) {
      [NSEvent removeMonitor:localMon];
      localMon = nil;
    }
    if (globalMon) {
      [NSEvent removeMonitor:globalMon];
      globalMon = nil;
    }
    if (magnifyLocalMon) {
      [NSEvent removeMonitor:magnifyLocalMon];
      magnifyLocalMon = nil;
    }
    if (magnifyGlobalMon) {
      [NSEvent removeMonitor:magnifyGlobalMon];
      magnifyGlobalMon = nil;
    }
    if (mouseLocalMon) {
      [NSEvent removeMonitor:mouseLocalMon];
      mouseLocalMon = nil;
    }
    if (mouseGlobalMon) {
      [NSEvent removeMonitor:mouseGlobalMon];
      mouseGlobalMon = nil;
    }
    if (keyMon) {
      [NSEvent removeMonitor:keyMon];
      keyMon = nil;
    }
    if (keyGlobalUpMon) {
      [NSEvent removeMonitor:keyGlobalUpMon];
      keyGlobalUpMon = nil;
    }
  };

  __block id closeObs = [NSNotificationCenter.defaultCenter
      addObserverForName:NSPopoverWillCloseNotification
                  object:popover
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *n) {
                removeMonitors();
                // Fire the CURRENT content's onClose (a swap already fired the
                // outgoing one), then clear the live state - a real close ends
                // the session; the next show re-installs monitors.
                __strong typeof(navWeakSelf) s = navWeakSelf;
                void (^oc)(void) = s ? s->_openContentOnClose : nil;
                NSView *closing = s ? s->_openContentView : nil;
                if (s) {
                  [s _cancelCompositionPeek];
                  s->_openContentOnClose = nil;
                  s->_openContentView = nil;
                  s->_openContentMiniViewer = nil;
                }
                if (oc)
                  oc();
                // Free the closing content's mini-viewer GPU memory promptly.
                // The backing window is NOT destroyed: _openContentPopover is
                // reused across opens (its remote-hosted window can't be freed
                // until inspector teardown anyway - see its declaration), so
                // reusing one window bounds the CA layer-hosting IOSurface leak
                // instead of creating a fresh stranded window per open. Defer
                // one runloop so the popover's own close settles first.
                dispatch_async(dispatch_get_main_queue(), ^{
                  if ([closing respondsToSelector:@selector(releaseMiniViewer)])
                    [(id)closing releaseMiniViewer];
                });
                [NSNotificationCenter.defaultCenter removeObserver:closeObs];
              }];

  // The content view can transiently veto dismissal (e.g. while a colour
  // swatch's shared NSColorPanel is open - a separate window whose clicks would
  // otherwise count as "outside" and close the popover mid-edit).
  BOOL (^contentSuppressesDismiss)(void) = ^BOOL {
    __strong typeof(navWeakSelf) s = navWeakSelf;
    NSView *c = s ? s->_openContentView : nil;
    return [c respondsToSelector:@selector(suppressesPopoverDismiss)] &&
           [(id)c suppressesPopoverDismiss];
  };

  // Scroll over the mini viewer = zoom/pan (events arrive global in
  // ViewBridge XPC - see [[project_viewbridge_global_sendEvent]]); scroll
  // elsewhere keeps the old outside-dismiss behavior.
  // Scroll/magnify over the canvas is handled by the responder chain
  // (KKMiniViewerView inside an NSScrollView - the proven mechanism). These
  // monitors only keep the outside-scroll-dismiss behavior, and must NOT
  // swallow or close when the pointer is over the canvas.
  // A scroll only dismisses when it lands within the HOST app (FCP). A scroll
  // while another app is focused reaches the global monitor too; without this
  // guard any such scroll closed the popover.
  BOOL (^scrollInHostApp)(void) = ^BOOL {
    if (hostPID == 0)
      return YES; // couldn't resolve host - keep the old close-on-scroll
    return KKWindowOwnerPIDAtScreenPoint(NSEvent.mouseLocation) == hostPID;
  };
  // A scroll only dismisses when it is a FRESH gesture the user made with the
  // popover already up. Two cases are not:
  //  - momentum (inertia) events, which keep arriving up to ~1.5s after the
  //    fingers lift: scrolling the inspector to reach a row and clicking it
  //    immediately meant the tail of that scroll dismissed the popover on its
  //    first open.
  //  - anything inside the same warm-up window the mouseDown monitor uses, for
  //    the pre-momentum tail of the same gesture.
  // Both read as "intermittent dismiss right after opening".
  BOOL (^scrollIsFreshGesture)(NSEvent *) = ^BOOL(NSEvent *e) {
    if (e.momentumPhase != NSEventPhaseNone)
      return NO;
    __strong typeof(navWeakSelf) s = navWeakSelf;
    if (s && CACurrentMediaTime() - s->_openPopoverShownAt < 0.2)
      return NO;
    return YES;
  };
  localMon = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                   handler:^NSEvent *(NSEvent *e) {
                                     __strong typeof(navWeakSelf) s =
                                         navWeakSelf;
                                     KKMiniViewerView *canvas =
                                         s ? s->_openContentMiniViewer : nil;
                                     if (canvas && [canvas pointerOverCanvas])
                                       return e; // let the responder handle it
                                     // Scroll inside a companion side panel
                                     // scrolls it, doesn't dismiss.
                                     if (KKPopoverPointInKeepAliveWindow(
                                             NSEvent.mouseLocation))
                                       return e;
                                     if (contentSuppressesDismiss())
                                       return e;
                                     if (!scrollIsFreshGesture(e))
                                       return e;
                                     if (!scrollInHostApp())
                                       return e;
                                     if (e.window != weakPopoverWindow)
                                       [weakPopover close];
                                     return e;
                                   }];

  globalMon = [NSEvent
      addGlobalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                    handler:^(NSEvent *e) {
                                      __strong typeof(navWeakSelf) s =
                                          navWeakSelf;
                                      KKMiniViewerView *canvas =
                                          s ? s->_openContentMiniViewer : nil;
                                      if (canvas && [canvas pointerOverCanvas])
                                        return;
                                      if (KKPopoverPointInKeepAliveWindow(
                                              NSEvent.mouseLocation))
                                        return;
                                      if (contentSuppressesDismiss())
                                        return;
                                      if (!scrollIsFreshGesture(e))
                                        return;
                                      if (!scrollInHostApp())
                                        return;
                                      [weakPopover close];
                                    }];

  // Replaces Transient's built-in outside-click close. Without the joyride
  // overlay, clicks in the XPC custom view are local events; clicks elsewhere
  // in FCP are global events. Both monitors are needed to cover all cases.
  // Joyride forwarding panels sit above the popover during a guide - a Next
  // click in that panel would dismiss the popover before the guide can hand
  // off to the next step, so treat any click landing inside one as inside-
  // the-popover. Identified by class name to avoid coupling to a private
  // joyride header.
  BOOL (^pointInJoyridePanel)(NSPoint) = ^BOOL(NSPoint p) {
    for (NSWindow *w in NSApp.windows) {
      if (!w.isVisible)
        continue;
      if (![NSStringFromClass(w.class)
              isEqualToString:@"_KKJoyrideForwardingPanel"])
        continue;
      if (NSPointInRect(p, w.frame))
        return YES;
    }
    return NO;
  };
  void (^closeIfOutsidePopover)(void) = ^{
    if (contentSuppressesDismiss())
      return;
    NSWindow *pw = [weakPopover contentViewController].view.window;
    NSPoint p = NSEvent.mouseLocation;
    if (pw && NSPointInRect(p, pw.frame))
      return;
    if (pointInJoyridePanel(p))
      return;
    // A plugin's companion side panel (e.g. a layer list shown beside the
    // popover) registers itself as keep-alive so clicking it doesn't dismiss.
    if (KKPopoverPointInKeepAliveWindow(p))
      return;
    // Only an outside click within the HOST app dismisses. A click in another
    // app (e.g. Finder, to drag a file into the panel) leaves it open. Fall
    // back to the old close-on-outside if we couldn't resolve the host PID.
    if (hostPID != 0) {
      pid_t owner = KKWindowOwnerPIDAtScreenPoint(p);
      if (owner != hostPID)
        return;
    }
    __strong typeof(self) s = navWeakSelf;
    if (!s)
      return;
    // A click on the popover's OWN anchor (e.g. the cog toggle button) is that
    // button's job to handle - it toggles the popover shut on mouseUp. Don't
    // also close here on mouseDown, or the button's action re-opens it right
    // after (the popover never closes from its own button). Applies to every
    // popover; option pickers just have no other in-inspector keep-open case.
    NSView *anchorV = s->_openPopoverAnchorView;
    if (anchorV && anchorV.window) {
      NSRect aScreen = [anchorV.window
          convertRectToScreen:[anchorV convertRect:anchorV.bounds toView:nil]];
      if (NSPointInRect(p, aScreen))
        return;
    }
    // COMPANION editors (keypose / constants / curve / modulation) treat a
    // click anywhere in the inspector's OWN UI as a mode switch, not a dismiss:
    // clicking another keypose/gap/the constants button switches them IN PLACE
    // (reconfigure / same-anchor swap), so closing here would fight that.
    // OPTION pickers (OSC / filter / param-order / motion blur / presets /
    // animated) instead dismiss on ANY click off them - including elsewhere in
    // the inspector - because they are separate; opening a companion from that
    // click re-shows at the correct anchor and its buttons fire on mouseDown so
    // they survive the reopen. Read the kind live (the popover swaps content in
    // place, so its current kind is on the ivar).
    if (!s->_openPopoverIsOptionType) {
      BOOL clickInInspector = NO;
      NSView *cv = s.window.contentView;
      if (s.window && cv) {
        NSRect inspScreen = [s.window
            convertRectToScreen:[cv convertRect:cv.bounds toView:nil]];
        clickInInspector = NSPointInRect(p, inspScreen);
      }
      if (clickInInspector)
        return;
    }
    [weakPopover close];
  };
  mouseLocalMon = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                   handler:^NSEvent *(NSEvent *e) {
                                     // ViewBridge delivers the real click as a
                                     // local event ~50-100ms after the joyride
                                     // global monitor fires; ignore events in
                                     // that window to avoid false-closing the
                                     // popover. Read the live show-time
                                     // (updated on every swap) so a swap gets
                                     // its own warm-up window.
                                     __strong typeof(navWeakSelf) sw =
                                         navWeakSelf;
                                     if (sw && CACurrentMediaTime() -
                                                       sw->_openPopoverShownAt <
                                                   0.2)
                                       return e;
                                     if (e.window != weakPopoverWindow)
                                       closeIfOutsidePopover();
                                     return e;
                                   }];
  mouseGlobalMon =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                             handler:^(NSEvent *e) {
                                               closeIfOutsidePopover();
                                             }];

  // Key handling while a content popover is open: P momentarily reveals the
  // composition behind companion editors, Esc closes, and (boundary popover
  // only) left/right arrows step to the prev/next keypose. All starts are
  // suppressed while a value field or code editor is active; a release is
  // always honoured if its matching hold began here.
  keyMon = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp
                                   handler:^NSEvent *(NSEvent *e) {
                                     __strong typeof(navWeakSelf) s =
                                         navWeakSelf;
                                     if (!s)
                                       return e;
                                     NSString *ch =
                                         e.charactersIgnoringModifiers
                                             .lowercaseString;
                                     if (e.type == NSEventTypeKeyUp) {
                                       if (s->_compositionPeekKeyHeld &&
                                           [ch isEqualToString:@"p"]) {
                                         [s _setCompositionPeekHeld:NO
                                                           keyboard:YES];
                                         return nil;
                                       }
                                       return e;
                                     }
                                     if (!s->_openContentPopover.isShown)
                                       return e;
                                     unsigned short kc = e.keyCode;
                                     // ViewBridge routes the popover's key
                                     // events through the host window, so
                                     // e.window never equals the popover window
                                     // - gate on the popover window's first
                                     // responder instead. An NSText (the field
                                     // editor, incl. the code editor's text
                                     // view) means a value field is being
                                     // edited. Also check the key window for a
                                     // field editor (e.g. renaming a layer in
                                     // the companion panel, a separate window).
                                     BOOL fieldEditing =
                                         [weakPopoverWindow.firstResponder
                                             isKindOfClass:[NSText class]] ||
                                         [NSApp.keyWindow.firstResponder
                                             isKindOfClass:[NSText class]];
                                     // Bare P = press-and-hold composition
                                     // peek. It is intentionally limited to
                                     // the four companion editors; option
                                     // pickers still pass P through to FCP.
                                     NSEventModifierFlags mods =
                                         e.modifierFlags &
                                         NSEventModifierFlagDeviceIndependentFlagsMask;
                                     if (!s->_openPopoverIsOptionType &&
                                         [ch isEqualToString:@"p"] &&
                                         !(mods &
                                           (NSEventModifierFlagCommand |
                                            NSEventModifierFlagControl |
                                            NSEventModifierFlagOption |
                                            NSEventModifierFlagShift |
                                            NSEventModifierFlagFunction)) &&
                                         !fieldEditing) {
                                       if (!e.isARepeat)
                                         [s _setCompositionPeekHeld:YES
                                                           keyboard:YES];
                                       return nil;
                                     }
                                     // Esc closes the popover - unless a value
                                     // field / code editor is focused, where it
                                     // should cancel that edit instead.
                                     if (kc == 53) { // Escape
                                       if (fieldEditing)
                                         return e;
                                       [s->_openContentPopover close];
                                       return nil; // consume
                                     }
                                     // Left/right step to the prev/next keypose
                                     // (boundary popover only), when not
                                     // editing a field, so arrows still move
                                     // the text cursor inside a value field.
                                     if (!s->_openStaticIsBoundary)
                                       return e;
                                     if (kc != 123 && kc != 124)
                                       return e; // 123 = left, 124 = right
                                     if (fieldEditing)
                                       return e;
                                     [s _navigateBoundaryPopoverDirection:
                                             (kc == 123 ? -1 : 1)];
                                     return nil; // consume
                                   }];

  // If focus leaves this process while P is down, its key-up is global rather
  // than local. Restore the editor even though a global monitor cannot consume
  // the event in the destination app.
  keyGlobalUpMon = [NSEvent
      addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyUp
                                    handler:^(NSEvent *e) {
                                      __strong typeof(navWeakSelf) s =
                                          navWeakSelf;
                                      if (s && s->_compositionPeekKeyHeld &&
                                          [e.charactersIgnoringModifiers
                                                  .lowercaseString
                                              isEqualToString:@"p"])
                                        [s _setCompositionPeekHeld:NO
                                                          keyboard:YES];
                                    }];

  _openContentPopover = popover;
  return popover;
}

- (NSRectEdge)_inspectorSidePreferredEdge {
  NSRectEdge sideEdge = NSRectEdgeMinX;
  if (self.window && self.window.screen) {
    NSRect selfScreen = [self.window
        convertRectToScreen:[self convertRect:self.bounds toView:nil]];
    NSRect vis = self.window.screen.visibleFrame;
    CGFloat spaceLeft = NSMinX(selfScreen) - NSMinX(vis);
    CGFloat spaceRight = NSMaxX(vis) - NSMaxX(selfScreen);
    sideEdge = (spaceLeft >= spaceRight) ? NSRectEdgeMinX : NSRectEdgeMaxX;
  }
  return sideEdge;
}

// Dedup tolerance for "same keypose, different lane" filmstrip cells. Two
// KPs within one frame render the same composite (the render pipeline
// already merges them), so the filmstrip should show one cell. Falls back
// to 1e-3 (~0.1% of the clip) before durations are populated by the first
// render tick.
- (double)_kpDedupEps {
  double clipDur = _basicGraph.clipDurationSeconds;
  if (clipDur <= 0.0)
    clipDur = _advancedGraph.clipDurationSeconds;
  double frameDur = _basicGraph.frameDurationSeconds;
  if (frameDur <= 0.0)
    frameDur = _advancedGraph.frameDurationSeconds;
  if (clipDur > 0.0 && frameDur > 0.0)
    return (frameDur * 0.5) / clipDur;
  return 1.0e-3;
}

// Build the label set of lanes participating in the open boundary popover
// (its displayLanes ∪ excludedLabels - both are same-group as the clicked KP).
// Used to scope the filmstrip / prev-next nav so Advanced's per-lane timing
// doesn't bleed unrelated lanes' KPs into the strip. Returns nil when no
// popover is open OR no scope was recorded - caller falls back to "all
// animatable lanes" which is correct for Basic (shared timing).
// Scope = the *primary* lane the popover is anchored to (the lane whose
// pill was clicked, or last navigated to via the filmstrip). Falls back to
// the full `displayLanes` set when no primary is known (Basic has no per-
// lane primary - all animatable lanes share boundary times anyway).
//
// `displayLanes` alone is wrong: when two same-group lanes happen to have a
// KP at the same time, Advanced expands displayLanes to include both so the
// popover can edit either value - but the filmstrip should still only
// reflect the originally-clicked lane's keypose timeline, otherwise the
// other lane's unrelated KPs leak in as phantom cells.
- (NSString *)_timeStringForFraction:(double)frac {
  if (_clipDurationSeconds > 0)
    return [NSString stringWithFormat:@"%.2fs", frac * _clipDurationSeconds];
  return [NSString stringWithFormat:@"%.0f%%", frac * 100.0];
}

// A skinny vertical pill matching the timeline keypose glyph (capsule.* is too
// fat). Template image so it tints with the header's dim colour.
static NSImage *_kkKeyposePillImage(void) {
  const CGFloat w = 5.0, h = 13.0;
  NSImage *img =
      [NSImage imageWithSize:NSMakeSize(w, h)
                     flipped:NO
              drawingHandler:^BOOL(NSRect r) {
                NSRect box = NSInsetRect(NSMakeRect(0, 0, w, h), 0.5, 0.5);
                NSBezierPath *p =
                    [NSBezierPath bezierPathWithRoundedRect:box
                                                    xRadius:(w - 1) / 2.0
                                                    yRadius:(w - 1) / 2.0];
                [[NSColor blackColor] setFill];
                [p fill];
                return YES;
              }];
  img.template = YES;
  return img;
}

BOOL _kkBoundaryValuesEqual(NSArray<NSNumber *> *a, NSArray<NSNumber *> *b) {
  if (a.count != b.count)
    return NO;
  for (NSUInteger i = 0; i < a.count; i++)
    if (fabs(a[i].doubleValue - b[i].doubleValue) > 1e-6)
      return NO;
  return YES;
}

// A boundary keypose is "linked" exactly when the tie-bar is drawn over an
// interval touching it: the interval's endpoints are linked AND its two
// keyposes hold the same value (a flat, linked hold). Mirror that condition
// against the real timeline so the title flag matches the graph 1:1.
- (BOOL)_anyLinkedKeyposeAtFraction:(double)frac {
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled)
      continue;
    NSArray<KKKeyPose *> *kps = lane.keyposes;
    for (NSInteger i = 0; i < (NSInteger)kps.count; i++) {
      if (fabs(kps[i].time - frac) > 1e-3)
        continue;
      if (i + 1 < (NSInteger)kps.count && kps[i].outgoing.endpointsLinked &&
          _kkBoundaryValuesEqual(kps[i].values, kps[i + 1].values))
        return YES;
      if (i > 0 && kps[i - 1].outgoing.endpointsLinked &&
          _kkBoundaryValuesEqual(kps[i - 1].values, kps[i].values))
        return YES;
    }
  }
  return NO;
}

- (void)
    _presentBoundaryValuePopoverFromAnchor:(NSView *)anchor
                              displayLanes:(NSArray<KKLane *> *)lanes
                                  fraction:(double)fraction
                            excludedLabels:(NSArray<NSString *> *)excludedLabels
                           initialCategory:(NSString *)initialCategory
                         remembersCategory:(BOOL)remembersCategory
                                   onValue:
                                       (void (^)(NSString *,
                                                 NSArray<NSNumber *> *))onValue
                                 onAnimate:(void (^)(NSString *))onAnimate
                                  onRemove:(void (^)(NSString *))onRemove
                               onDragBegin:(void (^)(void))onDragBegin
                                 onDragEnd:(void (^)(void))onDragEnd {
  if (lanes.count == 0 && excludedLabels.count == 0)
    return;
  __weak typeof(self) weak = self;
  _KKStaticValuesPopoverConfig *cfg =
      [[_KKStaticValuesPopoverConfig alloc] init];
  cfg.lanes = lanes;
  cfg.headerTitle = KKLoc(@"Keypose", @"Popover header: keypose.");
  cfg.headerDetail = [self _timeStringForFraction:fraction];
  cfg.headerIcon = _kkKeyposePillImage();
  cfg.renderMode = _renderMode;
  cfg.isBoundary = YES;
  cfg.fraction = fraction;
  // Open on the clicked keypose's category (the Advanced keypose popover can
  // span all categories, so the clicked lane's category is passed in explicitly
  // rather than guessed from the first display lane). The Basic boundary
  // popover has no single clicked lane, so it remembers the last tab instead.
  NSString *initCat =
      initialCategory.length ? initialCategory : lanes.firstObject.categoryKey;
  if (remembersCategory && _rememberedCategory.length)
    initCat = _rememberedCategory;
  cfg.initialCategory = initCat;
  if (remembersCategory)
    cfg.onCategoryChanged = ^(NSString *category) {
      __strong typeof(weak) s = weak;
      s->_rememberedCategory = [category copy];
    };
  cfg.excludedLabels = excludedLabels;
  cfg.onValue = onValue;
  cfg.onAnimate = onAnimate;
  cfg.onRemove = onRemove;
  cfg.onDragBegin = onDragBegin;
  cfg.onDragEnd = onDragEnd;
  cfg.onModeChanged = ^(KKMiniViewerRenderMode mode) {
    __strong typeof(weak) s = weak;
    [s _renderModeDidChange:mode];
  };
  cfg.onNavigate = ^(NSInteger dir) {
    __strong typeof(weak) s = weak;
    [s _navigateBoundaryPopoverDirection:dir];
  };
  [self _presentStaticValuesPopoverFromAnchor:anchor config:cfg];
}

@end

@implementation KKTimelineLanesView (Popovers)

- (NSString *)hostSelectedLayerKeyIn:(NSArray<KKLane *> *)lanes {
  return [self _hostSelectedLayerKeyIn:lanes];
}

- (NSSet<NSString *> *)openKeyposePopoverLayerKeys {
  if (!_openStaticView || !_openStaticIsBoundary)
    return [NSSet set];
  return KKLaneLayerKeysWithKeyposeNearFraction([self _graphTimeline].lanes,
                                                _openStaticBoundaryFraction);
}

- (void)closeManagePopover {
  [_openManagePopover close];
}

- (void)closeFilterPopover {
  [_laneFilterBar closeFilterPopover];
}

- (void)reopenOpenAppliesToPopover {
  if (!(_openGapEditor || _openHoldModEditor))
    return;
  // Basic's "Applies to" is keyed on shared In/Out/Hold sections, so re-derive
  // it against the new layer's timeline and re-scope the OPEN editor's
  // checklist in place (the `_rescopingGapPopover` flag routes the re-derived
  // participation to a rescope instead of a fresh popover - no close/reopen
  // flicker). Advanced's gap popover is anchored to one layer-specific keypose
  // interval - re-scoping to another layer's interval is undefined, so just
  // close it.
  if (_activeTab == 1) {
    [self _closeEditorPanel];
    [_openContentPopover close];
    return;
  }
  _rescopingGapPopover = YES;
  [_basicGraph reopenLastGapPopover];
  _rescopingGapPopover = NO;
}

- (NSPopover *)showCompanionPopover:(NSView *)content
                           fromView:(NSView *)anchor
                               kind:(NSString *)kind
                            onClose:(void (^)(void))onClose {
  // Present through the same keep-alive-aware presenter the value / manage
  // popovers use (ApplicationDefined + outside-click monitors that ignore
  // registered companion windows), then post the open/close signals a companion
  // panel (Canvas's layer list) observes - scoped to this lanes view via
  // `object`. Lets the OSC settings popover host the layer-list panel too.
  // These are option pickers (OSC / filter / param-order / motion blur), so
  // they dismiss on any outside click - a click elsewhere in the inspector
  // closes them (unlike the companion editors that stay open to switch
  // content).
  _nextPopoverIsOptionType = YES;
  __weak typeof(self) weak = self;
  NSPopover *popover =
      [self _showPopoverWithContent:content
                           fromView:anchor
                      preferredEdge:NSRectEdgeMinX
                            onClose:^{
                              __strong typeof(weak) s = weak;
                              [NSNotificationCenter.defaultCenter
                                  postNotificationName:
                                      KKStaticValuesPopoverDidCloseNotification
                                                object:s];
                              if (onClose)
                                onClose();
                            }];
  // isBoundary NO => every layer selectable (like the constants kind).
  KKPostStaticValuesPopoverDidOpen(popover, self, kind ?: @"osc", NO, 0.0);
  return popover;
}

- (NSPopover *)showOptionPopover:(NSView *)content
                        fromView:(NSView *)anchor
                   preferredEdge:(NSRectEdge)preferredEdge
                         onClose:(void (^)(void))onClose {
  // Option picker: dismiss on any outside click. No companion-panel DidOpen
  // signal (unlike -showCompanionPopover:) - these have no layer list beside
  // them.
  _nextPopoverIsOptionType = YES;
  return [self _showPopoverWithContent:content
                              fromView:anchor
                         preferredEdge:preferredEdge
                               onClose:onClose];
}

- (void)showStaticValuesPopoverFromView:(NSView *)anchor {
  // The Constants button is now a real toggle. A persistent panel no longer
  // disappears on outside clicks, so tapping the active source again is the
  // natural counterpart to Escape / the close button. A keypose panel still
  // switches to Constants in place.
  if ([self _editorPanelIsVisible] && _openEditorIsStaticFamily &&
      _openStaticView && !_openStaticIsBoundary) {
    [self _closeEditorPanel];
    return;
  }
  NSArray<KKLane *> *unopted = [self _unoptedLanes];
  if (unopted.count == 0)
    return;
  __weak typeof(self) weak = self;
  _KKStaticValuesPopoverConfig *cfg =
      [[_KKStaticValuesPopoverConfig alloc] init];
  cfg.lanes = unopted;
  cfg.headerTitle =
      KKLoc(@"Constants", @"Constants editor tab/section header.");
  // Dimmed subscript next to the title: the mini preview renders at the
  // playhead, not frame 0, so a property that animates in from off-screen
  // still shows here (see -showStaticValuesPopoverFromView: editFraction).
  cfg.headerDetail =
      KKLoc(@"Showing current frame",
            @"Constants editor preview hint: the mini-viewer shows the frame "
            @"at the playhead, not the first frame.");
  cfg.headerIcon =
      [KKPopoverHeaderView iconImageForSymbolName:@"slider.horizontal.3"];
  cfg.renderMode = KKMiniViewerRenderModeOff;
  // Remember the last category tab across reopens of the constants popover.
  cfg.initialCategory = _rememberedCategory;
  cfg.onCategoryChanged = ^(NSString *category) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    s->_rememberedCategory = [category copy];
    // Guide observation, fired alongside the remember so it never clobbers it.
    if (s.onGuideStaticCategoryChanged)
      s.onGuideStaticCategoryChanged(category);
  };
  // Constants commits go through -_setLaneValues:forLabel: (cfg.onValue=nil).
  // Outer drag begin/end forward to the lanes view's properties so a guide
  // observer is informed (same hook the boundary popover's caller wires).
  cfg.onDragBegin = ^{
    __strong typeof(weak) s = weak;
    if (s.onDragBegin)
      s.onDragBegin();
  };
  cfg.onDragEnd = ^{
    __strong typeof(weak) s = weak;
    if (s.onDragEnd)
      s.onDragEnd();
  };
  // Leading-gutter "move to animated" - the dropdown shortcut. Refreshing
  // `_unoptedLanes` to the open popover happens automatically via the
  // `_replaceLane` → `_refresh` chain (see `updateUnoptedLanes:` in
  // `_refresh`), so the flipped lane disappears from the popover without
  // an explicit close/reopen.
  cfg.onAddToAnimated = ^(NSString *label) {
    __strong typeof(weak) s = weak;
    [s _setLaneAnimatable:YES forLabel:label];
    // Same opt-in signal the manage popover's toggle fires, so a guide can
    // advance on this per-lane shortcut too (nil outside a guide).
    if (s.onLaneOptedIn)
      s.onLaneOptedIn(label);
  };
  // Playhead-fraction preview seeding (editFraction) happens in the presenter
  // itself so the in-place keypose->constants switch gets it too - see the
  // constants branch of -_presentStaticValuesPopoverFromAnchor:config:.
  [self _presentStaticValuesPopoverFromAnchor:anchor config:cfg];
}

- (nullable NSView *)staticValueRowViewForLabel:(NSString *)label {
  return [_openStaticView rowViewForLabel:label];
}

- (void)beginGuideConstantDrag {
  [_openStaticView guideBeginConstantDrag];
}

- (void)applyGuideConstantValues:(NSArray<NSNumber *> *)values
                        forLabel:(NSString *)label {
  [_openStaticView guideApplyConstantValues:values forLabel:label];
}

- (void)endGuideConstantDrag {
  [_openStaticView guideEndConstantDrag];
}

- (NSRect)guideConstantSliderTrackScreenRectForLabel:(NSString *)label {
  return [_openStaticView guideSliderTrackScreenRectForLabel:label];
}

- (NSRect)guideConstantSliderKnobScreenRectForLabel:(NSString *)label {
  return [_openStaticView guideSliderKnobScreenRectForLabel:label];
}

- (CGFloat)guideConstantSliderScreenXForValue:(double)value
                                     forLabel:(NSString *)label {
  return [_openStaticView guideSliderScreenXForValue:value forLabel:label];
}

- (double)guideConstantSliderValueForScreenX:(CGFloat)screenX
                                    forLabel:(NSString *)label {
  return [_openStaticView guideSliderValueForScreenX:screenX forLabel:label];
}

- (NSRect)guideConstantFieldScreenRectForLabel:(NSString *)label
                                     component:(NSInteger)component {
  return [_openStaticView guideFieldScreenRectForLabel:label
                                             component:component];
}

- (NSRect)guideConstantChoicePillScreenRectForLabel:(NSString *)label
                                            atIndex:(NSInteger)index {
  return [_openStaticView guideChoicePillScreenRectForLabel:label
                                                    atIndex:index];
}

- (NSRect)guideConstantCategoryPillScreenRectForKey:(NSString *)key {
  return [_openStaticView guideCategoryPillScreenRectForKey:key];
}

- (NSRect)guideConstantAddToAnimatedButtonScreenRectForLabel:(NSString *)label {
  return [_openStaticView guideAddToAnimatedButtonScreenRectForLabel:label];
}

- (void)guideScrollConstantRowIntoViewForLabel:(NSString *)label {
  [_openStaticView guideScrollRowIntoViewForLabel:label];
}

- (void)guideSelectConstantCategory:(NSString *)key {
  // Live-switch the open popover (if any); also remember it so a reopen lands
  // on the same tab.
  _rememberedCategory = [key copy];
  [_openStaticView guideSelectCategory:key];
}

- (void)setGuideConstantFieldEditHandlerForLabel:(NSString *)label
                                         handler:(void (^)(NSInteger,
                                                           double))handler {
  [_openStaticView setGuideFieldEditHandlerForLabel:label handler:handler];
}

- (void)commitGuideConstantFieldForLabel:(NSString *)label
                               component:(NSInteger)component {
  [_openStaticView guideCommitFieldForLabel:label component:component];
}

- (void)setOpenPopoverLivePlaying:(BOOL)playing {
  // Remembered even with no popover open: this is the only place the inspector
  // tells us, and it tells us once per flip, so a popover presented later reads
  // it from here (see the seed in -_showPopoverWithContent:).
  _openPopoverLivePlaying = playing;
  KKMiniViewerView *mini = _openEditorMiniViewer ?: _openContentMiniViewer;
  if (!mini)
    return;
  // Only react to the play state flipping; per-frame redraws come from the feed
  // poll picking up new source frames (each carries its own fraction tag), not
  // from the playhead poller.
  if (mini.livePlaybackActive == playing)
    return;
  mini.livePlaybackActive = playing;
  // The feed's source is pinned to the editor's frame - a keypose boundary, or
  // a stale request a prior keypose left behind (the constants editor writes
  // none of its own). Without releasing it, only the transform would animate
  // while the footage stayed frozen. Release the pin while playing so the feed
  // serves the live playhead frame for BOTH keypose and constants; on stop,
  // re-pin only a keypose so it snaps back to its frame (constants has nothing
  // to pin - single-slot live just shows the current playhead, which it
  // previews anyway).
  if (playing)
    [self _setOpenBoundaryRequestActive:NO];
  else if (_openStaticIsBoundary)
    [self _setOpenBoundaryRequestActive:YES];
  else
    [self _previewOpenConstantsAtFraction:[self _activeGraph].playheadFraction];
  [mini setNeedsDisplay:YES];
}

- (void)_setOpenBoundaryRequestActive:(BOOL)active {
  NSString *path = self.miniViewerRequestPath;
  if (!path)
    return;
  NSData *d = [NSData dataWithContentsOfFile:path];
  NSDictionary *j =
      d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
  if (![j isKindOfClass:[NSDictionary class]])
    return;
  NSArray<NSNumber *> *fracs =
      [j[@"fracs"] isKindOfClass:[NSArray class]] ? j[@"fracs"] : nil;
  if (fracs.count == 0) {
    NSNumber *f = j[@"frac"];
    fracs = f ? @[ f ] : @[ @0 ];
  }
  // Preserve the keypose fracs, flip only the active flag: NO releases the pin
  // (render side serves the live playhead frame), YES re-requests the keypose
  // boundary frame.
  KKWriteBoundaryRequestMulti(path, fracs, active);
}

@end
