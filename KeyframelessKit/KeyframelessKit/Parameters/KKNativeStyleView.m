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
#include <Foundation/Foundation.h>
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

static const double kKeyframeControlWidth = 80.0;
static const double kMenuButtonWidth = 20.0;

@implementation KKNativeStyleView {
  BOOL _isHovered;
  // No way for us to know if the host (Motion/FCP) has a context menu open
  // we are in ViewBridge Jail - we can only guess
  BOOL _isContextMenuOpen;
  NSView *_backgroundView;
  PassthroughView *_keyframeControlsRegion;
  MenuButtonView *_menuButton;
  KKLog *_log;
  // Event monitors to detect menu dismissal
  id _globalDismissalMonitor;
  id _localDismissalMonitor;
  NSInteger _monitorInstallerEventNumber;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];

    [self setupViews];
    [self setupConstraints];
    [self setupEventHandlers];

    [self updateKeyframeControlsVisibility];
  }
  return self;
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

  // TODO add keyframe shape, etc.
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
    [_menuButton.heightAnchor constraintEqualToAnchor:self.heightAnchor]

    // TODO add keyframe shape, etc.
  ]];
}

- (void)setupEventHandlers {
  __weak typeof(self) weakSelf = self;
  _keyframeControlsRegion.onMouseDown = ^(NSEvent *event) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf) {
      [strongSelf handleMenuButtonClick:event];
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

- (void)mouseEntered:(NSEvent *)event {
  if ([NSApp isActive] && !_isContextMenuOpen) {
    _isHovered = YES;
    [self updateKeyframeControlsVisibility];
  }
}

- (void)mouseExited:(NSEvent *)event {
  if (!_isContextMenuOpen) {
    _isHovered = NO;
    [self updateKeyframeControlsVisibility];
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
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self installMenuDismissalMonitors];
      });
}

- (void)installMenuDismissalMonitors {
  [self removeMenuDismissalMonitors];

  NSTimeInterval monitorInstallTime = [NSDate timeIntervalSinceReferenceDate];

  NSEventMask significantEvents =
      NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
      NSEventMaskOtherMouseDown | NSEventMaskLeftMouseUp |
      NSEventMaskRightMouseUp | NSEventMaskOtherMouseUp | NSEventMaskKeyDown;

  __weak typeof(self) weakSelf = self;
  _globalDismissalMonitor = [NSEvent
      addGlobalMonitorForEventsMatchingMask:significantEvents
                                    handler:^(NSEvent *event) {
                                      __strong typeof(weakSelf) strongSelf =
                                          weakSelf;
                                      if (strongSelf &&
                                          [strongSelf
                                              shouldDismissMenuForEvent:event
                                                            installTime:
                                                                monitorInstallTime]) {
                                        [strongSelf closeMenu];
                                      }
                                    }];

  _localDismissalMonitor = [NSEvent
      addLocalMonitorForEventsMatchingMask:significantEvents
                                   handler:^NSEvent *(NSEvent *event) {
                                     __strong typeof(weakSelf) strongSelf =
                                         weakSelf;
                                     if (strongSelf &&
                                         [strongSelf
                                             shouldDismissMenuForEvent:event
                                                           installTime:
                                                               monitorInstallTime]) {
                                       [strongSelf closeMenu];
                                     }
                                     return event;
                                   }];
}

- (BOOL)shouldDismissMenuForEvent:(NSEvent *)event
                      installTime:(NSTimeInterval)monitorInstallTime {
  if ([self wasSimulatedEvent:event]) {
    return NO;
  }

  NSTimeInterval timeSinceInstall =
      [NSDate timeIntervalSinceReferenceDate] - monitorInstallTime;
  static const NSTimeInterval kMonitorIgnoreInterval = 0.5;
  if (timeSinceInstall < kMonitorIgnoreInterval && [self isMouseOverView]) {
    return NO;
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
  [self removeMenuDismissalMonitors];
}

- (BOOL)isMouseOverView {
  NSPoint mouseLocation = [NSEvent mouseLocation];
  NSPoint windowPoint = [self.window convertPointFromScreen:mouseLocation];
  NSPoint viewPoint = [self convertPoint:windowPoint fromView:nil];
  return [self mouse:viewPoint inRect:self.bounds];
}

- (void)removeMenuDismissalMonitors {
  if (_globalDismissalMonitor) {
    [NSEvent removeMonitor:_globalDismissalMonitor];
    _globalDismissalMonitor = nil;
  }
  if (_localDismissalMonitor) {
    [NSEvent removeMonitor:_localDismissalMonitor];
    _localDismissalMonitor = nil;
  }
}

- (void)updateKeyframeControlsVisibility {
  if (_isContextMenuOpen || _isHovered) {
    _menuButton.hidden = NO;
  } else {
    _menuButton.hidden = YES;
  }
}

- (void)dealloc {
  [self removeMenuDismissalMonitors];
}

// - (instancetype)initWithFrame:(NSRect)frameRect {
//   self = [super initWithFrame:frameRect];
//   if (self) {
//     // Don't use wantsLayer - use setLayer directly for more control
//     // CALayer *layer = [CALayer layer];
//     // layer.frame = self.bounds;
//     // layer.backgroundColor = [[NSColor clearColor] CGColor];
//     // layer.opaque = NO;
//     // layer.masksToBounds = NO;

//     // Key: set the layer BEFORE enabling layer backing
//     [self setWantsLayer:YES];
//     self.layer.backgroundColor = [[NSColor clearColor] CGColor];
//     self.layer.opaque = NO;

//     // This view should not be part of responder chain
//     self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

//     // [self updateShapes];
//     // [self setWantsLayer:YES];
//     // self.layer.backgroundColor = [[NSColor clearColor] CGColor];

//     [self.layer setNeedsDisplay];
//     // [self updateShapes];
//     // _isHovered = NO;

//     // [self setWantsLayer:YES];
//     // _diamondLayer = [CAShapeLayer layer];
//     // _chevronLayer = [CAShapeLayer layer];

//     // _diamondLayer.actions =
//     //     @{@"position" : [NSNull null], @"bounds" : [NSNull null]};
//     // _chevronLayer.actions =
//     //     @{@"position" : [NSNull null], @"bounds" : [NSNull null]};

//     // if ([_diamondLayer
//     respondsToSelector:@selector(setHitTestsContents:)]) {
//     //   [_diamondLayer performSelector:@selector(setHitTestsContents:)
//     //                       withObject:@NO];
//     // }
//     // if ([_chevronLayer
//     respondsToSelector:@selector(setHitTestsContents:)]) {
//     //   [_chevronLayer performSelector:@selector(setHitTestsContents:)
//     //                       withObject:@NO];
//     // }

//     // [self.layer addSublayer:_diamondLayer];
//     // [self.layer addSublayer:_chevronLayer];

//     // [self updateShapes];

//     // Adding bg color makes hover work, but then clicks don't go through to
//     the
//     // keyframe buttons
//     // [self setWantsLayer:YES]; self.layer.backgroundColor =
//     //     [[[NSColor whiteColor] colorWithAlphaComponent:0.001] CGColor];
//   }
//   return self;
// }

// - (BOOL)wantsUpdateLayer {
//   return YES;
// }

// - (void)updateLayer {
//   // Draw into an image and set as layer contents
//   CGSize size = self.bounds.size;
//   if (size.width <= 0 || size.height <= 0)
//     return;

//   CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
//   CGContextRef ctx = CGBitmapContextCreate(
//       NULL, (size_t)size.width, (size_t)size.height, 8, (size_t)size.width *
//       4, colorSpace, kCGImageAlphaPremultipliedFirst);
//   CGColorSpaceRelease(colorSpace);

//   if (!ctx)
//     return;

//   CGContextClearRect(ctx, CGRectMake(0, 0, size.width, size.height));
//   CGContextSetRGBStrokeColor(ctx, 0.5, 0.5, 0.5, 1.0);

//   // Draw diamond
//   CGFloat diamondSize = 10;
//   CGFloat rightMargin = 22.0;
//   CGFloat bottomOffset = 0.5;
//   CGFloat x = size.width - rightMargin - diamondSize;
//   CGFloat y = (size.height - diamondSize) / 2;
//   CGFloat halfSize = diamondSize / 2;

//   CGContextSetLineWidth(ctx, 1.0);
//   CGContextBeginPath(ctx);
//   CGContextMoveToPoint(ctx, x, y + bottomOffset);
//   CGContextAddLineToPoint(ctx, x + halfSize, y + halfSize + bottomOffset);
//   CGContextAddLineToPoint(ctx, x + diamondSize, y + bottomOffset);
//   CGContextAddLineToPoint(ctx, x + halfSize, y - halfSize + bottomOffset);
//   CGContextClosePath(ctx);
//   CGContextStrokePath(ctx);

//   // Draw chevron
//   CGFloat chevronWidth = 6.5;
//   CGFloat chevronHeight = 3.5;
//   CGFloat chevronRightMargin = 5.5;
//   CGFloat chevronX = size.width - chevronRightMargin - chevronWidth;
//   CGFloat chevronY = (size.height - chevronHeight) / 2;

//   CGContextSetLineWidth(ctx, 1.5);
//   CGContextBeginPath(ctx);
//   CGContextMoveToPoint(ctx, chevronX, chevronY + chevronHeight +
//   bottomOffset); CGContextAddLineToPoint(ctx, chevronX + chevronWidth / 2,
//                           chevronY + bottomOffset);
//   CGContextAddLineToPoint(ctx, chevronX + chevronWidth,
//                           chevronY + chevronHeight + bottomOffset);
//   CGContextStrokePath(ctx);

//   CGImageRef image = CGBitmapContextCreateImage(ctx);

//   // Create a new layer that's NOT the view's layer
//   CALayer *overlayLayer = [CALayer layer];
//   overlayLayer.frame = self.bounds;
//   overlayLayer.contents = (__bridge id)image;

//   // Remove old overlay if exists
//   [[self.layer.sublayers firstObject] removeFromSuperlayer];

//   [self.layer addSublayer:overlayLayer];

//   CGImageRelease(image);
//   CGContextRelease(ctx);
// }

// - (void)layout {
//   [super layout];
//   [self.layer setNeedsDisplay];
// }

// - (BOOL)isOpaque {
//   return NO;
// }

// - (NSView *)hitTest:(NSPoint)point {
//   return nil;
// }

// mine

// - (void)drawKeyframeDiamond {
//   CGFloat diamondSize = 10;
//   CGFloat rightMargin = 22.0;
//   CGFloat bottomOffset = 0.5;
//   CGFloat x = self.bounds.size.width - rightMargin - diamondSize;
//   CGFloat y = (self.bounds.size.height - diamondSize) / 2;

//   NSBezierPath *diamond = [NSBezierPath bezierPath];
//   CGFloat halfSize = diamondSize / 2;

//   // TODO add a plus in middle and make the the norm - the keyframe outline
//   // already appears
//   // Origin at (0, 0), drawing from left to right for positioning
//   [diamond moveToPoint:NSMakePoint(0, 0)];                // Left
//   [diamond lineToPoint:NSMakePoint(halfSize, halfSize)];  // Top
//   [diamond lineToPoint:NSMakePoint(diamondSize, 0)];      // Right
//   [diamond lineToPoint:NSMakePoint(halfSize, -halfSize)]; // Bottom
//   [diamond closePath];

//   NSAffineTransform *transform = [NSAffineTransform transform];
//   [transform translateXBy:x yBy:y + halfSize + bottomOffset];
//   [diamond transformUsingAffineTransform:transform];

//   // TODO pull into color var
//   // TODO fill version
//   [[NSColor inspectorLabelColor] setStroke];
//   [diamond setLineWidth:1.0];
//   [diamond stroke];
// }

// - (void)drawControlChevron {
//   CGFloat chevronWidth = 6.5;
//   CGFloat chevronHeight = 3.5;
//   CGFloat rightMargin = 5.5;
//   CGFloat bottomOffset = 0.5;

//   CGFloat x = self.bounds.size.width - rightMargin - chevronWidth;
//   CGFloat y = (self.bounds.size.height - chevronHeight) / 2;

//   NSBezierPath *chevron = [NSBezierPath bezierPath];

//   // Chevron pointing down
//   [chevron moveToPoint:NSMakePoint(0, chevronHeight)]; // Top left
//   [chevron lineToPoint:NSMakePoint(chevronWidth / 2, 0)];
//   [chevron lineToPoint:NSMakePoint(chevronWidth, chevronHeight)]; // Top
//   right

//   NSAffineTransform *transform = [NSAffineTransform transform];
//   [transform translateXBy:x yBy:y + bottomOffset];
//   [chevron transformUsingAffineTransform:transform];

//   // TODO pull into color var
//   // TODO fill version
//   [[NSColor inspectorLabelColor] setStroke];
//   [chevron setLineWidth:1.5];
//   [chevron stroke];
// }

// - (void)updateTrackingAreas {
//   [super updateTrackingAreas];

//   for (NSTrackingArea *area in self.trackingAreas) {
//     [self removeTrackingArea:area];
//   }

//   NSTrackingArea *area = [[NSTrackingArea alloc]
//       initWithRect:self.bounds
//            options:NSTrackingMouseEnteredAndExited |
//                    NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
//              owner:self
//           userInfo:nil];
//   [self addTrackingArea:area];
// }

// - (void)mouseDown:(NSEvent *)event {
//   NSPoint windowPoint = [event locationInWindow];
//   [self.nextResponder mouseDown:event];
//   [[self window] sendEvent:event];
// }

// - (void)mouseUp:(NSEvent *)event {
//   [self.nextResponder mouseUp:event];
// }

// - (void)mouseDragged:(NSEvent *)event {
//   [self.nextResponder mouseDragged:event];
// }

// - (void)mouseEntered:(NSEvent *)event {
//   _isHovered = YES;
//   [self setNeedsDisplay:YES];
// }

// - (void)mouseExited:(NSEvent *)event {
//   _isHovered = NO;
//   [self setNeedsDisplay:YES];
// }

// - (NSView *)hitTest:(NSPoint)point {
//   return nil;
// }

@end
