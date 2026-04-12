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
}

- (void)dragCornerRadiusAtX:(double)positionX
                          y:(double)positionY
                  modifiers:(NSUInteger)modifiers
                forceUpdate:(BOOL *)forceUpdate {
  KKBezierPath *active = [self activePath];
  if (!active)
    return;

  simd_float2 bmin, bmax;
  [self boundsOfPath:active min:&bmin max:&bmax];
  float ddx = (float)(self.dragAnchor.x - positionX);
  float ddy = (float)(self.dragAnchor.y - positionY);
  NSInteger ci = self.dragCornerIndex;
  if (ci == 0 || ci == 3)
    ddx = -ddx;
  if (ci == 2 || ci == 3)
    ddy = -ddy;
  float delta = (ddx + ddy) * 0.5f;

  CGPoint cMin = [self canvasPointFromObjectPoint:bmin];
  CGPoint cMax = [self canvasPointFromObjectPoint:bmax];
  float canvasW = (float)fabs(cMax.x - cMin.x);
  float canvasH = (float)fabs(cMax.y - cMin.y);
  float halfShort = fminf(canvasW, canvasH) * 0.5f;
  float inset = (float)[self strokeWidth] * 0.5f + 20.0f;
  float travel = fminf(100.0f, fmaxf(1.0f, halfShort - inset));
  float rawFraction = self.dragStartPixelRadius + delta / travel;

  float sw = (float)[self strokeWidth];
  float maxPx = fmaxf(canvasW, canvasH) * 0.5f;
  float minFraction = (maxPx > 0.0001f) ? (sw * 1.15f) / maxPx : 0;
  float snapThreshold = minFraction * 0.5f;
  float fraction;
  if (rawFraction < snapThreshold)
    fraction = 0.0f;
  else
    fraction = fmaxf(minFraction, fminf(1.0f, rawFraction));

  BOOL optHeld = (modifiers & kFxModifierKey_OPTION) != 0;
  float ftl = optHeld ? active.cornerRadiusTL : fraction;
  float ftr = optHeld ? active.cornerRadiusTR : fraction;
  float fbr = optHeld ? active.cornerRadiusBR : fraction;
  float fbl = optHeld ? active.cornerRadiusBL : fraction;
  if (optHeld) {
    switch (ci) {
    case 0:
      ftl = fraction;
      break;
    case 1:
      ftr = fraction;
      break;
    case 2:
      fbr = fraction;
      break;
    case 3:
      fbl = fraction;
      break;
    }
  }

  [active setRoundedRectWithMin:bmin
                            max:bmax
                     fractionTL:ftl
                     fractionTR:ftr
                     fractionBR:fbr
                     fractionBL:fbl
                    canvasWidth:canvasW
                   canvasHeight:canvasH];
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
  if (self.dragIsRect) {
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
  BOOL optDown = (modifiers & kFxModifierKey_OPTION) != 0;

  CGFloat minX = MIN(self.marqueeStart.x, self.marqueeEnd.x);
  CGFloat maxX = MAX(self.marqueeStart.x, self.marqueeEnd.x);
  CGFloat minY = MIN(self.marqueeStart.y, self.marqueeEnd.y);
  CGFloat maxY = MAX(self.marqueeStart.y, self.marqueeEnd.y);

  if (maxX - minX < 2.0 && maxY - minY < 2.0)
    return;

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
  [self.paths addObject:rect];
  self.activePathIndex = (NSInteger)self.paths.count - 1;
  [self writePaths:self.paths];
}

- (void)resetDragState {
  self.dragIndex = -1;
  self.dragIsInHandle = NO;
  self.dragIsOutHandle = NO;
  self.dragIsNewPoint = NO;
  self.dragIsPath = NO;
  self.dragIsMarquee = NO;
  self.dragIsSelection = NO;
  self.dragIsRect = NO;
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
    self.activePathIndex = -1;
    self.toolbar.activeTag = kOSCToolbarCursor;
    *forceUpdate = YES;
    *didHandle = YES;
    return;
  }

  if (asciiKey != 127 && asciiKey != 8)
    return;

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

@end
#pragma clang diagnostic pop
