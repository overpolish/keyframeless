/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKParameterRowView.h"
#import "NSColor+KKColors.h"
#import <Cocoa/Cocoa.h>
#import <CoreMedia/CMTime.h>
#import <FxPlug/FxPlugSDK.h>

static const int64_t kSimulatedEventMarker = 0x53494D; // "SIM"

/// Intercepts mouse clicks and re-posts them as CGEvents so the underlying
/// host app view (hidden beneath this overlay) can receive them.
@interface KKEventForwardingView : NSView
@property(nonatomic, copy) void (^onMouseDown)(NSEvent *event);
@end

@implementation KKEventForwardingView

- (void)mouseDown:(NSEvent *)event {
  if (self.onMouseDown) {
    self.onMouseDown(event);
  }

  [self forwardMouseEvent:event type:kCGEventLeftMouseDown];
}

- (void)forwardMouseEvent:(NSEvent *)event type:(CGEventType)eventType {
  self.hidden = YES;

  CGPoint mouseCursorPosition = [self cgPointFromEvent:event];
  CGMouseButton button = kCGMouseButtonLeft;
  if (eventType == kCGEventRightMouseDown ||
      eventType == kCGEventRightMouseUp) {
    button = kCGMouseButtonRight;
  }

  CGEventRef cgEvent =
      CGEventCreateMouseEvent(NULL, eventType, mouseCursorPosition, button);
  CGEventSetIntegerValueField(cgEvent, kCGEventSourceUserData,
                              kSimulatedEventMarker);
  CGEventPost(kCGHIDEventTap, cgEvent);
  CFRelease(cgEvent);

  dispatch_async(dispatch_get_main_queue(), ^{
    self.hidden = NO;
  });
}

- (CGPoint)cgPointFromEvent:(NSEvent *)event {
  NSPoint windowPoint = [event locationInWindow];
  NSPoint screenPoint = [[self window] convertPointToScreen:windowPoint];
  NSScreen *screen = [[self window] screen] ?: [NSScreen mainScreen];
  CGFloat screenHeight = screen.frame.size.height;
  return CGPointMake(screenPoint.x, screenHeight - screenPoint.y);
}

@end

/// Draws a downward-pointing chevron to indicate a menu is available.
@interface KKMenuChevronView : NSView
@end

@implementation KKMenuChevronView

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];

  CGFloat chevronWidth = 6.5;
  CGFloat chevronHeight = 3.5;
  CGFloat rightMargin = 5.5;
  CGFloat bottomOffset = 0.5;

  CGFloat x = self.bounds.size.width - rightMargin - chevronWidth;
  CGFloat y = (self.bounds.size.height - chevronHeight) / 2;

  NSBezierPath *chevron = [NSBezierPath bezierPath];

  // Chevron pointing down
  [chevron moveToPoint:NSMakePoint(0, chevronHeight)]; // Top left
  [chevron lineToPoint:NSMakePoint(chevronWidth / 2, 0)];
  [chevron lineToPoint:NSMakePoint(chevronWidth, chevronHeight)]; // Top right

  NSAffineTransform *transform = [NSAffineTransform transform];
  [transform translateXBy:x yBy:y + bottomOffset];
  [chevron transformUsingAffineTransform:transform];

  [[NSColor inspectorLabelColor] setStroke];
  [chevron setLineWidth:1.5];
  [chevron stroke];
}

@end

/// Draws a diamond-shaped keyframe indicator.
/// Shows an outlined diamond with a + when no keyframe exists at the current
/// time, and a filled diamond with a − when one does.
@interface KKKeyframeDiamondView : NSView
@property(nonatomic) BOOL keyframeExists;
@end

@implementation KKKeyframeDiamondView

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];

  CGFloat diamondSize = 10;
  CGFloat rightMargin = 2.0;
  CGFloat bottomOffset = 0.5;
  CGFloat x = self.bounds.size.width - rightMargin - diamondSize;
  CGFloat y = (self.bounds.size.height - diamondSize) / 2;
  CGFloat halfSize = diamondSize / 2;

  NSBezierPath *diamond = [self diamondPathWithSize:diamondSize];
  NSBezierPath *symbol = [self symbolPathWithSize:diamondSize];

  NSAffineTransform *transform = [NSAffineTransform transform];
  [transform translateXBy:x yBy:y + halfSize + bottomOffset];
  [diamond transformUsingAffineTransform:transform];
  [symbol transformUsingAffineTransform:transform];

  if (_keyframeExists) {
    [self drawFilledDiamond:diamond withSymbolCutout:symbol];
  } else {
    [self drawStrokedDiamond:diamond withSymbol:symbol];
  }
}

- (NSBezierPath *)diamondPathWithSize:(CGFloat)size {
  NSBezierPath *diamond = [NSBezierPath bezierPath];
  CGFloat halfSize = size / 2;

  // Origin at (0, 0), drawing from left to right for positioning
  [diamond moveToPoint:NSMakePoint(0, 0)];
  [diamond lineToPoint:NSMakePoint(halfSize, halfSize)];
  [diamond lineToPoint:NSMakePoint(size, 0)];
  [diamond lineToPoint:NSMakePoint(halfSize, -halfSize)];
  [diamond closePath];

  return diamond;
}

- (NSBezierPath *)symbolPathWithSize:(CGFloat)diamondSize {
  NSBezierPath *symbol = [NSBezierPath bezierPath];
  CGFloat halfSize = diamondSize / 2;
  CGFloat symbolSize = 2.5;

  if (self.keyframeExists) {
    // Dash: remove/update keyframe
    [symbol moveToPoint:NSMakePoint(halfSize - symbolSize, 0)];
    [symbol lineToPoint:NSMakePoint(halfSize + symbolSize, 0)];
  } else {
    // Plus: add keyframe
    [symbol moveToPoint:NSMakePoint(halfSize, -symbolSize)];
    [symbol lineToPoint:NSMakePoint(halfSize, symbolSize)];
    [symbol moveToPoint:NSMakePoint(halfSize - symbolSize, 0)];
    [symbol lineToPoint:NSMakePoint(halfSize + symbolSize, 0)];
  }

  return symbol;
}

- (void)drawStrokedDiamond:(NSBezierPath *)diamond
                withSymbol:(NSBezierPath *)symbol {
  [[NSColor inspectorLabelColor] set];
  [diamond setLineWidth:1.0];
  [diamond stroke];
  [symbol setLineWidth:1.0];
  [symbol stroke];
}

- (void)drawFilledDiamond:(NSBezierPath *)diamond
         withSymbolCutout:(NSBezierPath *)symbol {
  [[NSColor inspectorLabelColor] set];
  [diamond fill];
  [diamond setLineWidth:1.0];
  [diamond stroke];

  [[NSColor inspectorBackground] set];
  [symbol setLineWidth:1.0];
  [symbol stroke];
}

@end

static const double kKeyframeControlWidth = 80.0;
static const double kMenuChevronWidth = 20.0;
static const double kKeyframeDiamondWidth = 18.0;

@implementation KKParameterRowView {
  BOOL _isHovered;
  // No way for us to know if the host (Motion/FCP) has a context menu open
  // we are in ViewBridge Jail - we can only guess
  BOOL _isContextMenuOpen;
  NSView *_backgroundView;
  KKEventForwardingView *_controlsRegion;
  KKMenuChevronView *_menuChevron;
  KKKeyframeDiamondView *_keyframeDiamond;

  id _globalMonitor;
  id _localMonitor;
  NSInteger _monitorInstallerEventNumber;

  BOOL _isKeyframeDiamondPressed;
}

- (instancetype)initWithFrame:(NSRect)frameRect
                   apiManager:(id<PROAPIAccessing>)apiManager
                  parameterId:(UInt32)parameterId {
  self = [super initWithFrame:frameRect];
  if (self) {
    _apiManager = apiManager;
    _parameterId = parameterId;

    [self setupViews];
    [self setupConstraints];
    [self setupEventHandlers];

    [self updateControlsVisibility];
  }
  return self;
}

- (void)drawRect:(NSRect)dirtyRect {
  // drawRect runs anytime play head moves, keyframe is added/removed, etc
  [super drawRect:dirtyRect];
  [self refreshKeyframeState];
}

- (void)refreshKeyframeState {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];

  CMTime currentTime = [actionAPI currentTime];
  id<FxKeyframeAPI_v3> keyframeAPI =
      [_apiManager apiForProtocol:@protocol(FxKeyframeAPI_v3)];

  BOOL hasKeyframe = NO;
  [keyframeAPI parameter:_parameterId
                 channel:0
             hasKeyframe:&hasKeyframe
                  atTime:currentTime];

  _keyframeDiamond.keyframeExists = hasKeyframe;

  [actionAPI endAction:self];

  [_keyframeDiamond setNeedsDisplay:YES];
}

- (void)setupViews {
  _backgroundView = [[NSView alloc] initWithFrame:NSZeroRect];
  _backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
  _backgroundView.wantsLayer = YES;
  _backgroundView.layer.backgroundColor = [[NSColor redColor] CGColor];
  [self addSubview:_backgroundView];

  _controlsRegion = [[KKEventForwardingView alloc] initWithFrame:NSZeroRect];
  _controlsRegion.translatesAutoresizingMaskIntoConstraints = NO;
  _controlsRegion.wantsLayer = YES;
  // Effectively clearColor - using clearColor directly causes this NSView to no
  // longer participate in tracking events as all internal content is hidden
  // initially. Adding a pseudo-clear color keeps the view 'alive'
  _controlsRegion.layer.backgroundColor =
      [[[NSColor whiteColor] colorWithAlphaComponent:0.001] CGColor];
  [self addSubview:_controlsRegion];

  _menuChevron = [[KKMenuChevronView alloc] initWithFrame:NSZeroRect];
  _menuChevron.translatesAutoresizingMaskIntoConstraints = NO;
  _menuChevron.wantsLayer = YES;
  [_controlsRegion addSubview:_menuChevron];

  _keyframeDiamond = [[KKKeyframeDiamondView alloc] initWithFrame:NSZeroRect];
  _keyframeDiamond.translatesAutoresizingMaskIntoConstraints = NO;
  _keyframeDiamond.wantsLayer = YES;
  [_controlsRegion addSubview:_keyframeDiamond];
}

- (void)setupConstraints {
  // Layout lag when resizing inspector is most likely down to ViewBridge XPC
  // round-trip, it takes time for our view to get the new size from the host
  // app
  [NSLayoutConstraint activateConstraints:@[
    [_backgroundView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_backgroundView.topAnchor constraintEqualToAnchor:self.topAnchor],
    [_backgroundView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    [_backgroundView.trailingAnchor
        constraintEqualToAnchor:self.trailingAnchor
                       constant:-kKeyframeControlWidth],

    [_controlsRegion.leadingAnchor
        constraintEqualToAnchor:_backgroundView.trailingAnchor],
    [_controlsRegion.trailingAnchor
        constraintEqualToAnchor:self.trailingAnchor],
    [_controlsRegion.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_controlsRegion.heightAnchor constraintEqualToAnchor:self.heightAnchor],

    [_menuChevron.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_menuChevron.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_menuChevron.widthAnchor constraintEqualToConstant:kMenuChevronWidth],
    [_menuChevron.heightAnchor constraintEqualToAnchor:self.heightAnchor],

    [_keyframeDiamond.trailingAnchor
        constraintEqualToAnchor:_menuChevron.leadingAnchor],
    [_keyframeDiamond.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_keyframeDiamond.widthAnchor
        constraintEqualToConstant:kKeyframeDiamondWidth],
    [_keyframeDiamond.heightAnchor constraintEqualToAnchor:self.heightAnchor]
  ]];
}

- (void)setupEventHandlers {
  __weak typeof(self) weakSelf = self;
  _controlsRegion.onMouseDown = ^(NSEvent *event) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }

    NSPoint locationInWindow = [event locationInWindow];
    NSPoint locationInRegion =
        [strongSelf->_controlsRegion convertPoint:locationInWindow
                                         fromView:nil];

    if ([strongSelf->_menuChevron hitTest:locationInRegion]) {
      [strongSelf handleMenuChevronClick:event];
    } else if ([strongSelf->_keyframeDiamond hitTest:locationInRegion]) {
      // Hide diamond and let the underlying Motion/FCP button handle state
      [strongSelf handleKeyframeDiamondClick:event];
    }
  };
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];

  for (NSTrackingArea *area in self.trackingAreas) {
    [self removeTrackingArea:area];
  }

  NSTrackingArea *trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                   NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:trackingArea];
}

/// Updates the diamond's visibility while it is held pressed.
/// When pressed and hovering over the diamond, the host app shows its own
/// state so we hide ours. When pressed but cursor moves away, the row hover
/// effect takes over and we show both controls again.
- (void)updateKeyframeDiamondHoverState:(NSEvent *)event {
  if (!_isKeyframeDiamondPressed) {
    return;
  }

  NSPoint locationInWindow = [event locationInWindow];
  NSPoint locationInRegion = [_controlsRegion convertPoint:locationInWindow
                                                  fromView:nil];

  BOOL diamondHovered = [_keyframeDiamond hitTest:locationInRegion];

  if (diamondHovered) {
    _keyframeDiamond.hidden = YES;
  } else {
    _keyframeDiamond.hidden = NO;
    _menuChevron.hidden = NO;
  }
}

- (void)mouseEntered:(NSEvent *)event {
  if ([NSApp isActive] && !_isContextMenuOpen) {
    _isHovered = YES;
    [self updateControlsVisibility];
    [self updateKeyframeDiamondHoverState:event];
  }
}

- (void)mouseExited:(NSEvent *)event {
  if (!_isContextMenuOpen) {
    _isHovered = NO;
    [self updateControlsVisibility];
    [self updateKeyframeDiamondHoverState:event];
  }
}

- (void)handleMenuChevronClick:(NSEvent *)event {
  if ([self wasSimulatedEvent:event]) {
    return;
  }

  if (event.eventNumber == _monitorInstallerEventNumber) {
    return;
  }

  if (_isContextMenuOpen) {
    // Keyframe region clicked whilst menu is already open
    [self closeMenu];
    return;
  }

  _monitorInstallerEventNumber = event.eventNumber;
  _isContextMenuOpen = YES;
  _isHovered = YES;
  [self updateControlsVisibility];

  // Wait for current mouse click to complete - avoids monitors reacting to the
  // initial click
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __weak typeof(self) weakSelf = self;
        [weakSelf
            installMonitors:NSEventMaskLeftMouseDown |
                            NSEventMaskRightMouseDown |
                            NSEventMaskOtherMouseDown | NSEventMaskLeftMouseUp |
                            NSEventMaskRightMouseUp | NSEventMaskOtherMouseUp |
                            NSEventMaskKeyDown
               eventHandler:^(NSEvent *event) {
                 __strong typeof(weakSelf) strongSelf = weakSelf;
                 if (!strongSelf) {
                   return;
                 }

                 [strongSelf closeMenu];
               }
                      delay:0.5];
      });
}

- (void)handleKeyframeDiamondClick:(NSEvent *)event {
  if ([self wasSimulatedEvent:event]) {
    return;
  }

  if (event.eventNumber == _monitorInstallerEventNumber) {
    return;
  }

  _monitorInstallerEventNumber = event.eventNumber;
  _isHovered = YES;
  _isKeyframeDiamondPressed = YES;
  [self updateControlsVisibility];
  [self updateKeyframeDiamondHoverState:event];

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __weak typeof(self) weakSelf = self;
        [weakSelf installMonitors:NSEventMaskLeftMouseUp
                     eventHandler:^(NSEvent *event) {
                       __strong typeof(weakSelf) strongSelf = weakSelf;
                       if (!strongSelf) {
                         return;
                       }

                       strongSelf->_isKeyframeDiamondPressed = NO;
                       [strongSelf updateControlsVisibility];
                     }
                            delay:0.0];
      });
}

- (void)installMonitors:(NSEventMask)eventMasks
           eventHandler:(void (^)(NSEvent *event))eventHandler
                  delay:(NSTimeInterval)delay {
  [self removeMonitors];

  NSTimeInterval monitorInstallTime = [NSDate timeIntervalSinceReferenceDate];
  __weak typeof(self) weakSelf = self;

  _globalMonitor = [NSEvent
      addGlobalMonitorForEventsMatchingMask:eventMasks
                                    handler:^(NSEvent *event) {
                                      __strong typeof(weakSelf) strongSelf =
                                          weakSelf;
                                      if (strongSelf &&
                                          [strongSelf
                                              shouldHandleEvent:event
                                                    installTime:
                                                        monitorInstallTime
                                                          delay:delay]) {
                                        eventHandler(event);
                                      }
                                    }];

  _localMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:eventMasks
                                   handler:^NSEvent *(NSEvent *event) {
                                     __strong typeof(weakSelf) strongSelf =
                                         weakSelf;
                                     if (strongSelf &&
                                         [strongSelf
                                             shouldHandleEvent:event
                                                   installTime:
                                                       monitorInstallTime
                                                         delay:delay]) {
                                       eventHandler(event);
                                     }
                                     return event;
                                   }];
}

- (BOOL)shouldHandleEvent:(NSEvent *)event
              installTime:(NSTimeInterval)monitorInstallTime
                    delay:(NSTimeInterval)delay {
  if ([self wasSimulatedEvent:event]) {
    return NO;
  }

  // If need to wait before handling
  if (delay > 0.0) {
    NSTimeInterval timeSinceInstall =
        [NSDate timeIntervalSinceReferenceDate] - monitorInstallTime;
    if (timeSinceInstall < delay && [self isMouseOverView]) {
      return NO;
    }
  }

  return YES;
}

- (BOOL)wasSimulatedEvent:(NSEvent *)event {
  CGEventRef cgEvent = [event CGEvent];
  if (cgEvent) {
    int64_t userData =
        CGEventGetIntegerValueField(cgEvent, kCGEventSourceUserData);
    if (userData == kSimulatedEventMarker) {
      return YES;
    }
  }
  return NO;
}

/// Marks the menu as closed, updates state and relevant UI.
- (void)closeMenu {
  _isContextMenuOpen = NO;
  _isHovered = [self isMouseOverView];
  [self updateControlsVisibility];
  [self removeMonitors];
}

- (BOOL)isMouseOverView {
  NSPoint mouseLocation = [NSEvent mouseLocation];
  NSPoint windowPoint = [self.window convertPointFromScreen:mouseLocation];
  NSPoint viewPoint = [self convertPoint:windowPoint fromView:nil];
  return [self mouse:viewPoint inRect:self.bounds];
}

- (void)removeMonitors {
  if (_globalMonitor) {
    [NSEvent removeMonitor:_globalMonitor];
    _globalMonitor = nil;
  }
  if (_localMonitor) {
    [NSEvent removeMonitor:_localMonitor];
    _localMonitor = nil;
  }
}

- (void)updateControlsVisibility {
  BOOL visible = _isContextMenuOpen || _isHovered;
  _menuChevron.hidden = !visible;
  _keyframeDiamond.hidden = !visible;
}

- (void)dealloc {
  [self removeMonitors];
}

@end
