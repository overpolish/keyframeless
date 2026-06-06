/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKJoyrideDragStep.h"

#import "KKJoyrideController.h"

NSPoint KKJoyrideSnapToTarget(NSPoint p, NSRect targetRect, CGFloat tolerance) {
  if (NSIsEmptyRect(targetRect))
    return p;
  NSPoint c = NSMakePoint(NSMidX(targetRect), NSMidY(targetRect));
  return (hypot(p.x - c.x, p.y - c.y) <= tolerance) ? c : p;
}

@implementation KKJoyrideDragStep

+ (KKJoyrideStep *)stepForGuide:(KKJoyrideController *)guide
                        atIndex:(NSInteger)stepIndex
                         isLast:(BOOL)isLast
                   clickMessage:(NSString *)clickMessage
                    dragMessage:(NSString *)dragMessage
                       circular:(BOOL)circular
                       spotRect:(NSRect (^)(void))spotRect
                     targetRect:(NSRect (^)(void))targetRect
                          begin:(void (^)(NSPoint))begin
                         dragTo:(void (^)(NSPoint))dragTo
                            end:(void (^)(void))end
                   hitOnRelease:(BOOL (^)(NSPoint))hitOnRelease {
  __weak KKJoyrideController *wg = guide;
  // No drag message ⇒ no press-gated reveal: the target shows immediately
  // and the prompt never changes (the slider-style step).
  __block BOOL pressed = (dragMessage == nil);
  NSString *swap = [dragMessage copy];

  KKJoyrideStep *step = [KKJoyrideStep stepWithMessage:clickMessage
                                            targetView:nil];
  step.spotlightCircular = circular;
  step.spotlightPassThrough = YES;
  // Drives an in-process inspector view via the synthesize path below, so the
  // overlay panel must keep capturing raw mouse events - otherwise the press
  // also reaches the real view and the drag fires twice (leaking an undo
  // group). See -[KKJoyrideController _showStep:].
  step.spotlightSynthesizesInProcess = YES;
  step.targetScreenRect = ^NSRect {
    return spotRect();
  };
  step.pillToScreenRect = ^NSRect {
    return pressed ? targetRect() : NSZeroRect;
  };
  step.spotlightMouseDown = ^(NSPoint p) {
    begin(p);
    if (swap && !pressed) {
      pressed = YES;
      [wg updateMessage:swap stepNumber:0];
    }
    [wg refreshSpotlight];
  };
  step.spotlightMouseDragged = ^(NSPoint p) {
    dragTo(p);
    [wg refreshSpotlight];
  };
  step.spotlightMouseUp = ^(NSPoint p) {
    end();
    __strong KKJoyrideController *g = wg;
    if (!g || !g.isActive || g.currentStepIndex != stepIndex)
      return;
    if (!hitOnRelease(p))
      return; // require-target-hit: stay, let them re-drag
    if (isLast)
      [g dismiss]; // final step → onComplete marks completed
    else
      [g advance];
  };
  return step;
}

@end
