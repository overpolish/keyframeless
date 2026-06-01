/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTokens.h"
#import "KKLocalized.h"
#import "KKMiniCanvasRenderer.h"
#import "KKMiniCanvasView.h"
#import "KKPopoverHeaderView.h"
#import "KKTimelineLanesView+Guide.h"
#import "KKTimelineLanesView_Popovers.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKSegmentEditView.h>
#import <KeyframelessKit/KKTimelineAdvancedView.h>
#import <QuartzCore/QuartzCore.h>

// The mini-canvas delegate is a KKMiniCanvasRenderer (or subclass) but its
// header framework-imports KKMiniCanvasView.h, which collides with the quote
// import above (path-dedup). Toggle its boundary-editing mode via KVC to
// avoid pulling that header in here.
static void KKSetBoundaryEditing(id delegate, BOOL on, double fraction) {
  if ([delegate
          respondsToSelector:NSSelectorFromString(@"setBoundaryEditing:")]) {
    [delegate setValue:@(on) forKey:@"boundaryEditing"];
    [delegate setValue:@(fraction) forKey:@"editFraction"];
  }
}

// Hide the mini-canvas handle/box for properties excluded from this phase.
static void KKSetSuppressedHandles(id delegate, NSArray<NSString *> *labels) {
  if ([delegate respondsToSelector:NSSelectorFromString(
                                       @"setSuppressedHandleLabels:")])
    [delegate setValue:labels forKey:@"suppressedHandleLabels"];
}

// Reverse channel: tell the render side which clip fraction the popover is
// previewing so it can pull that frame (via -scheduleInputs:).
static void KKWriteBoundaryRequest(NSString *path, double frac, BOOL active) {
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
static void KKWriteBoundaryRequestMulti(NSString *path,
                                        NSArray<NSNumber *> *fracs,
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

static KKMiniCanvasView *KKFindMiniCanvas(NSView *root) {
  if ([root isKindOfClass:[KKMiniCanvasView class]])
    return (KKMiniCanvasView *)root;
  for (NSView *sub in root.subviews) {
    KKMiniCanvasView *found = KKFindMiniCanvas(sub);
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
@interface _KKStaticValuesPopoverConfig : NSObject
@property(nonatomic, strong) NSArray<KKLane *> *lanes;
@property(nonatomic, copy) NSString *headerTitle;
@property(nonatomic, copy, nullable) NSString *headerDetail;
@property(nonatomic, strong, nullable) NSImage *headerIcon;
@property(nonatomic) KKMiniCanvasRenderMode renderMode;
@property(nonatomic) BOOL isBoundary;
// Boundary-only.
@property(nonatomic) double fraction;
@property(nonatomic, copy, nullable) NSArray<NSString *> *excludedLabels;
// Handlers. `onValue` nil → commits go through -_setLaneValues:forLabel:
// (constants direct write); non-nil → boundary, the host's per-fraction setter.
@property(nonatomic, copy, nullable) void (^onValue)
    (NSString *label, NSArray<NSNumber *> *values);
@property(nonatomic, copy, nullable) void (^onAnimate)(NSString *label);
@property(nonatomic, copy, nullable) void (^onRemove)(NSString *label);
/// Constants popover: leading-gutter "move to animated" handler. Lets
/// the user flip a property to animatable without going through the
/// dropdown - mirrors the keypose popover's "−" remove gutter.
@property(nonatomic, copy, nullable) void (^onAddToAnimated)(NSString *label);
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
@property(nonatomic, copy, nullable) void (^onNavigate)(NSInteger dir);
@property(nonatomic, copy, nullable) void (^onModeChanged)
    (KKMiniCanvasRenderMode mode);
@end

@implementation _KKStaticValuesPopoverConfig
@end

@interface KKTimelineLanesView (PopoversUnified)
- (void)_presentStaticValuesPopoverFromAnchor:(NSView *)anchor
                                       config:
                                           (_KKStaticValuesPopoverConfig *)cfg;
@end

@implementation KKTimelineLanesView (PopoversInternal)

- (void)_showManagePopoverFromView:(NSView *)anchorView {
  NSSet<NSString *> *checked = [self _optedInLabelsSet];
  __weak typeof(self) weak = self;

  __block _KKManagePopoverView *manageView = nil;
  manageView = [[_KKManagePopoverView alloc]
      initWithLanes:_availableLanes
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
  __weak NSPopover *weakPopover = popover;
  KKMiniCanvasView *canvas = KKFindMiniCanvas(content);
  __block id localMon = nil;
  __block id globalMon = nil;
  __block id magnifyLocalMon = nil;
  __block id magnifyGlobalMon = nil;
  __block id mouseLocalMon = nil;
  __block id mouseGlobalMon = nil;

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

  // Scroll over the mini canvas = zoom/pan (events arrive global in
  // ViewBridge XPC - see [[project_viewbridge_global_sendEvent]]); scroll
  // elsewhere keeps the old outside-dismiss behavior.
  // Scroll/magnify over the canvas is handled by the responder chain
  // (KKMiniCanvasView inside an NSScrollView - the proven mechanism). These
  // monitors only keep the outside-scroll-dismiss behavior, and must NOT
  // swallow or close when the pointer is over the canvas.
  localMon = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                   handler:^NSEvent *(NSEvent *e) {
                                     if (canvas && [canvas pointerOverCanvas])
                                       return e; // let the responder handle it
                                     if (e.window != popoverWindow)
                                       [weakPopover close];
                                     return e;
                                   }];

  globalMon = [NSEvent
      addGlobalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                    handler:^(NSEvent *e) {
                                      if (canvas && [canvas pointerOverCanvas])
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
    NSWindow *pw = [weakPopover contentViewController].view.window;
    NSPoint p = NSEvent.mouseLocation;
    if (pw && NSPointInRect(p, pw.frame))
      return;
    if (pointInJoyridePanel(p))
      return;
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
- (nullable NSSet<NSString *> *)_scopedLaneLabelsForOpenPopover {
  if (_advancedGraph && !_advancedGraph.hidden) {
    NSString *primary = _advancedGraph.primaryLaneLabel;
    if (primary)
      return [NSSet setWithObject:primary];
  }
  if (_openStaticBoundaryLanes.count == 0)
    return nil;
  NSMutableSet<NSString *> *labels = [NSMutableSet set];
  for (KKLane *l in _openStaticBoundaryLanes)
    if (l.label)
      [labels addObject:l.label];
  return labels;
}

- (void)_publishBoundaryRequestForFraction:(double)fraction {
  // Filmstrip / Onion = one frame per KP across the lanes participating in
  // the open popover (same-group as the clicked KP), time-sorted. Off =
  // single-frame at the clicked fraction. KP-snap (within ~1 frame) so
  // Basic's OutEnd (frac=1.0 click vs endFrac<1.0 KP) doesn't produce a
  // phantom extra cell.
  if (_renderMode != KKMiniCanvasRenderModeOff) {
    NSSet<NSString *> *scope = [self _scopedLaneLabelsForOpenPopover];
    NSMutableArray<NSNumber *> *kpTimes = [NSMutableArray array];
    for (KKLane *lane in _timeline.lanes) {
      if (!lane.enabled)
        continue;
      if (scope && ![scope containsObject:lane.label])
        continue;
      for (KKKeyPose *kp in lane.keyposes)
        [kpTimes addObject:@(kp.time)];
    }
    const double kSnapToKP = 0.05;
    double snapped = fraction;
    double bestDt = kSnapToKP;
    for (NSNumber *t in kpTimes) {
      double dt = fabs(t.doubleValue - fraction);
      if (dt < bestDt) {
        bestDt = dt;
        snapped = t.doubleValue;
      }
    }
    NSMutableArray<NSNumber *> *all = [NSMutableArray array];
    [all addObject:@(snapped)];
    [all addObjectsFromArray:kpTimes];
    [all sortUsingSelector:@selector(compare:)];
    NSMutableArray<NSNumber *> *ordered = [NSMutableArray array];
    const double dedupEps = [self _kpDedupEps];
    for (NSNumber *f in all) {
      if (ordered.count == 0 ||
          fabs(f.doubleValue - ordered.lastObject.doubleValue) > dedupEps)
        [ordered addObject:f];
    }
    NSArray<NSNumber *> *collapsed = [self _collapseTiedHolds:ordered
                                                        scope:scope];
    KKWriteBoundaryRequestMulti(self.miniCanvasRequestPath, collapsed, YES);
  } else {
    KKWriteBoundaryRequest(self.miniCanvasRequestPath, fraction, YES);
  }
}

// Time-sorted, eps-deduped list of every KP fraction across animatable
// lanes - the navigable set behind the popover's prev/next buttons.
- (NSArray<NSNumber *> *)_animatableKPFractions {
  NSSet<NSString *> *scope = [self _scopedLaneLabelsForOpenPopover];
  NSMutableArray<NSNumber *> *kpTimes = [NSMutableArray array];
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled)
      continue;
    if (scope && ![scope containsObject:lane.label])
      continue;
    for (KKKeyPose *kp in lane.keyposes)
      [kpTimes addObject:@(kp.time)];
  }
  [kpTimes sortUsingSelector:@selector(compare:)];
  NSMutableArray<NSNumber *> *deduped = [NSMutableArray array];
  const double dedupEps = [self _kpDedupEps];
  for (NSNumber *f in kpTimes) {
    if (deduped.count == 0 ||
        fabs(f.doubleValue - deduped.lastObject.doubleValue) > dedupEps)
      [deduped addObject:f];
  }
  return [self _collapseTiedHolds:deduped scope:scope];
}

// YES when every in-scope lane is constant across the open span (a,b) *because
// it's a tied/linked flat hold* (or the lane simply isn't animating there) -
// i.e. the frame at b is identical to the one at a by user intent, not
// coincidence. A lane with a real transition straddling the span returns NO
// (keep the cell). Spans passed here are consecutive entries in the KP-time
// union, so no lane has an interior KP between a and b: each sits in exactly
// one interval, found by the midpoint.
- (BOOL)_spanIsTiedHoldBetween:(double)a
                           and:(double)b
                         scope:(nullable NSSet<NSString *> *)scope {
  double mid = 0.5 * (a + b);
  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled)
      continue;
    if (scope && ![scope containsObject:lane.label])
      continue;
    NSArray<KKKeyPose *> *kps = lane.keyposes;
    if (kps.count < 2)
      continue; // constant lane - never blocks
    KKKeyPose *ia = nil, *ib = nil;
    for (NSInteger i = 0; i + 1 < (NSInteger)kps.count; i++) {
      if (kps[i].time <= mid && mid < kps[i + 1].time) {
        ia = kps[i];
        ib = kps[i + 1];
        break;
      }
    }
    if (!ia)
      continue; // span lies outside this lane's KP range - constant there
    if (!(ia.outgoing.endpointsLinked &&
          _kkBoundaryValuesEqual(ia.values, ib.values)))
      return NO;
  }
  return YES;
}

// Drop KP times whose span from the previous time is a tied/linked flat hold
// across all in-scope lanes - collapsing a tie-bar hold to a single
// representative (the earlier KP) so the filmstrip / onion / prev-next nav
// don't show identical frames twice. Input must be time-sorted.
- (NSArray<NSNumber *> *)_collapseTiedHolds:(NSArray<NSNumber *> *)sorted
                                      scope:
                                          (nullable NSSet<NSString *> *)scope {
  if (sorted.count < 2)
    return sorted;
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  [out addObject:sorted[0]];
  for (NSUInteger i = 1; i < sorted.count; i++) {
    if ([self _spanIsTiedHoldBetween:sorted[i - 1].doubleValue
                                 and:sorted[i].doubleValue
                               scope:scope])
      continue;
    [out addObject:sorted[i]];
  }
  return out;
}

// Returns the index of the KP closest to `frac` in `fracs` (NSNotFound only
// if the list is empty). Mirrors the snap behaviour used when publishing
// the boundary request so prev/next agree with the rendered filmstrip.
- (NSInteger)_indexOfFraction:(double)frac
                     inSorted:(NSArray<NSNumber *> *)fracs {
  if (fracs.count == 0)
    return NSNotFound;
  NSInteger best = 0;
  double bestDt = INFINITY;
  for (NSInteger i = 0; i < (NSInteger)fracs.count; i++) {
    double dt = fabs(fracs[i].doubleValue - frac);
    if (dt < bestDt) {
      bestDt = dt;
      best = i;
    }
  }
  return best;
}

- (void)_refreshBoundaryPopoverNavEnabled {
  if (!_openStaticView)
    return;
  NSArray<NSNumber *> *fracs = [self _animatableKPFractions];
  NSInteger idx = [self _indexOfFraction:_openStaticBoundaryFraction
                                inSorted:fracs];
  BOOL prev = (idx != NSNotFound && idx > 0);
  BOOL next = (idx != NSNotFound && idx + 1 < (NSInteger)fracs.count);
  [_openStaticView setNavPrevEnabled:prev nextEnabled:next];
}

- (void)_navigateBoundaryPopoverDirection:(NSInteger)direction {
  if (!(_openContentPopover.isShown && _openStaticIsBoundary))
    return;
  NSArray<NSNumber *> *fracs = [self _animatableKPFractions];
  NSInteger idx = [self _indexOfFraction:_openStaticBoundaryFraction
                                inSorted:fracs];
  if (idx == NSNotFound)
    return;
  NSInteger target = idx + direction;
  if (target < 0 || target >= (NSInteger)fracs.count)
    return;
  double newFrac = fracs[target].doubleValue;
  // Same path the filmstrip cell click uses - graph rebuilds the display
  // lanes for the new KP, then calls back into the in-place updater.
  if (_activeTab == 1) {
    [_advancedGraph requestValuePopoverAtFraction:newFrac];
  } else {
    [_basicGraph requestValuePopoverAtFraction:newFrac];
  }
}

- (void)_renderModeDidChange:(KKMiniCanvasRenderMode)mode {
  _renderMode = mode;
  if (self.onRenderModeChanged)
    self.onRenderModeChanged(mode);
  // Pill toggle while a boundary popover is open → re-publish so the
  // render side switches single↔multi without close/reopen.
  if (_openContentPopover.isShown && _openStaticIsBoundary && _openStaticView) {
    [self _publishBoundaryRequestForFraction:_openStaticBoundaryFraction];
    if (self.onBoundaryPreviewNeedsRender)
      self.onBoundaryPreviewNeedsRender();
  }
}

- (void)_republishBoundaryRequestIfOpen {
  if (_renderMode == KKMiniCanvasRenderModeOff)
    return;
  if (!(_openContentPopover.isShown && _openStaticIsBoundary &&
        _openStaticView))
    return;
  [self _publishBoundaryRequestForFraction:_openStaticBoundaryFraction];
  [self _refreshBoundaryPopoverNavEnabled];
  if (self.onBoundaryPreviewNeedsRender)
    self.onBoundaryPreviewNeedsRender();
}

- (void)_updateBoundaryPopoverInPlaceWithLanes:(NSArray<KKLane *> *)lanes
                                      fraction:(double)fraction
                                excludedLabels:
                                    (NSArray<NSString *> *)excludedLabels {
  if (!(_openContentPopover.isShown && _openStaticIsBoundary &&
        _openStaticView))
    return;
  BOOL fracChanged = fabs(fraction - _openStaticBoundaryFraction) > 1e-6;
  KKSetBoundaryEditing(self.miniCanvasDelegate, YES, fraction);
  KKSetSuppressedHandles(self.miniCanvasDelegate, excludedLabels);
  // Full row rebuild (not just value rebind): the editable↔Animate split can
  // change between fractions (navigate) or after add/remove, and the one-way
  // applyExcludedLabels: swap can't restore an editable row on its own.
  [_openStaticView rebuildRowsWithLanes:lanes excludedLabels:excludedLabels];
  [_openStaticView setHeaderDetail:[self _timeStringForFraction:fraction]];
  [_openStaticView setHeaderLinked:[self _anyLinkedKeyposeAtFraction:fraction]];
  _openStaticBoundaryFraction = fraction;
  _openStaticBoundaryLanes = [lanes copy];
  _openStaticBoundaryExcluded = [excludedLabels copy];
  // The render nudge writes an undoable param to force FCP to resolve the
  // preview frame at a NEW boundary time. A same-fraction in-place rebuild
  // (add / remove / undo-refresh) keeps the time, and the blob write already
  // triggers a render - nudging here would add a phantom undo entry (cmd-Z
  // would then need two presses). Only republish + nudge on a real time change
  // (navigation between boundaries).
  if (fracChanged) {
    [self _publishBoundaryRequestForFraction:fraction];
    if (self.onBoundaryPreviewNeedsRender)
      self.onBoundaryPreviewNeedsRender();
  }
  [self _refreshBoundaryPopoverNavEnabled];
}

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

static BOOL _kkBoundaryValuesEqual(NSArray<NSNumber *> *a,
                                   NSArray<NSNumber *> *b) {
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
  cfg.excludedLabels = excludedLabels;
  cfg.onValue = onValue;
  cfg.onAnimate = onAnimate;
  cfg.onRemove = onRemove;
  cfg.onDragBegin = onDragBegin;
  cfg.onDragEnd = onDragEnd;
  cfg.onModeChanged = ^(KKMiniCanvasRenderMode mode) {
    __strong typeof(weak) s = weak;
    [s _renderModeDidChange:mode];
  };
  cfg.onNavigate = ^(NSInteger dir) {
    __strong typeof(weak) s = weak;
    [s _navigateBoundaryPopoverDirection:dir];
  };
  [self _presentStaticValuesPopoverFromAnchor:anchor config:cfg];
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
  KKSegmentEditView *edit =
      [[KKSegmentEditView alloc] initWithKind:KKSegmentEditKindTransition
                                  showsLinked:NO
                                   bulkHeader:NO
                          participationLabels:partLabels
                          participationStates:partStates];
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
  edit.animateOut = animateOut;
  edit.curveType = (NSInteger)curve;
  edit.intensity = intensity;
  edit.frequency = frequency;
  // A curve pick is discrete → commits immediately (its own undo entry).
  // Intensity/frequency are continuous → KKSegmentEditView brackets the drag
  // via onSliderDragBegin/End, which we route to the host's undo group so the
  // per-tick writes coalesce to one entry (same chain as the boundary drag).
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
  edit.onSliderDragBegin = ^{
    if (onDragBegin)
      onDragBegin();
  };
  edit.onSliderDragEnd = ^{
    if (onDragEnd)
      onDragEnd();
  };

  CGFloat w = [KKSegmentEditView contentWidth];
  CGFloat editH =
      [KKSegmentEditView contentHeightForKind:KKSegmentEditKindTransition
                                  showsLinked:NO
                                   bulkHeader:NO
                                participation:(partLabels.count > 0)];
  edit.translatesAutoresizingMaskIntoConstraints = NO;

  // Plugin-supplied extras (toggles, sliders) appended below the segment
  // editor. Each row gets its own intrinsic height; container height grows.
  NSArray<NSView *> *extras = nil;
  if (self.gapPopoverExtraRows && representativeInterval && intervalMutator)
    extras = self.gapPopoverExtraRows(phase, laneLabel, representativeInterval,
                                      intervalReader ?: ^KKInterval *{
                                        return representativeInterval;
                                      },
                                      intervalMutator);

  // Wrap the editor with a "Curve <start>–<end>" header (the editor itself is
  // left untouched - it's also used by the hold-modulation popover).
  NSString *range = [NSString
      stringWithFormat:@"%@ → %@", [self _timeStringForFraction:startFraction],
                       [self _timeStringForFraction:endFraction]];
  KKPopoverHeaderView *header = [[KKPopoverHeaderView alloc]
      initWithTitle:KKLoc(@"Curve", @"Section: easing curve.")
             detail:range
         symbolName:@"point.topleft.down.to.point.bottomright.curvepath"];
  CGFloat headerH = [KKPopoverHeaderView height];
  CGFloat extrasH = 0;
  for (NSView *v in extras)
    extrasH += v.intrinsicContentSize.height;
  CGFloat totalH =
      KKPaddingMD + headerH + KKSpacingSM + editH + extrasH + KKPaddingMD;
  NSView *container =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, totalH)];
  [container addSubview:header];
  [container addSubview:edit];
  [NSLayoutConstraint activateConstraints:@[
    [header.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                         constant:KKPaddingMD],
    [header.topAnchor constraintEqualToAnchor:container.topAnchor
                                     constant:KKPaddingMD],
    [edit.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
    [edit.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    [edit.topAnchor constraintEqualToAnchor:header.bottomAnchor
                                   constant:KKSpacingSM],
    [edit.heightAnchor constraintEqualToConstant:editH],
    [container.widthAnchor constraintEqualToConstant:w],
    [container.heightAnchor constraintEqualToConstant:totalH],
  ]];
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
      // First extra anchors to edit.bottom which already includes the
      // editor's internal kVPadding (~10pt); zero gap here lands at roughly
      // the same visual spacing as the editor's internal kRowGap rows.
      // Subsequent extras stack with no extra gap; rows that need separation
      // should bake it into their own intrinsicContentSize.
      [extra.topAnchor constraintEqualToAnchor:prev.bottomAnchor],
    ]];
    prev = extra;
  }

  // Track the editor + a rebuilder so _refresh can push fresh participation
  // pill states after an external mutation (cmd-Z) without reopening - same
  // pattern as the hold-modulation popover.
  _openGapEditor = edit;
  _openGapRebuilder = [partRebuilder copy];
  _openGapIntervalReader = [intervalReader copy];
  _openExtraRows = extras;
  __weak typeof(self) weakClose = self;
  [self _showPopoverWithContent:container
                       fromView:anchor
                        onClose:^{
                          __strong typeof(weakClose) sc = weakClose;
                          if (!sc)
                            return;
                          sc->_openGapEditor = nil;
                          sc->_openGapRebuilder = nil;
                          sc->_openGapIntervalReader = nil;
                          sc->_openExtraRows = nil;
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

// KKSegmentEditView (Hold kind) pills are indexed by KKHoldEffect
// (0 None, 1 Bounce, 2 Wiggle); the model stores KKIntervalModulation. The
// evaluator maps Wiggle→Wiggle, Oscillate→Bounce (KKTimingEvaluation.m), so
// the pill index and the stored enum are NOT interchangeable.
NSInteger KKModulationToPill(KKIntervalModulation m) {
  switch (m) {
  case KKIntervalModulationWiggle:
    return KKHoldEffectWiggle;
  case KKIntervalModulationOscillate:
    return KKHoldEffectBounce;
  case KKIntervalModulationHandheld:
    return KKHoldEffectHandheld;
  default:
    return KKHoldEffectNone;
  }
}
static KKIntervalModulation KKPillToModulation(NSInteger pill) {
  switch (pill) {
  case KKHoldEffectWiggle:
    return KKIntervalModulationWiggle;
  case KKHoldEffectBounce:
    return KKIntervalModulationOscillate;
  case KKHoldEffectHandheld:
    return KKIntervalModulationHandheld;
  default:
    return KKIntervalModulationNone;
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
  KKSegmentEditView *edit =
      [[KKSegmentEditView alloc] initWithKind:KKSegmentEditKindHold
                                  showsLinked:showsLinked
                                   bulkHeader:NO
                       participationCompounds:partCompoundLabels
                  participationCompoundStates:partCompoundStates];
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
  edit.curveType = KKModulationToPill(modulation);
  edit.intensity = intensity;
  edit.frequency = frequency;
  edit.seed = seed;
  edit.linked = linked;
  __weak KKSegmentEditView *weakEdit = edit;
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
  edit.onSeedReroll = ^{
    uint32_t s = arc4random();
    weakEdit.seed = s;
    if (onSeed)
      onSeed(s);
  };
  edit.onLinkedChanged = ^(BOOL l) {
    if (onLinked)
      onLinked(l);
  };
  edit.onSliderDragBegin = ^{
    if (onDragBegin)
      onDragBegin();
  };
  edit.onSliderDragEnd = ^{
    if (onDragEnd)
      onDragEnd();
  };

  CGFloat w = [KKSegmentEditView contentWidth];
  CGFloat editH =
      [KKSegmentEditView contentHeightForKind:KKSegmentEditKindHold
                                  showsLinked:showsLinked
                                   bulkHeader:NO
                                participation:(partCompoundLabels.count > 0)];
  edit.translatesAutoresizingMaskIntoConstraints = NO;

  // Same header treatment as the curve popover (the editor is
  // shared/untouched).
  NSString *range = [NSString
      stringWithFormat:@"%@ → %@", [self _timeStringForFraction:startFraction],
                       [self _timeStringForFraction:endFraction]];
  KKPopoverHeaderView *header = [[KKPopoverHeaderView alloc]
      initWithTitle:KKLoc(@"Modulation", @"Section: modulation settings.")
             detail:range
         symbolName:@"waveform"];
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
  CGFloat totalH =
      KKPaddingMD + headerH + KKSpacingSM + editH + extrasH + KKPaddingMD;
  NSView *container =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, totalH)];
  [container addSubview:header];
  [container addSubview:edit];
  [NSLayoutConstraint activateConstraints:@[
    [header.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                         constant:KKPaddingMD],
    [header.topAnchor constraintEqualToAnchor:container.topAnchor
                                     constant:KKPaddingMD],
    [edit.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
    [edit.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    [edit.topAnchor constraintEqualToAnchor:header.bottomAnchor
                                   constant:KKSpacingSM],
    [edit.heightAnchor constraintEqualToConstant:editH],
    [container.widthAnchor constraintEqualToConstant:w],
    [container.heightAnchor constraintEqualToConstant:totalH],
  ]];
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
      // First extra anchors to edit.bottom which already includes the
      // editor's internal kVPadding (~10pt); zero gap here lands at roughly
      // the same visual spacing as the editor's internal kRowGap rows.
      // Subsequent extras stack with no extra gap; rows that need separation
      // should bake it into their own intrinsicContentSize.
      [extra.topAnchor constraintEqualToAnchor:prev.bottomAnchor],
    ]];
    prev = extra;
  }

  // Stash for external refresh on applyTimeline (cmd-Z etc).
  _openHoldModEditor = edit;
  _openHoldModRebuilder = [partRebuilder copy];
  _openHoldModIntervalReader = [intervalReader copy];
  _openExtraRows = extras;
  __weak typeof(self) weak = self;
  [self _showPopoverWithContent:container
                       fromView:anchor
                        onClose:^{
                          __strong typeof(weak) s = weak;
                          if (!s)
                            return;
                          s->_openHoldModEditor = nil;
                          s->_openHoldModRebuilder = nil;
                          s->_openHoldModIntervalReader = nil;
                          s->_openExtraRows = nil;
                        }];
}

// Unified static-values popover presenter. Constants AND keypose (boundary)
// modes flow through here - whatever feature lives in this method is in BOTH
// popovers automatically. New popover features go here, NOT into either
// caller, so the two never drift apart again.
- (void)_presentStaticValuesPopoverFromAnchor:(NSView *)anchor
                                       config:
                                           (_KKStaticValuesPopoverConfig *)cfg {
  // Boundary-only preamble: in-place rebind / defer-if-other-popover-open /
  // mini-canvas state setup / boundary-request publish + render nudge.
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

    KKSetBoundaryEditing(self.miniCanvasDelegate, YES, cfg.fraction);
    KKSetSuppressedHandles(self.miniCanvasDelegate, cfg.excludedLabels);
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

  // During drag we push live values into the mini canvas renderer (which
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
    id<KKMiniCanvasDelegate> del = s.miniCanvasDelegate;
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
    [sv.miniCanvas setNeedsDisplay:YES];
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
    id<KKMiniCanvasDelegate> del = s.miniCanvasDelegate;
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
      descriptorPath:self.miniCanvasDescriptorPath
          clipAspect:self.miniCanvasClipAspect
         headerTitle:cfg.headerTitle
        headerDetail:cfg.headerDetail
          headerIcon:cfg.headerIcon
      canvasDelegate:self.miniCanvasDelegate
          renderMode:cfg.renderMode
       onModeChanged:cfg.onModeChanged
          onNavigate:cfg.onNavigate
       onHandleValue:onHandleValue
         onDragBegin:onDragBeginBlock
           onDragEnd:onDragEndBlock
        editsKeypose:cfg.isBoundary];

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
    staticView.miniCanvas.onFilmstripCellActivated = ^(double newFrac) {
      __strong typeof(weakSelf) s = weakSelf;
      if (!s)
        return;
      if (s->_activeTab == 1)
        [weakAdv requestValuePopoverAtFraction:newFrac];
      else
        [weakBasic requestValuePopoverAtFraction:newFrac];
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
                        s->_openStaticView = nil;
                        if (isBoundary) {
                          s->_openStaticIsBoundary = NO;
                          KKSetBoundaryEditing(s.miniCanvasDelegate, NO, 0.0);
                          KKSetSuppressedHandles(s.miniCanvasDelegate, nil);
                          KKWriteBoundaryRequest(s.miniCanvasRequestPath, 0.0,
                                                 NO);
                        }
                        if (s.onStaticValuesPopoverClosed)
                          s.onStaticValuesPopoverClosed();
                      }];
  staticView.popover = popover;

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
          strong.onStaticValuesPopoverWillOpen(sv, KKFindMiniCanvas(sv));
        });
  }
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
  cfg.headerIcon =
      [KKPopoverHeaderView iconImageForSymbolName:@"slider.horizontal.3"];
  cfg.renderMode = KKMiniCanvasRenderModeOff;
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
