/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (Drag)

- (simd_float2)shiftConstrainedPosition:(simd_float2)objPos {
  simd_float2 totalDelta = objPos - self.dragAnchor;
  if (fabs(totalDelta.x) > fabs(totalDelta.y))
    objPos.y = self.dragAnchor.y;
  else
    objPos.x = self.dragAnchor.x;
  return objPos;
}

- (void)dragRectToX:(double)positionX
                  y:(double)positionY
          modifiers:(NSUInteger)modifiers
        forceUpdate:(BOOL *)forceUpdate {
  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  if (modifiers & kFxModifierKey_SHIFT) {
    CGPoint sc = [self canvasPointFromObjectPoint:self.rectStart];
    float dx = (float)(positionX - sc.x);
    float dy = (float)(positionY - sc.y);
    float side = roundf(fmaxf(fabsf(dx), fabsf(dy)));
    float sx = roundf((float)sc.x);
    float sy = roundf((float)sc.y);
    float ex = sx + copysignf(side, dx);
    float ey = sy + copysignf(side, dy);
    objPos = [self objectPointFromCanvasPoint:CGPointMake(ex, ey)];
  }
  self.dragOrigin = objPos;
  *forceUpdate = YES;
}

- (void)dragLineToX:(double)positionX
                  y:(double)positionY
          modifiers:(NSUInteger)modifiers
        forceUpdate:(BOOL *)forceUpdate {
  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  if (modifiers & kFxModifierKey_SHIFT) {
    CGPoint sc = [self canvasPointFromObjectPoint:self.rectStart];
    float dx = (float)(positionX - sc.x);
    float dy = (float)(positionY - sc.y);
    float angle = atan2f(dy, dx);
    float snapped = roundf(angle / (M_PI / 4.0f)) * (M_PI / 4.0f);
    float dist = hypotf(dx, dy);
    float ex = (float)sc.x + dist * cosf(snapped);
    float ey = (float)sc.y + dist * sinf(snapped);
    objPos = [self objectPointFromCanvasPoint:CGPointMake(ex, ey)];
  }
  self.dragOrigin = objPos;
  *forceUpdate = YES;
}

- (void)dragSelectionToX:(double)positionX
                       y:(double)positionY
               modifiers:(NSUInteger)modifiers
             forceUpdate:(BOOL *)forceUpdate {
  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  if (modifiers & kFxModifierKey_SHIFT)
    objPos = [self shiftConstrainedPosition:objPos];
  simd_float2 delta = objPos - self.dragOrigin;
  self.dragOrigin = objPos;

  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  if (isCursorMode) {
    [self.selectedPathIndices
        enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
          if (idx < self.paths.count)
            [self.paths[idx] translateBy:delta];
        }];
  } else {
    for (NSUInteger p = 0; p < self.paths.count; p++) {
      KKBezierPath *path = self.paths[p];
      for (NSUInteger i = 0; i < path.count; i++) {
        if ([self isPointSelected:p point:i]) {
          KKBezierPoint pt = [path pointAtIndex:i];
          [path moveAtIndex:i to:(simd_float2){pt.x + delta.x, pt.y + delta.y}];
        }
      }
    }
  }
  [self writePaths:self.paths];
  *forceUpdate = YES;
}

- (void)dragPointOrHandleToX:(double)positionX
                           y:(double)positionY
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate {
  KKBezierPath *active = [self activePath];
  if (!active || self.dragIndex < 0 ||
      self.dragIndex >= (NSInteger)active.count)
    return;

  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  BOOL breakSymmetry = (modifiers & kFxModifierKey_OPTION) != 0;
  KKBezierPoint pt = [active pointAtIndex:self.dragIndex];
  simd_float2 offset = {objPos.x - pt.x, objPos.y - pt.y};

  if (self.dragIsNewPoint) {
    CGPoint ptCanvas =
        [self canvasPointFromObjectPoint:(simd_float2){pt.x, pt.y}];
    CGFloat canvasDist = hypot(positionX - ptCanvas.x, positionY - ptCanvas.y);
    if (canvasDist > 4.0) {
      [self setHandle:offset
                atIndex:self.dragIndex
                   isIn:NO
          breakSymmetry:NO
                 onPath:active];
    }
  } else if (self.dragIsInHandle) {
    [self setHandle:offset
              atIndex:self.dragIndex
                 isIn:YES
        breakSymmetry:breakSymmetry
               onPath:active];
  } else if (self.dragIsOutHandle) {
    [self setHandle:offset
              atIndex:self.dragIndex
                 isIn:NO
        breakSymmetry:breakSymmetry
               onPath:active];
  } else {
    if (modifiers & kFxModifierKey_SHIFT)
      objPos = [self shiftConstrainedPosition:objPos];
    [active moveAtIndex:self.dragIndex to:objPos];
  }

  [self writePaths:self.paths];
  *forceUpdate = YES;
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  if (self.dragIsMarquee) {
    self.marqueeEnd = CGPointMake(positionX, positionY);
    *forceUpdate = YES;
    return;
  }
  if (self.dragIsLine) {
    [self dragLineToX:positionX
                    y:positionY
            modifiers:modifiers
          forceUpdate:forceUpdate];
    return;
  }
  if (self.dragIsRect || self.dragIsEllipse) {
    [self dragRectToX:positionX
                    y:positionY
            modifiers:modifiers
          forceUpdate:forceUpdate];
    return;
  }
  if (self.dragIsSelection) {
    [self dragSelectionToX:positionX
                         y:positionY
                 modifiers:modifiers
               forceUpdate:forceUpdate];
    return;
  }
  if (self.dragIndex == -2) {
    [self dragCornerRadiusAtX:positionX
                            y:positionY
                    modifiers:modifiers
                  forceUpdate:forceUpdate];
    return;
  }
  if (self.dragResizeHandle >= 0) {
    [self dragResizeAtX:positionX
                      y:positionY
              modifiers:modifiers
            forceUpdate:forceUpdate];
    return;
  }
  if (self.dragIsPath) {
    KKBezierPath *active = [self activePath];
    if (!active)
      return;
    simd_float2 objPos =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    simd_float2 delta = objPos - self.dragOrigin;
    [active translateBy:delta];
    self.dragOrigin = objPos;
    [self writePaths:self.paths];
    *forceUpdate = YES;
    return;
  }
  [self dragPointOrHandleToX:positionX
                           y:positionY
                   modifiers:modifiers
                 forceUpdate:forceUpdate];
}

- (void)finalizeMarqueeAtX:(double)positionX
                         y:(double)positionY
                 modifiers:(NSUInteger)modifiers {
  self.marqueeEnd = CGPointMake(positionX, positionY);

  CGFloat minX = MIN(self.marqueeStart.x, self.marqueeEnd.x);
  CGFloat maxX = MAX(self.marqueeStart.x, self.marqueeEnd.x);
  CGFloat minY = MIN(self.marqueeStart.y, self.marqueeEnd.y);
  CGFloat maxY = MAX(self.marqueeStart.y, self.marqueeEnd.y);

  if (maxX - minX < 2.0 && maxY - minY < 2.0)
    return;

  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);

  if (isCursorMode) {
    for (NSUInteger p = 0; p < self.paths.count; p++) {
      KKBezierPath *path = self.paths[p];
      if (path.count == 0)
        continue;
      simd_float2 bmin, bmax;
      [self boundsOfPath:path min:&bmin max:&bmax];
      CGPoint bl = [self canvasPointFromObjectPoint:bmin];
      CGPoint tr = [self canvasPointFromObjectPoint:bmax];
      CGFloat pMinX = MIN(bl.x, tr.x), pMaxX = MAX(bl.x, tr.x);
      CGFloat pMinY = MIN(bl.y, tr.y), pMaxY = MAX(bl.y, tr.y);
      BOOL fullyInside =
          (pMinX >= minX && pMaxX <= maxX && pMinY >= minY && pMaxY <= maxY);
      if (fullyInside) {
        [self.selectedPathIndices addIndex:p];
        self.activePathIndex = (NSInteger)p;
      }
    }
    return;
  }

  BOOL optDown = (modifiers & kFxModifierKey_OPTION) != 0;
  for (NSUInteger p = 0; p < self.paths.count; p++) {
    KKBezierPath *path = self.paths[p];
    for (NSUInteger i = 0; i < path.count; i++) {
      KKBezierPoint pt = [path pointAtIndex:i];
      CGPoint canvas = [self canvasPointForBezierPoint:pt];
      BOOL inside = (canvas.x >= minX && canvas.x <= maxX && canvas.y >= minY &&
                     canvas.y <= maxY);
      if (!inside)
        continue;
      NSUInteger key = selKey(p, i);
      if (optDown)
        [self.selectedPoints removeIndex:key];
      else
        [self.selectedPoints addIndex:key];
    }
  }
}

- (void)finalizeRect {
  simd_float2 a = self.rectStart;
  simd_float2 b = self.dragOrigin;
  float minX = fminf(a.x, b.x), maxX = fmaxf(a.x, b.x);
  float minY = fminf(a.y, b.y), maxY = fmaxf(a.y, b.y);
  if (maxX - minX < 0.001f || maxY - minY < 0.001f)
    return;

  KKBezierPath *rect = [[KKBezierPath alloc] init];
  [rect insertAtIndex:0 position:(simd_float2){minX, maxY}];
  [rect insertAtIndex:1 position:(simd_float2){maxX, maxY}];
  [rect insertAtIndex:2 position:(simd_float2){maxX, minY}];
  [rect insertAtIndex:3 position:(simd_float2){minX, minY}];
  rect.closed = YES;
  rect.isRect = YES;
  [self.paths addObject:rect];
  self.activePathIndex = (NSInteger)self.paths.count - 1;
  [self.selectedPathIndices removeAllIndexes];
  [self.selectedPathIndices addIndex:self.activePathIndex];
  [self writePaths:self.paths];
}

- (void)finalizeEllipse {
  simd_float2 a = self.rectStart;
  simd_float2 b = self.dragOrigin;
  float minX = fminf(a.x, b.x), maxX = fmaxf(a.x, b.x);
  float minY = fminf(a.y, b.y), maxY = fmaxf(a.y, b.y);
  if (maxX - minX < 0.001f || maxY - minY < 0.001f)
    return;

  float cx = (minX + maxX) * 0.5f, cy = (minY + maxY) * 0.5f;
  float rx = (maxX - minX) * 0.5f, ry = (maxY - minY) * 0.5f;
  float kx = rx * 0.5522847498f, ky = ry * 0.5522847498f;

  KKBezierPath *ellipse = [[KKBezierPath alloc] init];
  [ellipse insertAtIndex:0 position:(simd_float2){cx, cy + ry}]; // top
  [ellipse insertAtIndex:1 position:(simd_float2){cx + rx, cy}]; // right
  [ellipse insertAtIndex:2 position:(simd_float2){cx, cy - ry}]; // bottom
  [ellipse insertAtIndex:3 position:(simd_float2){cx - rx, cy}]; // left

  [ellipse setOutHandle:(simd_float2){kx, 0} atIndex:0];
  [ellipse setInHandle:(simd_float2){-kx, 0} atIndex:0];
  [ellipse setType:KKBezierPointBezier atIndex:0];

  [ellipse setOutHandle:(simd_float2){0, -ky} atIndex:1];
  [ellipse setInHandle:(simd_float2){0, ky} atIndex:1];
  [ellipse setType:KKBezierPointBezier atIndex:1];

  [ellipse setOutHandle:(simd_float2){-kx, 0} atIndex:2];
  [ellipse setInHandle:(simd_float2){kx, 0} atIndex:2];
  [ellipse setType:KKBezierPointBezier atIndex:2];

  [ellipse setOutHandle:(simd_float2){0, ky} atIndex:3];
  [ellipse setInHandle:(simd_float2){0, -ky} atIndex:3];
  [ellipse setType:KKBezierPointBezier atIndex:3];

  ellipse.closed = YES;
  [self.paths addObject:ellipse];
  self.activePathIndex = (NSInteger)self.paths.count - 1;
  [self.selectedPathIndices removeAllIndexes];
  [self.selectedPathIndices addIndex:self.activePathIndex];
  [self writePaths:self.paths];
}

- (void)finalizeLine {
  simd_float2 a = self.rectStart;
  simd_float2 b = self.dragOrigin;
  if (fabs(a.x - b.x) < 0.001f && fabs(a.y - b.y) < 0.001f)
    return;

  KKBezierPath *line = [[KKBezierPath alloc] init];
  [line insertAtIndex:0 position:a];
  [line insertAtIndex:1 position:b];
  [self.paths addObject:line];
  NSInteger lineIdx = (NSInteger)self.paths.count - 1;
  self.activePathIndex = -1;
  [self.selectedPathIndices removeAllIndexes];
  [self.selectedPathIndices addIndex:lineIdx];
  [self writePaths:self.paths];
}

- (void)resetDragState {
  self.dragIndex = -1;
  self.dragResizeHandle = -1;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = NO;
  self.dragIsNewPoint = NO;
  self.dragIsPath = NO;
  self.dragIsMarquee = NO;
  self.dragIsSelection = NO;
  self.dragIsRect = NO;
  self.dragIsEllipse = NO;
  self.dragIsLine = NO;
  self.resizeOrigSnapshots = nil;
  self.resizeOrigIndices = nil;
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  if (self.dragIsMarquee)
    [self finalizeMarqueeAtX:positionX y:positionY modifiers:modifiers];
  if (self.dragIsRect)
    [self finalizeRect];
  if (self.dragIsEllipse)
    [self finalizeEllipse];
  if (self.dragIsLine)
    [self finalizeLine];

  [self resetDragState];
  *forceUpdate = YES;
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

- (void)keyDownAtPositionX:(double)positionX
                 positionY:(double)positionY
                keyPressed:(unsigned short)asciiKey
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                 didHandle:(BOOL *)didHandle
                    atTime:(CMTime)time {
  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);

  if (asciiKey == 27) {
    [self.selectedPoints removeAllIndexes];
    [self.selectedPathIndices removeAllIndexes];
    self.activePathIndex = -1;
    self.toolbar.activeTag = kOSCToolbarCursor;
    *forceUpdate = YES;
    *didHandle = YES;
    return;
  }

  if (asciiKey != 127 && asciiKey != 8)
    return;

  self.paths = [self readPaths];

  if (isCursorMode && self.selectedPathIndices.count > 0) {
    [self.selectedPathIndices
        enumerateIndexesWithOptions:NSEnumerationReverse
                         usingBlock:^(NSUInteger idx, BOOL *stop) {
                           if (idx < self.paths.count)
                             [self.paths removeObjectAtIndex:idx];
                         }];
    [self.selectedPathIndices removeAllIndexes];
    self.activePathIndex = -1;
    [self writePaths:self.paths];
    *forceUpdate = YES;
    *didHandle = YES;
    return;
  }

  KKBezierPath *active = [self activePath];
  if (!active)
    return;

  if (isCursorMode) {
    [self.paths removeObjectAtIndex:self.activePathIndex];
    [self.selectedPathIndices removeAllIndexes];
    self.activePathIndex = -1;
    [self writePaths:self.paths];
    *forceUpdate = YES;
    *didHandle = YES;
  } else if (active.count > 0) {
    [active removeAtIndex:active.count - 1];
    if (active.count < 2) {
      [self.paths removeObjectAtIndex:self.activePathIndex];
      self.activePathIndex = -1;
    }
    [self writePaths:self.paths];
    *forceUpdate = YES;
    *didHandle = YES;
  }
}

@end
#pragma clang diagnostic pop
