/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKEventForwardingView.h"

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
