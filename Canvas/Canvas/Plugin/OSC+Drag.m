/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"

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
    if ((modifiers & kFxModifierKey_OPTION) && !self.dragDidDuplicate) {
      self.dragDidDuplicate = YES;
      NSMutableIndexSet *expanded = [self.selectedPathIndices mutableCopy];
      [self.selectedPathIndices
          enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            if (idx < self.paths.count && self.paths[idx].isGroup)
              [expanded addIndexes:KKDescendantIndices(idx, self.paths)];
          }];
      NSMutableIndexSet *newIndices = [NSMutableIndexSet indexSet];
      NSMutableDictionary<NSString *, NSString *> *groupIDMap =
          [NSMutableDictionary dictionary];
      [expanded enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx >= self.paths.count || self.paths[idx].locked)
          return;
        KKBezierPath *clone =
            [KKBezierPath pathWithData:[self.paths[idx] dataRepresentation]];
        if (clone.isGroup && clone.groupID) {
          NSString *newID = [[NSUUID UUID] UUIDString];
          groupIDMap[clone.groupID] = newID;
          clone.groupID = newID;
        }
        if (clone.parentGroupID && groupIDMap[clone.parentGroupID])
          clone.parentGroupID = groupIDMap[clone.parentGroupID];
        [self.paths addObject:clone];
        if ([self.selectedPathIndices containsIndex:idx])
          [newIndices addIndex:self.paths.count - 1];
      }];
      [self.selectedPathIndices removeAllIndexes];
      [self.selectedPathIndices addIndexes:newIndices];
      self.activePathIndex = (NSInteger)newIndices.lastIndex;
    }
    [self.selectedPathIndices
        enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
          if (idx < self.paths.count && !self.paths[idx].locked)
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
    NSUInteger dragKey =
        selKey((NSUInteger)self.activePathIndex, (NSUInteger)self.dragIndex);
    if (self.selectedPoints.count > 1 &&
        [self.selectedPoints containsIndex:dragKey]) {
      simd_float2 delta = {objPos.x - pt.x, objPos.y - pt.y};
      [self.selectedPoints
          enumerateIndexesUsingBlock:^(NSUInteger sk, BOOL *stop) {
            NSUInteger pi = sk / 100000;
            NSUInteger pti = sk % 100000;
            if (pi >= self.paths.count)
              return;
            KKBezierPath *p = self.paths[pi];
            if (pti >= p.count)
              return;
            p.isRect = NO;
            KKBezierPoint sp = [p pointAtIndex:pti];
            simd_float2 newPos = {sp.x + delta.x, sp.y + delta.y};
            [p moveAtIndex:pti to:newPos];
          }];
    } else {
      active.isRect = NO;
      [active moveAtIndex:self.dragIndex to:objPos];
    }
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
    if (self.autoSelectPending) {
      CGFloat dx = positionX - self.autoSelectClickOrigin.x;
      CGFloat dy = positionY - self.autoSelectClickOrigin.y;
      if (hypot(dx, dy) < 4.0)
        return;
      self.autoSelectPending = NO;
    }
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
  if (self.dragIsRotation) {
    [self dragRotateAtX:positionX
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
    if (modifiers & kFxModifierKey_SHIFT)
      objPos = [self shiftConstrainedPosition:objPos];
    simd_float2 delta = objPos - self.dragOrigin;
    BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
    if (isCursorMode && (modifiers & kFxModifierKey_OPTION) &&
        !self.dragDidDuplicate) {
      self.dragDidDuplicate = YES;
      NSMutableIndexSet *srcIndices =
          [NSMutableIndexSet indexSetWithIndex:self.activePathIndex];
      if (active.isGroup)
        [srcIndices
            addIndexes:KKDescendantIndices(self.activePathIndex, self.paths)];
      NSMutableDictionary<NSString *, NSString *> *groupIDMap =
          [NSMutableDictionary dictionary];
      __block NSInteger cloneIdx = -1;
      [srcIndices enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        KKBezierPath *c =
            [KKBezierPath pathWithData:[self.paths[idx] dataRepresentation]];
        if (c.isGroup && c.groupID) {
          NSString *newID = [[NSUUID UUID] UUIDString];
          groupIDMap[c.groupID] = newID;
          c.groupID = newID;
        }
        if (c.parentGroupID && groupIDMap[c.parentGroupID])
          c.parentGroupID = groupIDMap[c.parentGroupID];
        [self.paths addObject:c];
        if ((NSUInteger)self.activePathIndex == idx)
          cloneIdx = (NSInteger)self.paths.count - 1;
      }];
      [self.selectedPathIndices removeAllIndexes];
      [self.selectedPathIndices addIndex:cloneIdx];
      self.activePathIndex = cloneIdx;
    }
    active = [self activePath];
    [active translateBy:delta];
    if (active.isGroup) {
      NSIndexSet *desc = KKDescendantIndices(self.activePathIndex, self.paths);
      [desc enumerateIndexesUsingBlock:^(NSUInteger di, BOOL *stop) {
        [self.paths[di] translateBy:delta];
      }];
    }
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

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  if (self.autoSelectPending) {
    self.autoSelectPending = NO;
    double hitRadiusStroke = [self strokeHitRadius];
    NSInteger frontPath = [self pathIndexNearX:positionX
                                             y:positionY
                                        radius:hitRadiusStroke];
    if (frontPath >= 0 && ![self.selectedPathIndices containsIndex:frontPath]) {
      NSIndexSet *prevSel = [self.selectedPathIndices copy];
      [self.selectedPathIndices removeAllIndexes];
      [self.selectedPathIndices addIndex:frontPath];
      self.activePathIndex = frontPath;
      [self resetDragState];
      [self syncStrokeParamsToSelectionWithPrevious:prevSel];
      *forceUpdate = YES;
      [super mouseUpAtPositionX:positionX
                      positionY:positionY
                     activePart:activePart
                      modifiers:modifiers
                    forceUpdate:forceUpdate
                         atTime:time];
      return;
    }
  }

  if (self.dragIsMarquee)
    [self finalizeMarqueeAtX:positionX y:positionY modifiers:modifiers];
  if (self.dragIsRect)
    [self finalizeRect];
  if (self.dragIsEllipse)
    [self finalizeEllipse];
  if (self.dragIsLine)
    [self finalizeLine];

  [self resetDragState];
  [self syncStrokeParamsToSelection];
  *forceUpdate = YES;
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

@end
