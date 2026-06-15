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
#import <KeyframelessKit/KKTimelineAdvancedView.h>
#import <QuartzCore/QuartzCore.h>

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

- (void)_showManagePopoverFromView:(NSView *)anchorView {
  NSSet<NSString *> *checked = [self _optedInLabelsSet];
  __weak typeof(self) weak = self;

  // Mode-gated lanes drop out of the manage list (and their category, e.g. the
  // whole "Color" group when Mode = Dynamic) - computed over the timeline so
  // the controller Mode resolves to its current value.
  NSSet<NSString *> *condVisible =
      KKConditionalVisibleLaneLabels(_timeline.lanes, nil);
  NSMutableArray<KKLane *> *visibleLanes = [NSMutableArray array];
  for (KKLane *l in _availableLanes)
    if ([condVisible containsObject:l.label])
      [visibleLanes addObject:l];

  __block _KKManagePopoverView *manageView = nil;
  manageView = [[_KKManagePopoverView alloc]
      initWithLanes:visibleLanes
      checkedLabels:checked
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

  _openManageView = manageView;

  NSPopover *pop = [self _showPopoverWithContent:manageView
                                        fromView:anchorView
                                         onClose:^{
                                           __strong typeof(weak) s = weak;
                                           if (!s)
                                             return;
                                           s->_openManageView = nil;
                                           if (s.onManagePopoverClosed)
                                             s.onManagePopoverClosed();
                                         }];
  _openManagePopover = pop;
  manageView.popover = pop;

  if (self.onManagePopoverWillOpen) {
    NSString *targetLabel =
        self.managePopoverSpotlightLabel ?: _availableLanes.firstObject.label;
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

- (NSPopover *)_showPopoverWithContent:(NSView *)content
                              fromView:(NSView *)anchor
                               onClose:(void (^)(void))onClose {
  // Dismiss any popover from a previous call first - the ApplicationDefined
  // outside-click monitors don't fire click-to-click between two gaps in the
  // same custom view, so a second gap would otherwise stack on the first.
  // (Not reentrant: we're in a fresh mouseUp, not the old popover's callback.)
  [_openContentPopover close];

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

  NSPopover *popover = [[NSPopover alloc] init];
  // ApplicationDefined instead of Transient: Transient closes the popover if
  // ANY event targets a different window - ViewBridge-routed clicks from FCP
  // target the inspector window, not the popover, triggering that immediately.
  // We replicate outside-click close with local + global mouseDown monitors.
  popover.behavior = NSPopoverBehaviorApplicationDefined;
  popover.contentViewController = vc;

  [popover showRelativeToRect:anchor.bounds
                       ofView:anchor
                preferredEdge:NSRectEdgeMinY];

  NSWindow *popoverWindow = popover.contentViewController.view.window;
  CFTimeInterval shownAt = CACurrentMediaTime();
  // Host app (FCP) is frontmost when the popover opens. Captured so an
  // outside-click in another app doesn't dismiss it.
  pid_t hostPID =
      NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
  __weak NSPopover *weakPopover = popover;
  KKMiniViewerView *canvas = KKFindMiniViewer(content);
  __block id localMon = nil;
  __block id globalMon = nil;
  __block id magnifyLocalMon = nil;
  __block id magnifyGlobalMon = nil;
  __block id mouseLocalMon = nil;
  __block id mouseGlobalMon = nil;
  __block id keyMon = nil;
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
  };

  __block id closeObs = [NSNotificationCenter.defaultCenter
      addObserverForName:NSPopoverWillCloseNotification
                  object:popover
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *n) {
                removeMonitors();
                if (onClose)
                  onClose();
                [NSNotificationCenter.defaultCenter removeObserver:closeObs];
              }];

  // The content view can transiently veto dismissal (e.g. while a colour
  // swatch's shared NSColorPanel is open - a separate window whose clicks would
  // otherwise count as "outside" and close the popover mid-edit).
  BOOL (^contentSuppressesDismiss)(void) = ^BOOL {
    return [content respondsToSelector:@selector(suppressesPopoverDismiss)] &&
           [(id)content suppressesPopoverDismiss];
  };

  // Scroll over the mini viewer = zoom/pan (events arrive global in
  // ViewBridge XPC - see [[project_viewbridge_global_sendEvent]]); scroll
  // elsewhere keeps the old outside-dismiss behavior.
  // Scroll/magnify over the canvas is handled by the responder chain
  // (KKMiniViewerView inside an NSScrollView - the proven mechanism). These
  // monitors only keep the outside-scroll-dismiss behavior, and must NOT
  // swallow or close when the pointer is over the canvas.
  localMon = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                   handler:^NSEvent *(NSEvent *e) {
                                     if (canvas && [canvas pointerOverCanvas])
                                       return e; // let the responder handle it
                                     // Scroll inside a companion side panel
                                     // scrolls it, doesn't dismiss.
                                     if (KKPopoverPointInKeepAliveWindow(
                                             NSEvent.mouseLocation))
                                       return e;
                                     if (contentSuppressesDismiss())
                                       return e;
                                     if (e.window != popoverWindow)
                                       [weakPopover close];
                                     return e;
                                   }];

  globalMon = [NSEvent
      addGlobalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                    handler:^(NSEvent *e) {
                                      if (canvas && [canvas pointerOverCanvas])
                                        return;
                                      if (KKPopoverPointInKeepAliveWindow(
                                              NSEvent.mouseLocation))
                                        return;
                                      if (contentSuppressesDismiss())
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
    [weakPopover close];
  };
  mouseLocalMon = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                   handler:^NSEvent *(NSEvent *e) {
                                     // ViewBridge delivers the real click as a
                                     // local event ~50-100ms after the joyride
                                     // global monitor fires; ignore events in
                                     // that window to avoid false-closing the
                                     // popover.
                                     if (CACurrentMediaTime() - shownAt < 0.2)
                                       return e;
                                     if (e.window != popoverWindow)
                                       closeIfOutsidePopover();
                                     return e;
                                   }];
  mouseGlobalMon =
      [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown
                                             handler:^(NSEvent *e) {
                                               closeIfOutsidePopover();
                                             }];

  // Left/right arrows step to the prev/next keypose while the boundary popover
  // is focused - but only when no value field is being edited (the field editor
  // is first responder), so arrows still move the text cursor inside a field.
  keyMon = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                   handler:^NSEvent *(NSEvent *e) {
                                     __strong typeof(navWeakSelf) s =
                                         navWeakSelf;
                                     if (!s)
                                       return e;
                                     if (!(s->_openContentPopover.isShown &&
                                           s->_openStaticIsBoundary))
                                       return e;
                                     unsigned short kc = e.keyCode;
                                     if (kc != 123 && kc != 124)
                                       return e; // 123 = left, 124 = right
                                     // ViewBridge routes the popover's key
                                     // events through the host window, so
                                     // e.window never equals the popover window
                                     // - gate on the popover window's first
                                     // responder instead. An NSText (the field
                                     // editor) means a value field is being
                                     // edited: let the arrows move the text
                                     // cursor rather than navigating.
                                     if ([popoverWindow.firstResponder
                                             isKindOfClass:[NSText class]])
                                       return e;
                                     [s _navigateBoundaryPopoverDirection:
                                             (kc == 123 ? -1 : 1)];
                                     return nil; // consume
                                   }];

  _openContentPopover = popover;
  return popover;
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

- (void)closeManagePopover {
  [_openManagePopover close];
}

- (void)showStaticValuesPopoverFromView:(NSView *)anchor {
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
    s->_rememberedCategory = [category copy];
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
  };
  // Preview at the live playhead, not t=0. A property animated to start
  // off-canvas (e.g. flying in) would otherwise render its first-frame pose,
  // pushing the object + its handles out of the mini-viewer. Evaluate
  // animatable lanes at the current playhead fraction so the preview matches
  // the viewer. Constant lanes are single-keypose so editFraction doesn't move
  // them, and the constants WRITE path ignores editFraction too (it always
  // replaces the t=0 keypose - see -_timelineBySettingValues:forLabel:).
  // boundaryEditing stays NO, so handle gating / writes are unchanged. Reset
  // to 0 on close (see -_presentStaticValuesPopoverFromAnchor: onClose).
  id constantsDel = self.miniViewerDelegate;
  if ([constantsDel
          respondsToSelector:NSSelectorFromString(@"setEditFraction:")]) {
    double playFrac = [[(_activeTab == 1 ? (id)_advancedGraph : (id)_basicGraph)
        valueForKey:@"playheadFraction"] doubleValue];
    if (playFrac < 0.0)
      playFrac = 0.0; // render tick hasn't pushed a playhead yet
    [constantsDel setValue:@(playFrac) forKey:@"editFraction"];
  }
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

- (void)setGuideConstantFieldEditHandlerForLabel:(NSString *)label
                                         handler:(void (^)(NSInteger,
                                                           double))handler {
  [_openStaticView setGuideFieldEditHandlerForLabel:label handler:handler];
}

- (void)commitGuideConstantFieldForLabel:(NSString *)label
                               component:(NSInteger)component {
  [_openStaticView guideCommitFieldForLabel:label component:component];
}

@end
