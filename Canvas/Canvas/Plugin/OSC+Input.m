/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (Input)

- (void)setHandle:(simd_float2)offset
          atIndex:(NSInteger)idx
             isIn:(BOOL)isIn
    breakSymmetry:(BOOL)breakSymmetry
           onPath:(KKBezierPath *)path {
  if (isIn) {
    [path setInHandle:offset atIndex:idx];
    if (!breakSymmetry)
      [path setOutHandle:(simd_float2){-offset.x, -offset.y} atIndex:idx];
  } else {
    [path setOutHandle:offset atIndex:idx];
    if (!breakSymmetry)
      [path setInHandle:(simd_float2){-offset.x, -offset.y} atIndex:idx];
  }
  [path setType:KKBezierPointBezier atIndex:idx];
}

- (void)toggleBezierAtIndex:(NSInteger)idx onPath:(KKBezierPath *)path {
  KKBezierPoint pt = [path pointAtIndex:idx];
  if (pt.type == KKBezierPointBezier) {
    [path setType:KKBezierPointLinear atIndex:idx];
    [path setInHandle:(simd_float2){0, 0} atIndex:idx];
    [path setOutHandle:(simd_float2){0, 0} atIndex:idx];
  } else {
    simd_float2 pos = {pt.x, pt.y}, prev = pos, next = pos;
    if (idx > 0) {
      KKBezierPoint pp = [path pointAtIndex:idx - 1];
      prev = (simd_float2){pp.x, pp.y};
    }
    if (idx + 1 < (NSInteger)path.count) {
      KKBezierPoint np = [path pointAtIndex:idx + 1];
      next = (simd_float2){np.x, np.y};
    }
    simd_float2 dir = (next - prev) * 0.25f;
    [path setOutHandle:dir atIndex:idx];
    [path setInHandle:(simd_float2){-dir.x, -dir.y} atIndex:idx];
    [path setType:KKBezierPointBezier atIndex:idx];
  }
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  // Toolbar button
  if (activePart == kOSCToolbarCursor || activePart == kOSCToolbarPen ||
      activePart == kOSCToolbarRect) {
    self.toolbar.activeTag = activePart;
    *forceUpdate = YES;
    return;
  }
  // Toolbar background (between buttons) — no-op
  if (activePart == -1)
    return;

  self.paths = [self readPaths];
  KKBezierPath *active = [self activePath];
  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  BOOL isPenMode = (self.toolbar.activeTag == kOSCToolbarPen);
  BOOL isRectMode = (self.toolbar.activeTag == kOSCToolbarRect);

  // Close path: allow drag to adjust first point's in-handle
  if (activePart == kOSCClosePath && active) {
    active.closed = YES;
    [self writePaths:self.paths];
    self.dragIndex = 0;
    self.dragIsInHandle = YES;
    self.dragIsOutHandle = NO;
    *forceUpdate = YES;
    return;
  }

  // Option-click on point: delete
  if (activePart >= kOSCPathPointBase && activePart < kOSCInHandleBase &&
      (modifiers & kFxModifierKey_OPTION) && active) {
    NSInteger idx = activePart - kOSCPathPointBase;
    if (idx >= 0 && idx < (NSInteger)active.count) {
      [active removeAtIndex:idx];
      if (active.count < 2) {
        [self.paths removeObjectAtIndex:self.activePathIndex];
        self.activePathIndex = -1;
      }
      [self writePaths:self.paths];
    }
    *forceUpdate = YES;
    return;
  }

  // Click on point: drag or double-click toggle
  if (activePart >= kOSCPathPointBase && activePart < kOSCInHandleBase &&
      active) {
    NSInteger idx = activePart - kOSCPathPointBase;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

    if (self.lastClickIndex == idx && (now - self.lastClickTime) < 0.35) {
      [self toggleBezierAtIndex:idx onPath:active];
      [self writePaths:self.paths];
      self.lastClickIndex = -1;
      *forceUpdate = YES;
      return;
    }

    self.lastClickTime = now;
    self.lastClickIndex = idx;
    self.dragIndex = idx;
    self.dragIsInHandle = NO;
    self.dragIsOutHandle = NO;
    KKBezierPoint dragPt = [active pointAtIndex:idx];
    self.dragOrigin = (simd_float2){dragPt.x, dragPt.y};
    self.dragAnchor = self.dragOrigin;
    *forceUpdate = YES;
    return;
  }

  // Drag handles
  if (activePart >= kOSCInHandleBase && activePart < kOSCOutHandleBase) {
    self.dragIndex = activePart - kOSCInHandleBase;
    self.dragIsInHandle = YES;
    self.dragIsOutHandle = NO;
    *forceUpdate = YES;
    return;
  }
  if (activePart >= kOSCOutHandleBase && activePart < kOSCPathSegmentBase) {
    self.dragIndex = activePart - kOSCOutHandleBase;
    self.dragIsInHandle = NO;
    self.dragIsOutHandle = YES;
    *forceUpdate = YES;
    return;
  }

  // Corner radius drag — record starting state
  if (activePart == kOSCCornerRadius && active) {
    self.dragIndex = -2; // sentinel for corner radius drag
    self.dragAnchor = (simd_float2){(float)positionX, (float)positionY};
    // Compute current pixel radius from stored cornerRadius
    simd_float2 bmin, bmax;
    [self boundsOfPath:active min:&bmin max:&bmax];
    CGPoint minC = [self canvasPointFromObjectPoint:bmin];
    CGPoint maxC = [self canvasPointFromObjectPoint:bmax];
    float canvasH = (float)fabs(maxC.y - minC.y);
    float objH = bmax.y - bmin.y;
    float storedPixelR =
        (objH > 0.0001f) ? (active.cornerRadius / objH) * canvasH : 0;
    // The inset position represents radius=0 visually, so offset accordingly
    float inset = (float)[self strokeWidth] * 0.5f + 20.0f;
    float insetPixelR = inset * 1.4142135624f;
    self.dragStartPixelRadius = storedPixelR + insetPixelR;
    *forceUpdate = YES;
    return;
  }

  // Insert on segment (pen mode)
  if (activePart >= kOSCPathSegmentBase && isPenMode && active) {
    NSInteger segIdx = activePart - kOSCPathSegmentBase;
    simd_float2 objPos =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    [active insertAtIndex:segIdx + 1 position:objPos];
    [self writePaths:self.paths];
    self.dragIndex = segIdx + 1;
    self.dragIsInHandle = NO;
    self.dragIsOutHandle = NO;
    *forceUpdate = YES;
    return;
  }

  // Cursor mode
  if (isCursorMode) {
    [self handleCursorMouseDownX:positionX
                               y:positionY
                       modifiers:modifiers
                     forceUpdate:forceUpdate];
    return;
  }

  // Pen mode + Cmd: temporary cursor mode (select, drag, marquee)
  if (isPenMode && (modifiers & kFxModifierKey_COMMAND)) {
    [self handleCursorMouseDownX:positionX
                               y:positionY
                       modifiers:modifiers
                     forceUpdate:forceUpdate];
    return;
  }

  // Pen mode: add point or start new path
  if (isPenMode) {
    [self handlePenMouseDownX:positionX
                            y:positionY
                       active:active
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time
                   activePart:activePart];
    return;
  }

  // Rectangle mode: start drawing rect
  if (isRectMode) {
    simd_float2 objPos =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    self.rectStart = objPos;
    self.dragOrigin = objPos;
    self.dragIsRect = YES;
    *forceUpdate = YES;
  }
}

- (void)handleCursorMouseDownX:(double)positionX
                             y:(double)positionY
                     modifiers:(NSUInteger)modifiers
                   forceUpdate:(BOOL *)forceUpdate {
  BOOL shiftDown = (modifiers & kFxModifierKey_SHIFT) != 0;
  BOOL optDown = (modifiers & kFxModifierKey_OPTION) != 0;

  // Click on a selected point → drag selection
  if (self.selectedPoints.count > 0) {
    for (NSUInteger p = 0; p < self.paths.count; p++) {
      KKBezierPath *path = self.paths[p];
      for (NSUInteger i = 0; i < path.count; i++) {
        if (![self isPointSelected:p point:i])
          continue;
        KKBezierPoint pt = [path pointAtIndex:i];
        CGPoint ptCanvas = [self canvasPointForBezierPoint:pt];
        if (hypot(positionX - ptCanvas.x, positionY - ptCanvas.y) < 12.0) {
          self.dragIsSelection = YES;
          simd_float2 clickObj = [self
              objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
          self.dragOrigin = clickObj;
          self.dragAnchor = clickObj;
          *forceUpdate = YES;
          return;
        }
      }
    }
  }

  // Click near a path
  double hitRadiusStroke = [self strokeHitRadius];
  NSInteger nearPath = [self pathIndexNearX:positionX
                                          y:positionY
                                     radius:hitRadiusStroke];
  if (nearPath >= 0) {
    KKBezierPath *hitPath = self.paths[nearPath];
    if (shiftDown) {
      for (NSUInteger i = 0; i < hitPath.count; i++)
        [self.selectedPoints addIndex:selKey(nearPath, i)];
      *forceUpdate = YES;
      return;
    } else if (optDown) {
      for (NSUInteger i = 0; i < hitPath.count; i++)
        [self.selectedPoints removeIndex:selKey(nearPath, i)];
      *forceUpdate = YES;
      return;
    }
    [self.selectedPoints removeAllIndexes];
    self.activePathIndex = nearPath;
    self.dragIsPath = YES;
    self.dragOrigin =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    *forceUpdate = YES;
    return;
  }

  // Empty space: start marquee
  if (!shiftDown && !optDown)
    [self.selectedPoints removeAllIndexes];
  self.activePathIndex = -1;
  self.dragIsMarquee = YES;
  self.marqueeStart = CGPointMake(positionX, positionY);
  self.marqueeEnd = self.marqueeStart;
  *forceUpdate = YES;
}

- (void)handlePenMouseDownX:(double)positionX
                          y:(double)positionY
                     active:(KKBezierPath *)active
                  modifiers:(NSUInteger)modifiers
                forceUpdate:(BOOL *)forceUpdate
                     atTime:(CMTime)time
                 activePart:(NSInteger)activePart {
  if (!active) {
    KKBezierPath *newPath = [[KKBezierPath alloc] init];
    [self.paths addObject:newPath];
    self.activePathIndex = (NSInteger)self.paths.count - 1;
    active = newPath;
  } else if (active.closed) {
    double hitRadiusStroke = [self strokeHitRadius];
    NSInteger segIdx = [self segmentIndexNearX:positionX
                                             y:positionY
                                        radius:hitRadiusStroke
                                        inPath:active];
    if (segIdx >= 0) {
      simd_float2 objPos =
          [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
      [active insertAtIndex:segIdx + 1 position:objPos];
      [self writePaths:self.paths];
      self.dragIndex = segIdx + 1;
      self.dragIsInHandle = NO;
      self.dragIsOutHandle = NO;
      *forceUpdate = YES;
      return;
    }
    KKBezierPath *newPath = [[KKBezierPath alloc] init];
    [self.paths addObject:newPath];
    self.activePathIndex = (NSInteger)self.paths.count - 1;
    active = newPath;
  }

  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  [active insertAtIndex:active.count position:objPos];
  [self writePaths:self.paths];

  self.dragIndex = (NSInteger)active.count - 1;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = NO;
  self.dragIsNewPoint = YES;

  *forceUpdate = YES;
  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
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

  // Rectangle tool: update preview (shift = square in pixel space)
  if (self.dragIsRect) {
    simd_float2 objPos =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    if (modifiers & kFxModifierKey_SHIFT) {
      // Work entirely in canvas pixel space for exact square
      CGPoint sc = [self canvasPointFromObjectPoint:self.rectStart];
      float dx = (float)(positionX - sc.x);
      float dy = (float)(positionY - sc.y);
      float side = roundf(fmaxf(fabsf(dx), fabsf(dy)));
      // Compute both corners snapped to pixel grid, then force equal size
      float sx = roundf((float)sc.x);
      float sy = roundf((float)sc.y);
      float ex = sx + copysignf(side, dx);
      float ey = sy + copysignf(side, dy);
      objPos = [self objectPointFromCanvasPoint:CGPointMake(ex, ey)];
    }
    self.dragOrigin = objPos;
    *forceUpdate = YES;
    return;
  }

  // Drag selected points
  if (self.dragIsSelection) {
    simd_float2 objPos =
        [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
    // Shift: constrain to dominant axis from initial click
    if (modifiers & kFxModifierKey_SHIFT) {
      simd_float2 totalDelta = objPos - self.dragAnchor;
      if (fabs(totalDelta.x) > fabs(totalDelta.y))
        objPos.y = self.dragAnchor.y;
      else
        objPos.x = self.dragAnchor.x;
    }
    simd_float2 delta = objPos - self.dragOrigin;
    self.dragOrigin = objPos;
    for (NSUInteger p = 0; p < self.paths.count; p++) {
      KKBezierPath *path = self.paths[p];
      for (NSUInteger i = 0; i < path.count; i++) {
        if ([self isPointSelected:p point:i]) {
          KKBezierPoint pt = [path pointAtIndex:i];
          [path moveAtIndex:i to:(simd_float2){pt.x + delta.x, pt.y + delta.y}];
        }
      }
    }
    [self writePaths:self.paths];
    *forceUpdate = YES;
    return;
  }

  KKBezierPath *active = [self activePath];
  if (!active)
    return;

  simd_float2 objPos =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];

  // Corner radius drag — use delta from start for smooth dragging
  if (self.dragIndex == -2) {
    simd_float2 min, max;
    [self boundsOfPath:active min:&min max:&max];
    // Diagonal delta from drag start in canvas space
    float ddx = (float)(self.dragAnchor.x - positionX);
    float ddy = (float)(self.dragAnchor.y - positionY);
    // Project onto diagonal (inward = positive)
    float diagDelta = (ddx + ddy) * 0.7071067812f;
    float inset = (float)[self strokeWidth] * 0.5f + 20.0f;
    float insetPixelR = inset * 1.4142135624f;
    float pixelR =
        fmaxf(0.0f, self.dragStartPixelRadius + diagDelta - insetPixelR);
    // Convert pixel radius to object-space rx and ry
    CGPoint minCanvas = [self canvasPointFromObjectPoint:min];
    CGPoint maxCanvas = [self canvasPointFromObjectPoint:max];
    float canvasW = (float)fabs(maxCanvas.x - minCanvas.x);
    float canvasH = (float)fabs(maxCanvas.y - minCanvas.y);
    float objW = max.x - min.x;
    float objH = max.y - min.y;
    float rx = (canvasW > 0.0001f) ? (pixelR / canvasW) * objW : 0;
    float ry = (canvasH > 0.0001f) ? (pixelR / canvasH) * objH : 0;
    [active setRoundedRectWithMin:min max:max radiusX:rx radiusY:ry];
    [self writePaths:self.paths];
    *forceUpdate = YES;
    return;
  }

  // Whole-path drag
  if (self.dragIsPath) {
    simd_float2 delta = objPos - self.dragOrigin;
    [active translateBy:delta];
    self.dragOrigin = objPos;
    [self writePaths:self.paths];
    *forceUpdate = YES;
    return;
  }

  if (self.dragIndex < 0 || self.dragIndex >= (NSInteger)active.count)
    return;

  BOOL breakSymmetry = (modifiers & kFxModifierKey_OPTION) != 0;
  KKBezierPoint pt = [active pointAtIndex:self.dragIndex];
  simd_float2 offset = {objPos.x - pt.x, objPos.y - pt.y};

  if (self.dragIsNewPoint) {
    [self setHandle:offset
              atIndex:self.dragIndex
                 isIn:NO
        breakSymmetry:NO
               onPath:active];
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
    // Shift: constrain to dominant axis from initial position
    if (modifiers & kFxModifierKey_SHIFT) {
      simd_float2 totalDelta = objPos - self.dragAnchor;
      if (fabs(totalDelta.x) > fabs(totalDelta.y))
        objPos.y = self.dragAnchor.y;
      else
        objPos.x = self.dragAnchor.x;
    }
    [active moveAtIndex:self.dragIndex to:objPos];
  }

  [self writePaths:self.paths];
  *forceUpdate = YES;
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  if (self.dragIsMarquee) {
    self.marqueeEnd = CGPointMake(positionX, positionY);
    BOOL optDown = (modifiers & kFxModifierKey_OPTION) != 0;

    CGFloat minX = MIN(self.marqueeStart.x, self.marqueeEnd.x);
    CGFloat maxX = MAX(self.marqueeStart.x, self.marqueeEnd.x);
    CGFloat minY = MIN(self.marqueeStart.y, self.marqueeEnd.y);
    CGFloat maxY = MAX(self.marqueeStart.y, self.marqueeEnd.y);

    if (maxX - minX > 2.0 || maxY - minY > 2.0) {
      for (NSUInteger p = 0; p < self.paths.count; p++) {
        KKBezierPath *path = self.paths[p];
        for (NSUInteger i = 0; i < path.count; i++) {
          KKBezierPoint pt = [path pointAtIndex:i];
          CGPoint canvas = [self canvasPointForBezierPoint:pt];
          BOOL inside = (canvas.x >= minX && canvas.x <= maxX &&
                         canvas.y >= minY && canvas.y <= maxY);
          NSUInteger key = selKey(p, i);
          if (inside) {
            if (optDown)
              [self.selectedPoints removeIndex:key];
            else
              [self.selectedPoints addIndex:key];
          }
        }
      }
    }
  }

  // Finalize rectangle creation (use dragOrigin which has shift-square applied)
  if (self.dragIsRect) {
    simd_float2 a = self.rectStart;
    simd_float2 b = self.dragOrigin;
    float minX = fminf(a.x, b.x), maxX = fmaxf(a.x, b.x);
    float minY = fminf(a.y, b.y), maxY = fmaxf(a.y, b.y);

    // Only create if it has some size
    if (maxX - minX > 0.001f && maxY - minY > 0.001f) {
      KKBezierPath *rect = [[KKBezierPath alloc] init];
      [rect insertAtIndex:0 position:(simd_float2){minX, maxY}]; // top-left
      [rect insertAtIndex:1 position:(simd_float2){maxX, maxY}]; // top-right
      [rect insertAtIndex:2 position:(simd_float2){maxX, minY}]; // bottom-right
      [rect insertAtIndex:3 position:(simd_float2){minX, minY}]; // bottom-left
      rect.closed = YES;
      [self.paths addObject:rect];
      self.activePathIndex = (NSInteger)self.paths.count - 1;
      [self writePaths:self.paths];
    }
  }

  self.dragIndex = -1;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = NO;
  self.dragIsNewPoint = NO;
  self.dragIsPath = NO;
  self.dragIsMarquee = NO;
  self.dragIsSelection = NO;
  self.dragIsRect = NO;

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

  // Escape: clear selection, deselect, cursor mode
  if (asciiKey == 27) {
    [self.selectedPoints removeAllIndexes];
    self.activePathIndex = -1;
    self.toolbar.activeTag = kOSCToolbarCursor;
    *forceUpdate = YES;
    *didHandle = YES;
    return;
  }

  // Delete/Backspace
  if (asciiKey == 127 || asciiKey == 8) {
    self.paths = [self readPaths];

    if (isCursorMode && self.selectedPoints.count > 0) {
      for (NSInteger p = (NSInteger)self.paths.count - 1; p >= 0; p--) {
        KKBezierPath *path = self.paths[p];
        for (NSInteger i = (NSInteger)path.count - 1; i >= 0; i--) {
          if ([self isPointSelected:p point:i])
            [path removeAtIndex:i];
        }
        if (path.count < 2)
          [self.paths removeObjectAtIndex:p];
      }
      [self.selectedPoints removeAllIndexes];
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
}

@end
#pragma clang diagnostic pop
