//
//  KKNativeStyleView.m
//  KeyframelessKit
//
//  Created by Dom on 03/03/2026.
//

#import "KKNativeStyleView.h"
#import "NSColor+KKColors.h"
#include <AppKit/AppKit.h>
#include <AppKit/NSColor.h>
#include <CoreFoundation/CFCGTypes.h>
#include <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <objc/objc.h>
#include <objc/runtime.h>

#import <Cocoa/Cocoa.h>
#include <CoreFoundation/CFCGTypes.h>

@interface PassthroughView : NSView
@end

@implementation PassthroughView

- (void)mouseDown:(NSEvent *)event {
  [self passThroughMouseEvent:event type:kCGEventLeftMouseDown];
}

- (void)mouseUp:(NSEvent *)event {
  [self passThroughMouseEvent:event type:kCGEventLeftMouseUp];
}

- (void)mouseDragged:(NSEvent *)event {
  [self passThroughMouseEvent:event type:kCGEventLeftMouseDragged];
}

- (void)rightMouseDown:(NSEvent *)event {
  [self passThroughMouseEvent:event type:kCGEventRightMouseDown];
}

- (void)rightMouseUp:(NSEvent *)event {
  [self passThroughMouseEvent:event type:kCGEventRightMouseUp];
}

- (void)passThroughMouseEvent:(NSEvent *)event type:(CGEventType)eventType {
  // Hide immediately (no visual flicker at normal speed)
  self.hidden = YES;

  // Convert to screen coordinates
  NSPoint windowPoint = [event locationInWindow];
  NSPoint screenPoint = [[self window] convertPointToScreen:windowPoint];
  CGFloat screenHeight = NSScreen.mainScreen.frame.size.height;
  CGPoint cgPoint = CGPointMake(screenPoint.x, screenHeight - screenPoint.y);

  // Determine mouse button
  CGMouseButton button = kCGMouseButtonLeft;
  if (eventType == kCGEventRightMouseDown ||
      eventType == kCGEventRightMouseUp) {
    button = kCGMouseButtonRight;
  }

  // Create and post the event
  CGEventRef cgEvent =
      CGEventCreateMouseEvent(NULL, eventType, cgPoint, button);
  CGEventPost(kCGHIDEventTap, cgEvent);
  CFRelease(cgEvent);

  // Show again immediately (imperceptible delay)
  dispatch_async(dispatch_get_main_queue(), ^{
    self.hidden = NO;
  });
}

@end

@implementation KKNativeStyleView {
  BOOL _isHovered;
  PassthroughView *_squareView;
}

// TODO - left section/right section correctly switching, both nullable

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    // Background view (red, takes up most of the space)
    NSView *backgroundView = [[NSView alloc] initWithFrame:NSZeroRect];
    backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    backgroundView.wantsLayer = YES;
    backgroundView.layer.backgroundColor = [[NSColor redColor] CGColor];
    [self addSubview:backgroundView];

    // Square view in the right margin
    PassthroughView *squareView =
        [[PassthroughView alloc] initWithFrame:NSZeroRect];
    squareView.translatesAutoresizingMaskIntoConstraints = NO;
    squareView.wantsLayer = YES;
    squareView.layer.backgroundColor =
        [[[NSColor blueColor] colorWithAlphaComponent:0.5] CGColor];
    [self addSubview:squareView];
    _squareView = squareView;

    // Layout
    [NSLayoutConstraint activateConstraints:@[
      // Background view constraints
      [backgroundView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [backgroundView.topAnchor constraintEqualToAnchor:self.topAnchor],
      [backgroundView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [backgroundView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                    constant:-80],

      // Square view constraints - fills the 80pt margin
      [squareView.leadingAnchor
          constraintEqualToAnchor:backgroundView.trailingAnchor],
      [squareView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [squareView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [squareView.heightAnchor constraintEqualToConstant:80]
    ]];
  }
  return self;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];

  // Remove existing tracking areas
  for (NSTrackingArea *area in self.trackingAreas) {
    [self removeTrackingArea:area];
  }

  // Add tracking area over entire view
  NSTrackingArea *trackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                   NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
  // Turn right side purple
  _squareView.layer.backgroundColor =
      [[[NSColor purpleColor] colorWithAlphaComponent:0.5] CGColor];
}

- (void)mouseExited:(NSEvent *)event {
  // Turn right side back to blue
  _squareView.layer.backgroundColor =
      [[[NSColor blueColor] colorWithAlphaComponent:0.5] CGColor];
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
