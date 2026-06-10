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

void KKJoyrideStepAttachCursor(KKJoyrideStep *step,
                               NSCursor *_Nullable (^cursorFor)(NSPoint)) {
  if (!step || !cursorFor)
    return;
  // Hover (before press): the move monitor drives this when in the spotlight.
  step.spotlightMouseMoved = ^(NSPoint pt) {
    NSCursor *c = cursorFor(pt);
    if (c)
      [c set];
  };
  step.spotlightMouseExited = ^(NSPoint pt) {
    // Re-query at the now-outside point: for a point-aware source like the
    // mini-viewer this returns the arrow AND clears the renderer's hover
    // emphasis (its cursor hook doubles as its hover hook).
    NSCursor *c = cursorFor(pt);
    [(c ?: [NSCursor arrowCursor]) set];
  };
  // Hold the cursor through the drag (no move events fire while a button is
  // down; the drag monitor fires here instead). Chain the existing handlers.
  void (^prevDrag)(NSPoint) = step.spotlightMouseDragged;
  step.spotlightMouseDragged = ^(NSPoint pt) {
    NSCursor *c = cursorFor(pt);
    if (c)
      [c set];
    if (prevDrag)
      prevDrag(pt);
  };
  void (^prevUp)(NSPoint) = step.spotlightMouseUp;
  step.spotlightMouseUp = ^(NSPoint pt) {
    if (prevUp)
      prevUp(pt);
    [[NSCursor arrowCursor] set]; // drag done - back to arrow for the next step
  };
}
