/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKJoyrideOSCSegment.h"
#import "KKLog.h"

@implementation KKJoyrideOSCSegment {
  KKOSCGuideBridge *_bridge;
  KKOSCGuideStrategy *_strategy;
  id _stepObserver;
  id _positionObserver;
}

- (instancetype)initWithBridge:(KKOSCGuideBridge *)bridge
                      strategy:(KKOSCGuideStrategy *)strategy {
  self = [super init];
  if (self) {
    _bridge = bridge;
    _strategy = strategy;
  }
  return self;
}

- (NSArray<KKJoyrideStep *> *)stepsForGuide:(KKJoyrideController *)guide
                                displayBase:(NSInteger)displayBase
                               displayTotal:(NSInteger)displayTotal
                           firstStepOnEnter:(void (^)(void))firstStepOnEnter {
  KKOSCGuideBridge *bridge = _bridge;
  KKOSCGuideStrategy *strategy = _strategy;
  __weak KKJoyrideController *weakGuide = guide;
  NSInteger total = displayTotal > 0 ? displayTotal : 3;

  KKJoyrideStep *s1 = [KKJoyrideStep stepWithMessage:strategy.clickMessage
                                          targetView:nil];
  s1.targetScreenRect = ^NSRect {
    return [bridge estimatedHandleScreenRect];
  };
  s1.pillToScreenRect = ^NSRect {
    return [bridge estimatedTargetScreenRect];
  };
  s1.spotlightCircular = YES;
  s1.spotlightPassThrough = YES;
  s1.displayStepNumber = displayBase + 1;
  s1.displayTotalSteps = total;
  if (firstStepOnEnter)
    s1.onEnter = firstStepOnEnter;

  // Present the real OSC's cursor through the pass-through overlay while the
  // pointer is over the spotlight. FCP's own imperative setCursor doesn't
  // survive while the guide panel is frontmost, so the strategy hands us the
  // cursor the control would show and we set it here (also re-applied during
  // the drag below). Setting spotlightMouseMoved opts the controller's move
  // monitor in for this step.
  // On hover (in/out of the spotlight) present the control's cursor through the
  // pass-through overlay AND flip the OSC's hover emphasis (FCP runs neither
  // its own cursor nor its hitTest hover while the guide panel is frontmost).
  // The hover flag lives on the bridge; the OSC's drawOSC reads it.
  // requestRedraw forces the viewer to re-run drawOSC so the emphasis change
  // shows.
  NSCursor *_Nullable (^cursorFor)(NSPoint) = strategy.cursorForScreenPoint;
  void (^setHover)(BOOL) = ^(BOOL hovered) {
    if (bridge.handleHovered == hovered)
      return;
    bridge.handleHovered = hovered;
    if (strategy.requestRedraw)
      strategy.requestRedraw();
  };
  s1.spotlightMouseMoved = ^(NSPoint screenPt) {
    if (cursorFor) {
      NSCursor *c = cursorFor(screenPt);
      if (c)
        [c set];
    }
    setHover(YES);
  };
  s1.spotlightMouseExited = ^(NSPoint screenPt) {
    if (cursorFor)
      [[NSCursor arrowCursor] set]; // drop the control cursor on un-hover
    setHover(NO);
  };

  KKJoyrideStep *s3 = [KKJoyrideStep stepWithMessage:strategy.selectedMessage
                                          targetView:nil];
  NSRect (^finalRect)(void) = strategy.finalStepTargetRect;
  s3.targetScreenRect = ^NSRect {
    return finalRect ? finalRect() : NSZeroRect;
  };
  s3.displayStepNumber = displayBase + 3;
  s3.displayTotalSteps = total;

  // The ViewBridge NSServiceViewControllerWindow is a full-screen XPC window
  // that sits between our guide panel and FCP's native views. Setting
  // ignoresMouseEvents on it during passthrough steps lets clicks reach FCP.
  NSMutableArray<NSWindow *> *passthroughWins = [NSMutableArray array];
  for (NSWindow *w in [NSApp windows]) {
    if ([NSStringFromClass(w.class) containsString:@"ServiceViewController"])
      [passthroughWins addObject:w];
  }
  if (passthroughWins.count)
    guide.hostPassthroughWindows = passthroughWins;

  // Last value the drag set; the mouseUp gate checks whether it is ON the
  // target at *release* (not merely passed through it). Opaque (boxed) so the
  // segment supports scalar (radius) and 2D (position) controls alike.
  __block id lastValue = nil;
  NSInteger dragStepNumber = displayBase + 2;
  NSString *dragMessage = [strategy.dragMessage copy];

  s1.spotlightMouseDown = ^(NSPoint screenPt) {
    if (strategy.captureAnchorAtScreen)
      strategy.captureAnchorAtScreen(screenPt);
    id v = strategy.currentValue ? strategy.currentValue() : nil;
    if (v && strategy.setLiveValue)
      strategy.setLiveValue(v);
    lastValue = v;
    // Reveal the target now; the observer only advances on the final step so
    // this doesn't rebuild.
    bridge.guideStep = 2;
    // Same press, presented as advancing a step: swap the tooltip + counter
    // in place (no panel/monitor rebuild, so the drag keeps flowing).
    __strong KKJoyrideController *g = weakGuide;
    [g updateMessage:dragMessage stepNumber:dragStepNumber];
  };
  s1.spotlightMouseDragged = ^(NSPoint screenPt) {
    // Hold the control's cursor through the drag (the move monitor only fires
    // before the press; the drag monitor fires here).
    if (cursorFor) {
      NSCursor *c = cursorFor(screenPt);
      if (c)
        [c set];
    }
    if (!strategy.valueForScreenPoint)
      return;
    id v = strategy.valueForScreenPoint(screenPt);
    if (v && strategy.snapValue)
      v = strategy.snapValue(v); // snap to the glowing target when close
    lastValue = v;
    if (v && strategy.applyValue)
      strategy.applyValue(v);
  };
  s1.spotlightMouseUp = ^(NSPoint screenPt) {
    BOOL onTarget = lastValue && strategy.valueOnTarget &&
                    strategy.valueOnTarget(lastValue);
    if (strategy.requireTargetHit && !onTarget) {
      return; // user can press+drag again to land on it
    }
    // Drag done - drop back to the arrow so the next (non-pass-through) step
    // doesn't strand the control's cursor, and clear the hover emphasis.
    if (cursorFor)
      [[NSCursor arrowCursor] set];
    setHover(NO);
    bridge.guideStep = 3;
  };

  [self teardown];
  _stepObserver = [[NSNotificationCenter defaultCenter]
      addObserverForName:bridge.guideStepNotificationName
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *note) {
                __strong KKJoyrideController *g = weakGuide;
                if (!g || !g.isActive)
                  return;
                NSInteger step = [note.userInfo[@"step"] integerValue];
                // The combined drag step runs at step 2 the whole time; only
                // the drag's mouseUp (step 3) advances the joyride.
                if (step == 3)
                  [g advance];
              }];
  _positionObserver = [[NSNotificationCenter defaultCenter]
      addObserverForName:bridge.guidePositionNotificationName
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *note) {
                __strong KKJoyrideController *g = weakGuide;
                [g refreshSpotlight];
              }];

  return @[ s1, s3 ];
}

- (void)teardown {
  if (_stepObserver) {
    [[NSNotificationCenter defaultCenter] removeObserver:_stepObserver];
    _stepObserver = nil;
  }
  if (_positionObserver) {
    [[NSNotificationCenter defaultCenter] removeObserver:_positionObserver];
    _positionObserver = nil;
  }
}

- (void)dealloc {
  [self teardown];
}

@end
