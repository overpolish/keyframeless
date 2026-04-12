/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (HitTest)

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = kOSCCanvas;
  self.paths = [self readPaths];

  double hitRadius = 12.0;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

  NSInteger toolbarPart = [self.toolbar hitTestAtX:positionX y:positionY];
  if (toolbarPart != 0) {
    *activePart = toolbarPart;
    [oscAPI setCursor:[NSCursor arrowCursor]];
    return;
  }

  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  BOOL isPenMode = (self.toolbar.activeTag == kOSCToolbarPen);
  BOOL isRectMode = (self.toolbar.activeTag == kOSCToolbarRect);

  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optDown = (flags & kCGEventFlagMaskAlternate) != 0;
  BOOL shiftDown = (flags & kCGEventFlagMaskShift) != 0;
  BOOL cmdDown = (flags & kCGEventFlagMaskCommand) != 0;

  KKBezierPath *active = [self activePath];

  // Test corner radius handles
  if (active && active.closed && active.count >= 4) {
    NSInteger crParts[4] = {kOSCCornerRadiusTL, kOSCCornerRadiusTR,
                            kOSCCornerRadiusBR, kOSCCornerRadiusBL};
    for (int ci = 0; ci < 4; ci++) {
      CGPoint crPos = [self cornerRadiusHandlePosition:ci forPath:active];
      if (hypot(positionX - crPos.x, positionY - crPos.y) < hitRadius) {
        *activePart = crParts[ci];
        [oscAPI setCursor:self.editPointsCursor];
        return;
      }
    }
  }

  // Test active path's handles and points
  if (active) {
    for (NSUInteger i = 0; i < active.count; i++) {
      KKBezierPoint pt = [active pointAtIndex:i];
      if (pt.type != KKBezierPointBezier)
        continue;

      CGPoint inCanvas = [self canvasPointForBezierPoint:pt inHandleOffset:YES];
      if (hypot(positionX - inCanvas.x, positionY - inCanvas.y) < hitRadius) {
        *activePart = kOSCInHandleBase + (NSInteger)i;
        [oscAPI setCursor:self.editPointsCursor];
        return;
      }

      CGPoint outCanvas = [self canvasPointForBezierPoint:pt inHandleOffset:NO];
      if (hypot(positionX - outCanvas.x, positionY - outCanvas.y) < hitRadius) {
        *activePart = kOSCOutHandleBase + (NSInteger)i;
        [oscAPI setCursor:self.editPointsCursor];
        return;
      }
    }

    for (NSUInteger i = 0; i < active.count; i++) {
      KKBezierPoint pt = [active pointAtIndex:i];
      CGPoint ptCanvas = [self canvasPointForBezierPoint:pt];
      if (hypot(positionX - ptCanvas.x, positionY - ptCanvas.y) < hitRadius) {
        if (isPenMode && i == 0 && !active.closed && active.count >= 3) {
          *activePart = kOSCClosePath;
          [oscAPI setCursor:self.penCloseCursor];
          return;
        }
        *activePart = kOSCPathPointBase + (NSInteger)i;
        [oscAPI setCursor:optDown ? self.penDeleteCursor : self.moveCursor];
        return;
      }
    }
  }

  double hitRadiusStroke = [self strokeHitRadius];

  if (isCursorMode) {
    NSInteger nearPath = [self pathIndexNearX:positionX
                                            y:positionY
                                       radius:hitRadiusStroke];
    if (nearPath >= 0) {
      *activePart = kOSCCanvas;
      [oscAPI setCursor:[NSCursor arrowCursor]];
      return;
    }
    // Empty space: marquee cursor with modifier hints
    if (self.selectedPoints.count > 0 && shiftDown)
      [oscAPI setCursor:[NSCursor dragCopyCursor]];
    else if (self.selectedPoints.count > 0 && optDown)
      [oscAPI setCursor:[NSCursor operationNotAllowedCursor]];
    else
      [oscAPI setCursor:[NSCursor crosshairCursor]];
    return;
  }

  // Pen mode + Cmd: temporary cursor mode (select, marquee, etc.)
  if (isPenMode && cmdDown) {
    NSInteger nearPath = [self pathIndexNearX:positionX
                                            y:positionY
                                       radius:hitRadiusStroke];
    if (nearPath >= 0) {
      *activePart = kOSCCanvas;
      [oscAPI setCursor:[NSCursor arrowCursor]];
      return;
    }
    // Empty space: marquee
    if (self.selectedPoints.count > 0 && shiftDown)
      [oscAPI setCursor:[NSCursor dragCopyCursor]];
    else if (self.selectedPoints.count > 0 && optDown)
      [oscAPI setCursor:[NSCursor operationNotAllowedCursor]];
    else
      [oscAPI setCursor:[NSCursor crosshairCursor]];
    return;
  }

  // Pen mode: test active path's segments for insertion
  if (isPenMode && active && active.count >= 2) {
    NSInteger segIdx = [self segmentIndexNearX:positionX
                                             y:positionY
                                        radius:hitRadiusStroke
                                        inPath:active];
    if (segIdx >= 0) {
      *activePart = kOSCPathSegmentBase + segIdx;
      [oscAPI setCursor:self.penAddCursor];
      return;
    }
  }

  if (isPenMode)
    [oscAPI setCursor:self.penAddCursor];
  else if (isRectMode)
    [oscAPI setCursor:[NSCursor crosshairCursor]];
  else
    [oscAPI setCursor:[NSCursor arrowCursor]];
}

@end
#pragma clang diagnostic pop
