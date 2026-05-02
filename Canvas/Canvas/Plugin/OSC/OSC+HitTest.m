/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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

  // Position-lane motion path (control points / handles / curves) sits
  // visually above the transform arc, so test it first.
  {
    NSInteger pathPart = [self hitTestPositionPathAtX:x y:y atTime:kCMTimeZero];
    if (pathPart != 0) {
      *activePart = pathPart;
      return;
    }
  }

  // Transform OSC overlays — top-most, highest hit priority. Each handle
  // is gated by its own multi-stage lane visibility, mirroring Position.
  self.transformPositionHovered = NO;
  self.scaleRingHovered = NO;
  self.anchorHovered = NO;
  self.rotZHovered = NO;
  if ([self isTransformPositionOSCVisibleAtTime:kCMTimeZero]) {
    CGPoint pos = [self transformPositionCanvasPointAtTime:kCMTimeZero];
    if (hypot(x - pos.x, y - pos.y) < self.transformPositionOSC.hitRadius) {
      self.transformPositionHovered = YES;
      *activePart = kOSCTransformPosition;
      [oscAPI setCursor:[NSCursor openHandCursor]];
      return;
    }
  }
  BOOL anchorVisible = [self isAnchorOSCVisibleAtTime:kCMTimeZero];
  BOOL scaleVisible = [self isScaleRingOSCVisibleAtTime:kCMTimeZero];
  BOOL rotZVisible = [self isRotZOSCVisibleAtTime:kCMTimeZero];
  if (anchorVisible || scaleVisible || rotZVisible) {
    CGPoint anchor = [self transformAnchorCanvasPointAtTime:kCMTimeZero];
    if (rotZVisible) {
      double rz = 0.0;
      id<FxParameterRetrievalAPI_v6> getAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      [getAPI getFloatValue:&rz
              fromParameter:kParamRotation
                     atTime:kCMTimeZero];
      self.rotZOSC.center = anchor;
      self.rotZOSC.angle = (float)rz;
      if ([self.rotZOSC hitTestAtMousePositionX:x
                                      positionY:y
                                         atTime:kCMTimeZero]) {
        self.rotZHovered = YES;
        *activePart = kOSCTransformRotZ;
        [oscAPI setCursor:[NSCursor crosshairCursor]];
        return;
      }
    }
    if (anchorVisible && hypot(x - anchor.x, y - anchor.y) < hitRadius) {
      self.anchorHovered = YES;
      *activePart = kOSCTransformAnchor;
      [oscAPI setCursor:[NSCursor openHandCursor]];
      return;
    }
    if (scaleVisible) {
      CGFloat rx = 0, ry = 0;
      [self getScaleRingRadiiAtTime:kCMTimeZero rx:&rx ry:&ry];
      CGFloat dx = (x - anchor.x) / rx;
      CGFloat dy = (y - anchor.y) / ry;
      CGFloat normalized = hypot(dx, dy);
      CGFloat distPx = fabs(normalized - 1.0) * MIN(rx, ry);
      if (rx > 0.5 && ry > 0.5 && distPx < hitRadius) {
        self.scaleRingHovered = YES;
        *activePart = kOSCTransformScaleRing;
        [oscAPI setCursor:[NSCursor crosshairCursor]];
        return;
      }
    }
  }

  __block BOOL allLocked = YES;
  [self.selectedPathIndices
      enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx < self.paths.count && !self.paths[idx].locked) {
          allLocked = NO;
          *stop = YES;
        }
      }];
  if (self.selectedPathIndices.count == 0)
    allLocked = NO;

  if (self.selectedPathIndices.count > 0 && !allLocked) {
    simd_float2 bmin, bmax;
    if ([self boundsOfSelectedPaths:&bmin max:&bmax]) {
      simd_float2 mouseObj =
          [self objectPointFromCanvasPoint:CGPointMake(x, y)];
      simd_float2 hitRef =
          [self objectPointFromCanvasPoint:CGPointMake(x + hitRadius, y)];
      double objHitR = fabs(hitRef.x - mouseObj.x);

      CGPoint bl = {bmin.x, bmin.y};
      CGPoint tr = {bmax.x, bmax.y};

      CGPoint topMid = [self resizeHandlePosition:1 topRight:tr bottomLeft:bl];
      simd_float2 hitRefY =
          [self objectPointFromCanvasPoint:CGPointMake(x, y + 20.0)];
      double obj20 = fabs(hitRefY.y - mouseObj.y);
      CGPoint rotatePos = {topMid.x, topMid.y + (float)obj20};
      if (hypot(mouseObj.x - rotatePos.x, mouseObj.y - rotatePos.y) < objHitR) {
        *activePart = kOSCRotateHandle;
        [oscAPI setCursor:self.editPointsCursor];
        return;
      }

      for (NSInteger i = 0; i < 8; i++) {
        CGPoint pos = [self resizeHandlePosition:i topRight:tr bottomLeft:bl];
        if (hypot(mouseObj.x - pos.x, mouseObj.y - pos.y) < objHitR) {
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
          if (active.isRect && !active.isImage) {
            NSInteger crParts[4] = {kOSCCornerRadiusTL, kOSCCornerRadiusTR,
                                    kOSCCornerRadiusBR, kOSCCornerRadiusBL};
            for (int ci = 0; ci < 4; ci++) {
              CGPoint crCanvas = [self cornerRadiusHandlePosition:ci
                                                          forPath:active];
              simd_float2 crObj = [self objectPointFromCanvasPoint:crCanvas];
              if (hypot(mouseObj.x - crObj.x, mouseObj.y - crObj.y) < objHitR) {
                *activePart = crParts[ci];
                [oscAPI setCursor:self.editPointsCursor];
                return;
              }
            }
          }
        }
      }

      BOOL insideBox = (mouseObj.x >= fminf(bmin.x, bmax.x) &&
                        mouseObj.x <= fmaxf(bmin.x, bmax.x) &&
                        mouseObj.y >= fminf(bmin.y, bmax.y) &&
                        mouseObj.y <= fmaxf(bmin.y, bmax.y));
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

  simd_float2 mouseObj = [self objectPointFromCanvasPoint:CGPointMake(x, y)];
  simd_float2 hitRef =
      [self objectPointFromCanvasPoint:CGPointMake(x + hitRadius, y)];
  double objHitR = fabs(hitRef.x - mouseObj.x);

  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optDown = (flags & kCGEventFlagMaskAlternate) != 0;
  BOOL shiftDown = (flags & kCGEventFlagMaskShift) != 0;
  BOOL cmdDown = (flags & kCGEventFlagMaskCommand) != 0;

  // Check handles and points on the active path first.
  if (active) {
    for (NSUInteger i = 0; i < active.count; i++) {
      KKBezierPoint pt = [active pointAtIndex:i];
      if (pt.type != KKBezierPointBezier)
        continue;

      simd_float2 inObj = {pt.x + pt.inX, pt.y + pt.inY};
      if (hypot(mouseObj.x - inObj.x, mouseObj.y - inObj.y) < objHitR) {
        *activePart = kOSCInHandleBase + (NSInteger)i;
        [oscAPI setCursor:self.editPointsCursor];
        return;
      }

      simd_float2 outObj = {pt.x + pt.outX, pt.y + pt.outY};
      if (hypot(mouseObj.x - outObj.x, mouseObj.y - outObj.y) < objHitR) {
        *activePart = kOSCOutHandleBase + (NSInteger)i;
        [oscAPI setCursor:self.editPointsCursor];
        return;
      }
    }

    for (NSUInteger i = 0; i < active.count; i++) {
      KKBezierPoint pt = [active pointAtIndex:i];
      if (hypot(mouseObj.x - pt.x, mouseObj.y - pt.y) < objHitR) {
        if (i == 0 && !active.closed && !active.isLine && active.count >= 2 &&
            !cmdDown) {
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

  // Check selected points on any path (including non-active). This allows
  // clicking marquee-selected points across multiple paths without needing
  // CMD to switch the active path first.
  if (self.selectedPoints.count > 0) {
    for (NSUInteger p = 0; p < self.paths.count; p++) {
      if ((NSInteger)p == self.activePathIndex)
        continue;
      KKBezierPath *path = self.paths[p];
      for (NSUInteger i = 0; i < path.count; i++) {
        if (![self isPointSelected:p point:i])
          continue;
        KKBezierPoint pt = [path pointAtIndex:i];
        if (hypot(mouseObj.x - pt.x, mouseObj.y - pt.y) < objHitR) {
          self.activePathIndex = (NSInteger)p;
          *activePart = kOSCPathPointBase + (NSInteger)i;
          [oscAPI setCursor:self.moveCursor];
          return;
        }
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
  self.hoverCanvasPosition = CGPointMake(positionX, positionY);
  self.paths = [self readPaths];

  {
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    BOOL autoSel = YES;
    [paramGetAPI getBoolValue:&autoSel
                fromParameter:kParamAutoSelect
                       atTime:kCMTimeZero];
    self.autoSelect = autoSel;
  }

  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

  NSInteger toolbarPart = [self.toolbar hitTestAtX:positionX y:positionY];
  if (toolbarPart != 0) {
    *activePart = toolbarPart;
    [oscAPI setCursor:[NSCursor arrowCursor]];
    return;
  }

  NSInteger gridPart = [self.gridToolbar hitTestAtX:positionX y:positionY];
  if (gridPart != 0) {
    *activePart = gridPart;
    [oscAPI setCursor:[NSCursor arrowCursor]];
    return;
  }

  // Path combine toolbar (only visible when 2+ non-image paths selected).
  NSInteger pathToolbarPart = [self.pathToolbar hitTestAtX:positionX
                                                         y:positionY];
  if (pathToolbarPart > 0) {
    self.hoveredPathOp = pathToolbarPart;
  } else {
    if (self.hoveredPathOp != 0) {
      self.hoveredPathOp = 0;
      self.previewResultPath = nil;
      self.previewTexture = nil;
      self.previewCachedOp = 0;
    }
  }
  if (pathToolbarPart != 0) {
    *activePart = pathToolbarPart;
    [oscAPI setCursor:[NSCursor arrowCursor]];
    return;
  }

  if (self.toolbar.activeTag == 0) {
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

  BOOL isLineMode = (self.toolbar.activeTag == kOSCToolbarLine);

  if (isRectMode || isEllipseMode || isLineMode) {
    [oscAPI setCursor:[NSCursor crosshairCursor]];
    return;
  }

  [self hitTestPenModeAtX:positionX y:positionY activePart:activePart];
}

@end
#pragma clang diagnostic pop
