/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (HitTest)

- (void)hitTestCursorModeAtX:(double)x
                           y:(double)y
                  activePart:(NSInteger *)activePart {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  double hitRadius = 12.0;

  if (self.selectedPathIndices.count > 0) {
    simd_float2 bmin, bmax;
    if ([self boundsOfSelectedPaths:&bmin max:&bmax]) {
      CGPoint bl = [self canvasPointFromObjectPoint:bmin];
      CGPoint tr = [self canvasPointFromObjectPoint:bmax];

      for (NSInteger i = 0; i < 8; i++) {
        CGPoint pos = [self resizeHandlePosition:i topRight:tr bottomLeft:bl];
        if (hypot(x - pos.x, y - pos.y) < hitRadius) {
          *activePart = kOSCResizeHandleBase + i;
          BOOL isEdge = (i % 2 == 1);
          if (isEdge)
            [oscAPI setCursor:(i == 1 || i == 5)
                                  ? [NSCursor resizeUpDownCursor]
                                  : [NSCursor resizeLeftRightCursor]];
          else
            [oscAPI setCursor:self.editPointsCursor];
          return;
        }
      }

      if (self.selectedPathIndices.count == 1) {
        NSUInteger idx = self.selectedPathIndices.firstIndex;
        if (idx < self.paths.count) {
          KKBezierPath *active = self.paths[idx];
          BOOL hasLinear = NO;
          for (NSUInteger li = 0; li < active.count; li++) {
            if ([active pointAtIndex:li].type == KKBezierPointLinear) {
              hasLinear = YES;
              break;
            }
          }
          if (active.closed && active.count >= 4 && hasLinear) {
            NSInteger crParts[4] = {kOSCCornerRadiusTL, kOSCCornerRadiusTR,
                                    kOSCCornerRadiusBR, kOSCCornerRadiusBL};
            for (int ci = 0; ci < 4; ci++) {
              CGPoint crPos = [self cornerRadiusHandlePosition:ci
                                                       forPath:active];
              if (hypot(x - crPos.x, y - crPos.y) < hitRadius) {
                *activePart = crParts[ci];
                [oscAPI setCursor:self.editPointsCursor];
                return;
              }
            }
          }
        }
      }

      BOOL insideBox = (x >= MIN(bl.x, tr.x) && x <= MAX(bl.x, tr.x) &&
                        y >= MIN(bl.y, tr.y) && y <= MAX(bl.y, tr.y));
      if (insideBox) {
        *activePart = kOSCBoundingBox;
        [oscAPI setCursor:self.moveCursor];
        return;
      }
    }
  }

  double hitRadiusStroke = [self strokeHitRadius];
  NSInteger nearPath = [self pathIndexNearX:x y:y radius:hitRadiusStroke];
  if (nearPath >= 0) {
    *activePart = kOSCCanvas;
    [oscAPI setCursor:[NSCursor arrowCursor]];
    return;
  }

  [oscAPI setCursor:[NSCursor arrowCursor]];
}

- (void)hitTestPenModeAtX:(double)x
                        y:(double)y
               activePart:(NSInteger *)activePart {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  double hitRadius = 12.0;
  KKBezierPath *active = [self activePath];

  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optDown = (flags & kCGEventFlagMaskAlternate) != 0;
  BOOL shiftDown = (flags & kCGEventFlagMaskShift) != 0;
  BOOL cmdDown = (flags & kCGEventFlagMaskCommand) != 0;

  if (active) {
    for (NSUInteger i = 0; i < active.count; i++) {
      KKBezierPoint pt = [active pointAtIndex:i];
      if (pt.type != KKBezierPointBezier)
        continue;

      CGPoint inCanvas = [self canvasPointForBezierPoint:pt inHandleOffset:YES];
      if (hypot(x - inCanvas.x, y - inCanvas.y) < hitRadius) {
        *activePart = kOSCInHandleBase + (NSInteger)i;
        [oscAPI setCursor:self.editPointsCursor];
        return;
      }

      CGPoint outCanvas = [self canvasPointForBezierPoint:pt inHandleOffset:NO];
      if (hypot(x - outCanvas.x, y - outCanvas.y) < hitRadius) {
        *activePart = kOSCOutHandleBase + (NSInteger)i;
        [oscAPI setCursor:self.editPointsCursor];
        return;
      }
    }

    for (NSUInteger i = 0; i < active.count; i++) {
      KKBezierPoint pt = [active pointAtIndex:i];
      CGPoint ptCanvas = [self canvasPointForBezierPoint:pt];
      if (hypot(x - ptCanvas.x, y - ptCanvas.y) < hitRadius) {
        if (i == 0 && !active.closed && active.count >= 2) {
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

  if (cmdDown) {
    NSInteger nearPath = [self pathIndexNearX:x y:y radius:hitRadiusStroke];
    if (nearPath >= 0) {
      *activePart = kOSCCanvas;
      [oscAPI setCursor:[NSCursor arrowCursor]];
      return;
    }
    if (self.selectedPoints.count > 0 && shiftDown)
      [oscAPI setCursor:[NSCursor dragCopyCursor]];
    else if (self.selectedPoints.count > 0 && optDown)
      [oscAPI setCursor:[NSCursor operationNotAllowedCursor]];
    else
      [oscAPI setCursor:[NSCursor crosshairCursor]];
    return;
  }

  if (active && active.count >= 2) {
    NSInteger segIdx = [self segmentIndexNearX:x
                                             y:y
                                        radius:hitRadiusStroke
                                        inPath:active];
    if (segIdx >= 0) {
      *activePart = kOSCPathSegmentBase + segIdx;
      [oscAPI setCursor:self.penAddCursor];
      return;
    }
  }

  [oscAPI setCursor:self.penAddCursor];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = kOSCCanvas;
  self.paths = [self readPaths];

  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

  NSInteger toolbarPart = [self.toolbar hitTestAtX:positionX y:positionY];
  if (toolbarPart != 0) {
    *activePart = toolbarPart;
    [oscAPI setCursor:[NSCursor arrowCursor]];
    return;
  }

  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  BOOL isRectMode = (self.toolbar.activeTag == kOSCToolbarRect);
  BOOL isEllipseMode = (self.toolbar.activeTag == kOSCToolbarEllipse);

  if (isCursorMode) {
    [self hitTestCursorModeAtX:positionX y:positionY activePart:activePart];
    return;
  }

  if (isRectMode || isEllipseMode) {
    [oscAPI setCursor:[NSCursor crosshairCursor]];
    return;
  }

  [self hitTestPenModeAtX:positionX y:positionY activePart:activePart];
}

@end
#pragma clang diagnostic pop
