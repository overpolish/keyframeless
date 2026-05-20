/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniCanvasView.h"
#import "KKTimelineLanesView+Guide.h"
#import "KKTimelineLanesView_Popovers.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKSegmentEditView.h>
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
  NSDictionary *d = @{
    @"frac" : @(frac),
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
  // Dismiss any popover from a previous call first — the ApplicationDefined
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
  // ANY event targets a different window — ViewBridge-routed clicks from FCP
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
  // ViewBridge XPC — see [[project_viewbridge_global_sendEvent]]); scroll
  // elsewhere keeps the old outside-dismiss behavior.
  // Scroll/magnify over the canvas is handled by the responder chain
  // (KKMiniCanvasView inside an NSScrollView — the proven mechanism). These
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
  // Joyride forwarding panels sit above the popover during a guide — a Next
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

- (void)
    _presentBoundaryValuePopoverFromAnchor:(NSView *)anchor
                              displayLanes:(NSArray<KKLane *> *)lanes
                                  fraction:(double)fraction
                            excludedLabels:(NSArray<NSString *> *)excludedLabels
                                   onValue:
                                       (void (^)(NSString *,
                                                 NSArray<NSNumber *> *))onValue
                                 onAnimate:(void (^)(NSString *))onAnimate
                               onDragBegin:(void (^)(void))onDragBegin
                                 onDragEnd:(void (^)(void))onDragEnd {
  if (lanes.count == 0 && excludedLabels.count == 0)
    return;
  // If a popover is still open, close it NOW (its onClose tears down the old
  // boundary state in order) but DEFER building the replacement one runloop
  // tick — back-to-back mini-canvas teardown+rebuild in the same call stack
  // stalls ~0.5s and the new MTKView comes up blank. Re-entry next tick finds
  // it closed and proceeds on the fast path (matches the outside-click order).
  if (_openContentPopover.isShown) {
    [_openContentPopover close];
    __weak typeof(self) wself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      [wself _presentBoundaryValuePopoverFromAnchor:anchor
                                       displayLanes:lanes
                                           fraction:fraction
                                     excludedLabels:excludedLabels
                                            onValue:onValue
                                          onAnimate:onAnimate
                                        onDragBegin:onDragBegin
                                          onDragEnd:onDragEnd];
    });
    return;
  }
  [_openContentPopover close];

  __weak typeof(self) weak = self;
  KKSetBoundaryEditing(self.miniCanvasDelegate, YES, fraction);
  KKSetSuppressedHandles(self.miniCanvasDelegate, excludedLabels);
  KKWriteBoundaryRequest(self.miniCanvasRequestPath, fraction, YES);
  // Static playhead → no render → -scheduleInputs: never sees the request
  // just written. Nudge one render so the boundary frame resolves now.
  if (self.onBoundaryPreviewNeedsRender)
    self.onBoundaryPreviewNeedsRender();

  // Coalesce continuous handle/slider drags to one commit on drag-end (same
  // pattern as the constants popover); a discrete field edit commits at once.
  __block NSString *pendingLabel = nil;
  __block NSArray<NSNumber *> *pendingValues = nil;
  __block BOOL dragging = NO;

  _KKStaticValuesPopoverView *staticView =
      [[_KKStaticValuesPopoverView alloc] initWithLanes:lanes
          descriptorPath:self.miniCanvasDescriptorPath
          clipAspect:self.miniCanvasClipAspect
          canvasDelegate:self.miniCanvasDelegate
          onHandleValue:^(NSString *label, NSArray<NSNumber *> *values) {
            __strong typeof(weak) s = weak;
            if (dragging) {
              pendingLabel = label;
              pendingValues = values;
            } else if (onValue) {
              onValue(label, values);
            }
            // Mirror the constants popover so a guide can observe edits
            // made in either popover via the same hook.
            if (s.onStaticValueChanged)
              s.onStaticValueChanged(label, values);
          }
          onDragBegin:^{
            dragging = YES;
            if (onDragBegin)
              onDragBegin();
          }
          onDragEnd:^{
            __strong typeof(weak) s = weak;
            NSString *endedLabel = pendingLabel;
            NSArray<NSNumber *> *endedValues = pendingValues;
            if (pendingLabel && pendingValues && onValue) {
              onValue(pendingLabel, pendingValues);
              pendingLabel = nil;
              pendingValues = nil;
            }
            dragging = NO;
            if (onDragEnd)
              onDragEnd();
            if (endedLabel && endedValues && s.onStaticValueDragEnded)
              s.onStaticValueDragEnded(endedLabel, endedValues);
          }];
  _openStaticView = staticView;
  _openStaticIsBoundary = YES;
  [staticView applyDefaultsProvider:^NSArray<NSNumber *> *(NSString *l) {
    __strong typeof(weak) s = weak;
    return s ? [s _defaultValuesForLabel:l] : nil;
  }];
  [staticView applyExcludedLabels:excludedLabels
                        onAnimate:^(NSString *label) {
                          if (onAnimate)
                            onAnimate(label);
                        }];

  NSPopover *popover = [self
      _showPopoverWithContent:staticView
                     fromView:anchor
                      onClose:^{
                        __strong typeof(weak) s = weak;
                        if (!s)
                          return;
                        s->_openStaticView = nil;
                        s->_openStaticIsBoundary = NO;
                        KKSetBoundaryEditing(s.miniCanvasDelegate, NO, 0.0);
                        KKSetSuppressedHandles(s.miniCanvasDelegate, nil);
                        KKWriteBoundaryRequest(s.miniCanvasRequestPath, 0.0,
                                               NO);
                        if (s.onStaticValuesPopoverClosed)
                          s.onStaticValuesPopoverClosed();
                      }];
  staticView.popover = popover;

  if (self.onStaticValuesPopoverWillOpen) {
    __weak _KKStaticValuesPopoverView *weakStatic = staticView;
    // Same settle delay as the constants popover so the entrance animation
    // is done before a guide reads frames / spotlights the mini-canvas.
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

- (void)_presentGapPopoverFromAnchor:(NSView *)anchor
                          animateOut:(BOOL)animateOut
                               curve:(KKIntervalCurve)curve
                           intensity:(double)intensity
                           frequency:(double)frequency
                          partLabels:(NSArray<NSString *> *)partLabels
                          partStates:(NSArray<NSNumber *> *)partStates
                             onCurve:(void (^)(KKIntervalCurve))onCurve
                         onIntensity:(void (^)(double))onIntensity
                         onFrequency:(void (^)(double))onFrequency
                     onParticipation:(void (^)(NSInteger, BOOL))onParticipation
                         onDragBegin:(void (^)(void))onDragBegin
                           onDragEnd:(void (^)(void))onDragEnd {
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
  CGFloat h =
      [KKSegmentEditView contentHeightForKind:KKSegmentEditKindTransition
                                  showsLinked:NO
                                   bulkHeader:NO
                                participation:(partLabels.count > 0)];
  edit.frame = NSMakeRect(0, 0, w, h);
  [edit.widthAnchor constraintEqualToConstant:w].active = YES;
  [edit.heightAnchor constraintEqualToConstant:h].active = YES;

  [self _showPopoverWithContent:edit
                       fromView:anchor
                        onClose:^{
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
static NSInteger KKModulationToPill(KKIntervalModulation m) {
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
                                 modulation:(KKIntervalModulation)modulation
                                  intensity:(double)intensity
                                  frequency:(double)frequency
                                       seed:(uint32_t)seed
                                     linked:(BOOL)linked
                                showsLinked:(BOOL)showsLinked
                                 partLabels:(NSArray<NSString *> *)partLabels
                                 partStates:(NSArray<NSNumber *> *)partStates
                               onModulation:
                                   (void (^)(KKIntervalModulation))onModulation
                                onIntensity:(void (^)(double))onIntensity
                                onFrequency:(void (^)(double))onFrequency
                                     onSeed:(void (^)(uint32_t))onSeed
                                   onLinked:(void (^)(BOOL))onLinked
                            onParticipation:(void (^)(NSInteger,
                                                      BOOL))onParticipation
                                onDragBegin:(void (^)(void))onDragBegin
                                  onDragEnd:(void (^)(void))onDragEnd {
  KKSegmentEditView *edit =
      [[KKSegmentEditView alloc] initWithKind:KKSegmentEditKindHold
                                  showsLinked:showsLinked
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
  CGFloat h = [KKSegmentEditView contentHeightForKind:KKSegmentEditKindHold
                                          showsLinked:showsLinked
                                           bulkHeader:NO
                                        participation:(partLabels.count > 0)];
  edit.frame = NSMakeRect(0, 0, w, h);
  [edit.widthAnchor constraintEqualToConstant:w].active = YES;
  [edit.heightAnchor constraintEqualToConstant:h].active = YES;

  [self _showPopoverWithContent:edit
                       fromView:anchor
                        onClose:^{
                        }];
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
  // The mini canvas tracks the cursor live from the renderer's optimistic
  // timeline, so the heavy persist (_setLaneValues → _refresh →
  // onTimelineMutated → FCP param write + JSON) doesn't need to run per
  // mouse-moved tick — doing so blocks the main thread and makes the
  // handles/redraw lag. Coalesce: stash the latest value during the drag,
  // commit once on drag end, inside the drag's undo group.
  __block NSString *pendingLabel = nil;
  __block NSArray<NSNumber *> *pendingValues = nil;
  __block BOOL dragging = NO;

  _KKStaticValuesPopoverView *staticView =
      [[_KKStaticValuesPopoverView alloc] initWithLanes:unopted
          descriptorPath:self.miniCanvasDescriptorPath
          clipAspect:self.miniCanvasClipAspect
          canvasDelegate:self.miniCanvasDelegate
          onHandleValue:^(NSString *label, NSArray<NSNumber *> *values) {
            __strong typeof(weak) s = weak;
            // During a drag (mini-canvas handle or slider) coalesce — commit
            // once on drag end. A discrete edit (text field) has no drag, so
            // commit immediately.
            if (dragging) {
              pendingLabel = label;
              pendingValues = values;
            } else {
              [s _setLaneValues:values forLabel:label];
            }
            if (s.onStaticValueChanged)
              s.onStaticValueChanged(label, values);
          }
          onDragBegin:^{
            __strong typeof(weak) s = weak;
            dragging = YES;
            if (s.onDragBegin)
              s.onDragBegin();
          }
          onDragEnd:^{
            __strong typeof(weak) s = weak;
            NSString *endedLabel = pendingLabel;
            NSArray<NSNumber *> *endedValues = pendingValues;
            if (pendingValues && pendingLabel) {
              [s _setLaneValues:pendingValues forLabel:pendingLabel];
              pendingValues = nil;
              pendingLabel = nil;
            }
            dragging = NO;
            if (s.onDragEnd)
              s.onDragEnd();
            if (endedLabel && endedValues && s.onStaticValueDragEnded)
              s.onStaticValueDragEnded(endedLabel, endedValues);
          }];
  _openStaticView = staticView;
  _openStaticIsBoundary = NO;
  [staticView applyDefaultsProvider:^NSArray<NSNumber *> *(NSString *l) {
    __strong typeof(weak) s = weak;
    return s ? [s _defaultValuesForLabel:l] : nil;
  }];

  NSPopover *popover =
      [self _showPopoverWithContent:staticView
                           fromView:anchor
                            onClose:^{
                              __strong typeof(weak) s = weak;
                              if (!s)
                                return;
                              s->_openStaticView = nil;
                              if (s.onStaticValuesPopoverClosed)
                                s.onStaticValuesPopoverClosed();
                            }];
  staticView.popover = popover;

  if (self.onStaticValuesPopoverWillOpen) {
    __weak _KKStaticValuesPopoverView *weakStatic = staticView;
    // Delay matches the manage popover: let the entrance animation settle and
    // the window attach before a guide reads frames / spotlights the handle.
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
