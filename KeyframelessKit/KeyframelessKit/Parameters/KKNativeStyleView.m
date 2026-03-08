/* KeyframelessKit - Shared framework for the Keyframeless FxPlug library
 * Copyright (C) 2026 overpolish
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#import "KKNativeStyleView.h"
#include "KKLog.h"
#import "NSColor+KKColors.h"
#include <AppKit/AppKit.h>
#include <AppKit/NSColor.h>
#include <AppKit/NSEvent.h>
#include <CoreFoundation/CFCGTypes.h>
#include <CoreGraphics/CGEvent.h>
#include <CoreGraphics/CGEventTypes.h>
#include <CoreMedia/CMTime.h>
#include <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>
#include <MacTypes.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/NSObjCRuntime.h>
#include <objc/objc.h>
#include <objc/runtime.h>

#import <Cocoa/Cocoa.h>
#include <CoreFoundation/CFCGTypes.h>

static const int64_t kSimulatedEventMarker = 0x53494D; // "SIM"

@interface PassthroughView : NSView
@property(nonatomic, copy) void (^onMouseDown)(NSEvent *event);
@end

@implementation PassthroughView

- (void)mouseDown:(NSEvent *)event {
  if (self.onMouseDown) {
    self.onMouseDown(event);
  }

  [self passThroughMouseEvent:event type:kCGEventLeftMouseDown];
}

- (void)passThroughMouseEvent:(NSEvent *)event type:(CGEventType)eventType {
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
  CGFloat screenHeight = NSScreen.mainScreen.frame.size.height;
  return CGPointMake(screenPoint.x, screenHeight - screenPoint.y);
}

@end

@interface MenuButtonView : NSView
@end

@implementation MenuButtonView

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

@interface UpdateKeyframeButton : NSView
@property(nonatomic) BOOL keyframeExists;
@end

@implementation UpdateKeyframeButton {
  KKLog *_log;
}

- (instancetype)init {
  _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
  return self;
}

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
    [symbol moveToPoint:NSMakePoint(halfSize - symbolSize, 0)];
    [symbol lineToPoint:NSMakePoint(halfSize + symbolSize, 0)];
  } else {
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
  [symbol setLineWidth:1.5];
  [symbol stroke];
}

@end

static const double kKeyframeControlWidth = 80.0;
static const double kMenuButtonWidth = 20.0;
static const double kUpdateKeyframeButtonWidth = 18.0;

@implementation KKNativeStyleView {
  BOOL _isHovered;
  // No way for us to know if the host (Motion/FCP) has a context menu open
  // we are in ViewBridge Jail - we can only guess
  BOOL _isContextMenuOpen;
  NSView *_backgroundView;
  PassthroughView *_keyframeControlsRegion;
  MenuButtonView *_menuButton;
  UpdateKeyframeButton *_updateKeyframeButton;
  KKLog *_log;

  id _globalMonitor;
  id _localMonitor;
  NSInteger _monitorInstallerEventNumber;

  BOOL _isUpdateKeyFramePressed;
}

- (instancetype)initWithFrame:(NSRect)frameRect
                   apiManager:(id<PROAPIAccessing>)apiManager
                  parameterId:(UInt32)parameterId {
  self = [super initWithFrame:frameRect];
  if (self) {
    _apiManager = apiManager;
    _parameterId = parameterId;
    _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];

    [self setupViews];
    [self setupConstraints];
    [self setupEventHandlers];

    [self updateKeyframeControlsVisibility];
  }
  return self;
}

- (void)drawRect:(NSRect)dirtyRect {
  // drawRect runs anytime play head moves, keyframe is added/removed, etc
  [super drawRect:dirtyRect];

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

  _updateKeyframeButton.keyframeExists = hasKeyframe;

  [actionAPI endAction:self];

  [_updateKeyframeButton setNeedsDisplay:YES];
}

- (void)setupViews {
  _backgroundView = [[NSView alloc] initWithFrame:NSZeroRect];
  _backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
  _backgroundView.wantsLayer = YES;
  _backgroundView.layer.backgroundColor = [[NSColor redColor] CGColor];
  [self addSubview:_backgroundView];

  _keyframeControlsRegion = [[PassthroughView alloc] initWithFrame:NSZeroRect];
  _keyframeControlsRegion.translatesAutoresizingMaskIntoConstraints = NO;
  _keyframeControlsRegion.wantsLayer = YES;
  // Effectively clearColor - using clearColor directly causes this NSView to no
  // longer participate in tracking events as all internal content is hidden
  // initially. Adding a pseudo-clear color keeps the view 'alive'
  _keyframeControlsRegion.layer.backgroundColor =
      [[[NSColor whiteColor] colorWithAlphaComponent:0.001] CGColor];
  [self addSubview:_keyframeControlsRegion];

  _menuButton = [[MenuButtonView alloc] initWithFrame:NSZeroRect];
  _menuButton.translatesAutoresizingMaskIntoConstraints = NO;
  _menuButton.wantsLayer = YES;
  [_keyframeControlsRegion addSubview:_menuButton];

  _updateKeyframeButton =
      [[UpdateKeyframeButton alloc] initWithFrame:NSZeroRect];
  _updateKeyframeButton.translatesAutoresizingMaskIntoConstraints = NO;
  _updateKeyframeButton.wantsLayer = YES;
  [_keyframeControlsRegion addSubview:_updateKeyframeButton];
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

    [_keyframeControlsRegion.leadingAnchor
        constraintEqualToAnchor:_backgroundView.trailingAnchor],
    [_keyframeControlsRegion.trailingAnchor
        constraintEqualToAnchor:self.trailingAnchor],
    [_keyframeControlsRegion.centerYAnchor
        constraintEqualToAnchor:self.centerYAnchor],
    [_keyframeControlsRegion.heightAnchor
        constraintEqualToAnchor:self.heightAnchor],

    [_menuButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_menuButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [_menuButton.widthAnchor constraintEqualToConstant:kMenuButtonWidth],
    [_menuButton.heightAnchor constraintEqualToAnchor:self.heightAnchor],

    [_updateKeyframeButton.trailingAnchor
        constraintEqualToAnchor:_menuButton.leadingAnchor],
    [_updateKeyframeButton.centerYAnchor
        constraintEqualToAnchor:self.centerYAnchor],
    [_updateKeyframeButton.widthAnchor
        constraintEqualToConstant:kUpdateKeyframeButtonWidth],
    [_updateKeyframeButton.heightAnchor
        constraintEqualToAnchor:self.heightAnchor]
  ]];
}

- (void)setupEventHandlers {
  __weak typeof(self) weakSelf = self;
  _keyframeControlsRegion.onMouseDown = ^(NSEvent *event) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf) {
      return;
    }

    NSPoint locationInWindow = [event locationInWindow];
    NSPoint locationInRegion =
        [strongSelf->_keyframeControlsRegion convertPoint:locationInWindow
                                                 fromView:nil];

    if ([strongSelf->_menuButton hitTest:locationInRegion]) {
      [strongSelf handleMenuButtonClick:event];
    } else if ([strongSelf->_updateKeyframeButton hitTest:locationInRegion]) {
      // Hide keyframe button and let underlying Motion/FCP button handle the
      // state
      [strongSelf handleUpdateKeyframeClick:event];
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

/// Handles hover states when update keyframe button pressed
- (void)updateSubviewHoverStates:(NSEvent *)event {
  if (!_isUpdateKeyFramePressed) {
    return;
  }

  NSPoint locationInWindow = [event locationInWindow];
  NSPoint locationInRegion =
      [_keyframeControlsRegion convertPoint:locationInWindow fromView:nil];

  BOOL updateKeyframeButtonHovered =
      [_updateKeyframeButton hitTest:locationInRegion];

  if (_isUpdateKeyFramePressed) {
    // When pressed and hovered Motion/FCP shows own state,
    // when pressed and not hovered the row hover effect takes over
    if (updateKeyframeButtonHovered) {
      _updateKeyframeButton.hidden = YES;
    } else {
      _updateKeyframeButton.hidden = NO;
      _menuButton.hidden = NO;
    }
  }
}

- (void)mouseEntered:(NSEvent *)event {
  if ([NSApp isActive] && !_isContextMenuOpen) {
    _isHovered = YES;
    [self updateKeyframeControlsVisibility];
    [self updateSubviewHoverStates:event];
  }
}

- (void)mouseExited:(NSEvent *)event {
  if (!_isContextMenuOpen) {
    _isHovered = NO;
    [self updateKeyframeControlsVisibility];
    [self updateSubviewHoverStates:event];
  }
}

- (void)handleMenuButtonClick:(NSEvent *)event {
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
  [self updateKeyframeControlsVisibility];

  // Wait for current mouse click to complete - avoids monitors reacting to the
  // initial click
  static const NSTimeInterval kMonitorIgnoreInterval = 0.5;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self installMonitors:NSEventMaskLeftMouseDown |
                              NSEventMaskRightMouseDown |
                              NSEventMaskOtherMouseDown |
                              NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp |
                              NSEventMaskOtherMouseUp | NSEventMaskKeyDown
                 eventHandler:^(NSEvent *event) {
                   [self closeMenu];
                 }
                        delay:kMonitorIgnoreInterval];
      });
}

- (void)handleUpdateKeyframeClick:(NSEvent *)event {
  if ([self wasSimulatedEvent:event]) {
    return;
  }

  if (event.eventNumber == _monitorInstallerEventNumber) {
    return;
  }

  _monitorInstallerEventNumber = event.eventNumber;
  _isHovered = YES;
  _isUpdateKeyFramePressed = YES;
  [self updateKeyframeControlsVisibility];
  [self updateSubviewHoverStates:event];

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self installMonitors:NSEventMaskLeftMouseUp
                 eventHandler:^(NSEvent *event) {
                   _isUpdateKeyFramePressed = NO;
                   [self updateKeyframeControlsVisibility];
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

/// Mark menu as closed, update state and relevant UI.
- (void)closeMenu {
  _isContextMenuOpen = NO;
  _isHovered = [self isMouseOverView];
  [self updateKeyframeControlsVisibility];
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

- (void)updateKeyframeControlsVisibility {
  if (_isContextMenuOpen || _isHovered) {
    _menuButton.hidden = NO;
    _updateKeyframeButton.hidden = NO;
  } else {
    _menuButton.hidden = YES;
    _updateKeyframeButton.hidden = YES;
  }
}

- (void)dealloc {
  [self removeMonitors];
}

@end