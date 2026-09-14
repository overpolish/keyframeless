/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKJoyrideController.h"
#import "KKJoyrideController_Private.h"
#import "KKLog.h"

/// `ignoresMouseEvents` makes a window transparent to clicks/scroll but NOT
/// to gesture events - a pinch is delivered to this (frontmost) panel and,
/// unhandled, dropped before it can reach content below. Intercept magnify
/// at the window and hand it to the active step instead.
@interface _KKJoyrideForwardingPanel : NSPanel
@property(nonatomic, copy, nullable) void (^magnifyForwarder)(NSEvent *);
@end

@implementation _KKJoyrideForwardingPanel
- (void)sendEvent:(NSEvent *)event {
  if (event.type == NSEventTypeMagnify && _magnifyForwarder) {
    _magnifyForwarder(event);
    return;
  }
  [super sendEvent:event];
}
@end

@implementation KKJoyrideStep

+ (instancetype)stepWithMessage:(NSString *)message
                     targetView:(NSView *_Nullable (^)(void))targetView {
  KKJoyrideStep *s = [[self alloc] init];
  s->_message = [message copy];
  s->_targetView = [targetView copy];
  return s;
}

@end

@implementation KKJoyrideController

@synthesize hostPassthroughWindows = _hostPassthroughWindows;
@synthesize passthroughActivationHandler = _passthroughActivationHandler;

- (instancetype)initWithHostView:(NSView *)hostView {
  self = [super init];
  if (self) {
    _hostView = hostView;
  }
  return self;
}

- (BOOL)isActive {
  return _active;
}

- (NSInteger)currentStepIndex {
  return _currentIndex;
}

- (void)startWithSteps:(NSArray<KKJoyrideStep *> *)steps
            onComplete:(nullable void (^)(void))onComplete {
  if (_active) {
    _active = NO;
    [self _removeGlobalMonitor];
    [self _removeFocusObservers];
    [_panel orderOut:nil];
    _panel = nil;
    _overlay = nil;
    _onComplete = nil;
  }
  if (steps.count == 0) {
    if (onComplete)
      onComplete();
    return;
  }
  _steps = [steps copy];
  _onComplete = [onComplete copy];
  _currentIndex = 0;
  _active = YES;
  [self _installFocusObservers];
  [self _showStep:0];
}

- (void)advance {
  if (!_active)
    return;
  NSInteger next = _currentIndex + 1;
  if (next >= (NSInteger)_steps.count) {
    [self dismiss];
    return;
  }
  _currentIndex = next;
  [self _removeGlobalMonitor];
  NSPanel *oldPanel = _panel;
  [_overlay freezeForDismiss]; // old panel fades in place while next builds
  _panel = nil;
  _overlay = nil;
  __weak typeof(self) weak = self;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.2;
        oldPanel.animator.alphaValue = 0.0;
      }
      completionHandler:^{
        [oldPanel orderOut:nil];
        __strong typeof(weak) strong = weak;
        if (strong && strong->_active)
          [strong _showStep:next];
      }];
}

- (void)_applyPassthroughWindows:(BOOL)passThrough {
  for (NSWindow *w in _hostPassthroughWindows)
    w.ignoresMouseEvents = passThrough;
}

- (void)dismiss {
  if (!_active)
    return;
  _active = NO;
  [self _applyPassthroughWindows:NO];
  [self _removeGlobalMonitor];
  [self _removeFocusObservers];
  NSPanel *panel = _panel;
  [_overlay freezeForDismiss]; // fade in place, no centred-fallback jump
  _panel = nil;
  _overlay = nil;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.2;
        panel.animator.alphaValue = 0.0;
      }
      completionHandler:^{
        [panel orderOut:nil];
      }];
  [self _complete];
}

- (void)_showStep:(NSInteger)idx {
  NSView *host = _hostView;
  if (!host) {
    [self _complete];
    return;
  }
  KKJoyrideStep *step = _steps[idx];
  NSView *target = step.targetView ? step.targetView() : nil;
  BOOL isFinal = (idx + 1 == (NSInteger)_steps.count);

  NSScreen *screen = host.window.screen ?: NSScreen.mainScreen;
  _KKJoyrideForwardingPanel *panel = [[_KKJoyrideForwardingPanel alloc]
      initWithContentRect:screen.frame
                styleMask:NSWindowStyleMaskBorderless |
                          NSWindowStyleMaskNonactivatingPanel
                  backing:NSBackingStoreBuffered
                    defer:NO];
  __weak typeof(self) weakForward = self;
  panel.magnifyForwarder = ^(NSEvent *e) {
    __strong typeof(weakForward) sForward = weakForward;
    KKJoyrideStep *cur = [sForward _currentStep];
    if (cur.spotlightMagnifyEvent)
      cur.spotlightMagnifyEvent(e);
  };
  panel.level = NSPopUpMenuWindowLevel - 1;
  panel.opaque = NO;
  panel.backgroundColor = NSColor.clearColor;
  panel.hasShadow = NO;
  // Gesture events (pinch) bypass an ignoresMouseEvents window entirely, so a
  // guide that forwards gestures must let the panel receive events; clicks
  // still pass via the global monitor + synthesize path (overlay hitTest is
  // nil, so it never absorbs a click).
  //
  // A HOST/viewer pass-through step is the exception: it wants raw events to
  // reach the host (FCP's viewer), so the panel must ignore the mouse even when
  // the run forwards gestures for its non-pass-through (inspector) steps.
  // Without this, the panel sits over the viewer and FCP never sees the hover/
  // Option, so the OSC's opt-reveal (peek) and opt-click-hide never fire.
  //
  // An IN-PROCESS synthesize step (KKJoyrideDragStep, marked
  // spotlightSynthesizesInProcess) is pass-through for routing but drives a real
  // inspector view via the synthesize path - it must NOT ignore the mouse, or
  // the same press also reaches that view beneath the panel and the drag runs
  // twice (double onDragBegin leaks an undo group -> next startUndoGroup aborts).
  BOOL hostPassThrough =
      step.spotlightPassThrough && !step.spotlightSynthesizesInProcess;
  panel.ignoresMouseEvents = hostPassThrough ? YES : !self.forwardsGestures;
  panel.alphaValue = 0.0;

  _KKJoyrideOverlayView *overlay =
      [[_KKJoyrideOverlayView alloc] initWithTargetView:target
                                                message:step.message];
  if (step.targetScreenRect)
    [overlay setScreenRectBlock:step.targetScreenRect
                       circular:step.spotlightCircular];
  if (step.pillToScreenRect)
    [overlay setPillToScreenRectBlock:step.pillToScreenRect];
  overlay.spotlightPassThrough = step.spotlightPassThrough;
  overlay.step = step.displayStepNumber > 0 ? step.displayStepNumber : idx + 1;
  overlay.totalSteps = step.displayTotalSteps > 0 ? step.displayTotalSteps
                                                  : (NSInteger)_steps.count;
  overlay.frame = panel.contentView.bounds;
  overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [panel.contentView addSubview:overlay];

  _panel = panel;
  _overlay = overlay;
  _currentIndex = idx;
  [self _applyPassthroughWindows:step.spotlightPassThrough];

  __weak typeof(self) weak = self;

  if (!isFinal && step.showsNext) {
    overlay.onNext = ^{
      __strong typeof(weak) strong = weak;
      if (!strong || !strong->_active)
        return;
      [strong advance];
    };
  }

  overlay.onSkip = ^{
    __strong typeof(weak) strong = weak;
    if (!strong || !strong->_active)
      return;
    [strong dismiss];
  };

  [panel orderFront:nil];
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
    ctx.duration = 0.3;
    panel.animator.alphaValue = 1.0;
  }];

  if (step.spotlightPassThrough && _passthroughActivationHandler &&
      !step.spotlightMouseDown) {
    void (^handler)(void) = _passthroughActivationHandler;
    dispatch_async(dispatch_get_main_queue(), ^{
      handler();
    });
  }

  [self _installGlobalMonitor];

  // Fire the step's entry hook once it's on screen. Used to kick async work
  // for this step (e.g. the OSC portion's zoom-to-fit warm-up) - the step's
  // targetScreenRect stays NSZeroRect until that lands and a refreshSpotlight
  // reveals the cutout. This is the seam that lets one guide cross between
  // inspector-targeted and OSC-targeted steps.
  if (step.onEnter) {
    void (^enter)(void) = step.onEnter;
    dispatch_async(dispatch_get_main_queue(), ^{
      enter();
    });
  }
}

- (void)refreshSpotlight {
  [_overlay setNeedsDisplay:YES];
}

- (void)updateMessage:(NSString *)message stepNumber:(NSInteger)stepNumber {
  if (!_active)
    return;
  _overlay.message = message;
  if (stepNumber > 0)
    _overlay.step = stepNumber;
  [_overlay setNeedsDisplay:YES];
}

- (void)_complete {
  _active = NO;
  [self _removeFocusObservers];
  void (^block)(void) = _onComplete;
  _onComplete = nil;
  if (block)
    block();
}

- (void)dealloc {
  [self _removeGlobalMonitor];
  [self _removeFocusObservers];
  [_panel orderOut:nil];
}

@end
