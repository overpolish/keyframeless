/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"

@implementation CanvasOSC (Drag)

- (simd_float2)snapToGridPosition:(simd_float2)objPos {
  if (!self.snapToGrid || !self.gridEnabled || self.imageWidth <= 0 ||
      self.imageHeight <= 0)
    return objPos;
  CGFloat spacing = (CGFloat)self.gridSpacing;
  if (self.gridAdaptive) {
    CGPoint originCanvas =
        [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
    CGPoint unitCanvas = [self
        canvasPointFromObjectPoint:(simd_float2){1.0f / self.imageWidth, 0}];
    CGFloat pxPerSourcePx = fabs(unitCanvas.x - originCanvas.x);
    CGFloat screenSpacing = spacing * pxPerSourcePx;
    static const CGFloat kMinScreenSpacing = 30.0;
    while (screenSpacing < kMinScreenSpacing && spacing < 10000) {
      spacing *= 2.0;
      screenSpacing *= 2.0;
    }
  }
  float spacingX = (float)(spacing / self.imageWidth);
  float spacingY = (float)(spacing / self.imageHeight);
  objPos.x = roundf(objPos.x / spacingX) * spacingX;
  objPos.y = roundf(objPos.y / spacingY) * spacingY;
  return objPos;
}

- (simd_float2)alignSnapDelta:(simd_float2)delta
             forSelectedPaths:(NSIndexSet *)selected {
  self.alignSnappedX = NO;
  self.alignSnappedY = NO;

  if (!self.snapToGrid || self.gridEnabled)
    return delta;
  if (self.imageWidth <= 0 || self.imageHeight <= 0)
    return delta;
  if (selected.count == 0)
    return delta;

  // Threshold in object space — convert 8 canvas pixels.
  // pxPerSourcePx = canvas pixels per source pixel; multiply by imageWidth
  // to get canvas pixels per full object-space unit (0..1).
  CGPoint originC = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint unitC = [self
      canvasPointFromObjectPoint:(simd_float2){1.0f / self.imageWidth, 0}];
  float pxPerSourcePx = (float)fabs(unitC.x - originC.x);
  float pixelsPerUnit = pxPerSourcePx * self.imageWidth;
  float thresh = (pixelsPerUnit > 0) ? 8.0f / pixelsPerUnit : 0.005f;

  // Compute bounding box of selected paths after applying proposed delta.
  __block BOOL found = NO;
  __block float sMinX, sMinY, sMaxX, sMaxY;
  [selected enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
    if (idx >= self.paths.count)
      return;
    KKBezierPath *p = self.paths[idx];
    if (p.count == 0 || p.isGroup)
      return;
    simd_float2 pMin, pMax;
    [self boundsOfPath:p min:&pMin max:&pMax];
    pMin += delta;
    pMax += delta;
    if (!found) {
      sMinX = pMin.x;
      sMinY = pMin.y;
      sMaxX = pMax.x;
      sMaxY = pMax.y;
      found = YES;
    } else {
      sMinX = fminf(sMinX, pMin.x);
      sMinY = fminf(sMinY, pMin.y);
      sMaxX = fmaxf(sMaxX, pMax.x);
      sMaxY = fmaxf(sMaxY, pMax.y);
    }
  }];
  if (!found)
    return delta;

  float sCenterX = (sMinX + sMaxX) * 0.5f;
  float sCenterY = (sMinY + sMaxY) * 0.5f;

  // Collect snap target X and Y values from non-selected visible paths.
  // Each path contributes: left, center, right (X) and top, center, bottom (Y).
  // Plus canvas center (0.5, 0.5).
  NSUInteger maxTargets = (self.paths.count + 1) * 3;
  float *targetXs = malloc(maxTargets * sizeof(float));
  float *targetYs = malloc(maxTargets * sizeof(float));
  NSUInteger txCount = 0, tyCount = 0;

  // Canvas center.
  targetXs[txCount++] = 0.5f;
  targetYs[tyCount++] = 0.5f;

  for (NSUInteger i = 0; i < self.paths.count; i++) {
    if ([selected containsIndex:i])
      continue;
    KKBezierPath *p = self.paths[i];
    if (p.hidden || p.isGroup || p.count == 0)
      continue;
    simd_float2 pMin, pMax;
    [self boundsOfPath:p min:&pMin max:&pMax];
    targetXs[txCount++] = pMin.x;
    targetXs[txCount++] = (pMin.x + pMax.x) * 0.5f;
    targetXs[txCount++] = pMax.x;
    targetYs[tyCount++] = pMin.y;
    targetYs[tyCount++] = (pMin.y + pMax.y) * 0.5f;
    targetYs[tyCount++] = pMax.y;
  }

  // Check selection edges/center against targets — find best snap per axis.
  float selXs[3] = {sMinX, sCenterX, sMaxX};
  float selYs[3] = {sMinY, sCenterY, sMaxY};

  float bestDistX = FLT_MAX, snapAdjX = 0, matchedTargetX = 0;
  for (int si = 0; si < 3; si++) {
    for (NSUInteger ti = 0; ti < txCount; ti++) {
      float d = fabsf(selXs[si] - targetXs[ti]);
      if (d < thresh && d < bestDistX) {
        bestDistX = d;
        snapAdjX = targetXs[ti] - selXs[si];
        matchedTargetX = targetXs[ti];
      }
    }
  }

  float bestDistY = FLT_MAX, snapAdjY = 0, matchedTargetY = 0;
  for (int si = 0; si < 3; si++) {
    for (NSUInteger ti = 0; ti < tyCount; ti++) {
      float d = fabsf(selYs[si] - targetYs[ti]);
      if (d < thresh && d < bestDistY) {
        bestDistY = d;
        snapAdjY = targetYs[ti] - selYs[si];
        matchedTargetY = targetYs[ti];
      }
    }
  }

  free(targetXs);
  free(targetYs);

  if (bestDistX < FLT_MAX) {
    self.alignSnappedX = YES;
    self.alignSnapValueX = matchedTargetX;
    delta.x += snapAdjX;
  }
  if (bestDistY < FLT_MAX) {
    self.alignSnappedY = YES;
    self.alignSnapValueY = matchedTargetY;
    delta.y += snapAdjY;
  }

  return delta;
}

- (simd_float2)alignSnapPoint:(simd_float2)point
               excludingPaths:(NSIndexSet *)excluded
              excludingPoints:(NSIndexSet *)excludedPoints {
  self.alignSnappedX = NO;
  self.alignSnappedY = NO;

  if (!self.snapToGrid || self.gridEnabled)
    return point;
  if (self.imageWidth <= 0 || self.imageHeight <= 0)
    return point;

  CGPoint originC = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint unitC = [self
      canvasPointFromObjectPoint:(simd_float2){1.0f / self.imageWidth, 0}];
  float pxPerSourcePx = (float)fabs(unitC.x - originC.x);
  float pixelsPerUnit = pxPerSourcePx * self.imageWidth;
  float thresh = (pixelsPerUnit > 0) ? 8.0f / pixelsPerUnit : 0.005f;

  // Count total targets: 1 (canvas center) + per path (3 bbox + N points).
  NSUInteger maxTargets = 1;
  for (NSUInteger i = 0; i < self.paths.count; i++) {
    if (excluded && [excluded containsIndex:i])
      continue;
    KKBezierPath *p = self.paths[i];
    if (p.hidden || p.isGroup || p.count == 0)
      continue;
    maxTargets += 3 + p.count;
  }
  float *targetXs = malloc(maxTargets * sizeof(float));
  float *targetYs = malloc(maxTargets * sizeof(float));
  NSUInteger txCount = 0, tyCount = 0;

  targetXs[txCount++] = 0.5f;
  targetYs[tyCount++] = 0.5f;

  for (NSUInteger i = 0; i < self.paths.count; i++) {
    if (excluded && [excluded containsIndex:i])
      continue;
    KKBezierPath *p = self.paths[i];
    if (p.hidden || p.isGroup || p.count == 0)
      continue;
    // Skip bounding box targets for paths that contain excluded points,
    // since the bbox reflects those points' positions.
    BOOL hasExcludedPt = NO;
    if (excludedPoints) {
      for (NSUInteger j = 0; j < p.count; j++) {
        if ([excludedPoints containsIndex:selKey(i, j)]) {
          hasExcludedPt = YES;
          break;
        }
      }
    }
    if (!hasExcludedPt) {
      simd_float2 pMin, pMax;
      [self boundsOfPath:p min:&pMin max:&pMax];
      targetXs[txCount++] = pMin.x;
      targetXs[txCount++] = (pMin.x + pMax.x) * 0.5f;
      targetXs[txCount++] = pMax.x;
      targetYs[tyCount++] = pMin.y;
      targetYs[tyCount++] = (pMin.y + pMax.y) * 0.5f;
      targetYs[tyCount++] = pMax.y;
    }
    for (NSUInteger j = 0; j < p.count; j++) {
      if (excludedPoints && [excludedPoints containsIndex:selKey(i, j)])
        continue;
      KKBezierPoint bp = [p pointAtIndex:j];
      targetXs[txCount++] = bp.x;
      targetYs[tyCount++] = bp.y;
    }
  }

  float bestDistX = FLT_MAX, bestDistY = FLT_MAX;
  float matchedX = point.x, matchedY = point.y;
  for (NSUInteger ti = 0; ti < txCount; ti++) {
    float d = fabsf(point.x - targetXs[ti]);
    if (d < thresh && d < bestDistX) {
      bestDistX = d;
      matchedX = targetXs[ti];
    }
  }
  for (NSUInteger ti = 0; ti < tyCount; ti++) {
    float d = fabsf(point.y - targetYs[ti]);
    if (d < thresh && d < bestDistY) {
      bestDistY = d;
      matchedY = targetYs[ti];
    }
  }

  free(targetXs);
  free(targetYs);

  if (bestDistX < FLT_MAX) {
    self.alignSnappedX = YES;
    self.alignSnapValueX = matchedX;
    point.x = matchedX;
  }
  if (bestDistY < FLT_MAX) {
    self.alignSnappedY = YES;
    self.alignSnapValueY = matchedY;
    point.y = matchedY;
  }
  return point;
}

- (void)resetAlignSnap {
  self.alignSnappedX = NO;
  self.alignSnappedY = NO;
}

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
  objPos = [self snapToGridPosition:objPos];
  objPos = [self alignSnapPoint:objPos excludingPaths:nil excludingPoints:nil];
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
  objPos = [self snapToGridPosition:objPos];
  objPos = [self alignSnapPoint:objPos excludingPaths:nil excludingPoints:nil];
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
  objPos = [self snapToGridPosition:objPos];
  simd_float2 delta = objPos - self.dragOrigin;
  self.dragOrigin = objPos;

  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  if (isCursorMode)
    delta = [self alignSnapDelta:delta
                forSelectedPaths:self.selectedPathIndices];
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
    objPos = [self snapToGridPosition:objPos];
    {
      NSMutableIndexSet *exPts = [NSMutableIndexSet
          indexSetWithIndex:selKey((NSUInteger)self.activePathIndex,
                                   (NSUInteger)self.dragIndex)];
      if (self.selectedPoints.count > 1)
        [exPts addIndexes:self.selectedPoints];
      objPos = [self alignSnapPoint:objPos
                     excludingPaths:nil
                    excludingPoints:exPts];
    }
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
  if (self.stepperDragging) {
    // Accumulate delta from successive drags.
    double moveDelta = positionY - self.stepperDragOriginY;
    self.stepperDragOriginY = positionY;
    self.stepperAccumulatedDelta += moveDelta;

    BOOL shiftDown = (modifiers & kFxModifierKey_SHIFT) != 0;

    // When shift is pressed/released, rebase so the multiplier change
    // starts from the current value.
    if (shiftDown != self.stepperShiftWasDown) {
      self.stepperAccumulatedDelta = 0;
      self.stepperDragStartValue = self.gridSpacing;
      self.stepperShiftWasDown = shiftDown;
    }

    // 8px per unit normally, 2px per unit with shift.
    // Positive delta (drag down / Y increases) = increase value.
    double pxPerUnit = shiftDown ? 2.0 : 8.0;
    // Canvas Y=0 is top, so drag up = negative delta = increase.
    NSInteger newVal = self.stepperDragStartValue +
                       (NSInteger)(self.stepperAccumulatedDelta / pxPerUnit);
    if (newVal < 1)
      newVal = 1;
    if (newVal > 1000)
      newVal = 1000;
    if (newVal != self.gridSpacing) {
      self.gridSpacing = newVal;
      id<FxParameterSettingAPI_v5> setAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      [setAPI setIntValue:(int)self.gridSpacing
              toParameter:kParamGridSpacing
                   atTime:kCMTimeZero];
      *forceUpdate = YES;
    }
    return;
  }
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
    objPos = [self snapToGridPosition:objPos];
    simd_float2 delta = objPos - self.dragOrigin;
    BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
    if (isCursorMode) {
      NSMutableIndexSet *snapSet =
          [NSMutableIndexSet indexSetWithIndex:self.activePathIndex];
      if (active.isGroup)
        [snapSet
            addIndexes:KKDescendantIndices(self.activePathIndex, self.paths)];
      delta = [self alignSnapDelta:delta forSelectedPaths:snapSet];
    }
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
  if (self.stepperDragging) {
    self.stepperDragging = NO;
    self.stepperShiftWasDown = NO;
  }
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
  [self resetAlignSnap];
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
