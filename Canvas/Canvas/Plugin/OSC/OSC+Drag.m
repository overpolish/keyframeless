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

  BOOL snapActive = self.cmdSnapOverride ? !self.snapToGrid : self.snapToGrid;
  if (!snapActive || self.gridEnabled)
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
  NSUInteger maxTargets = (self.paths.count + 1) * 3 + 3;
  float *targetXs = malloc(maxTargets * sizeof(float));
  float *targetYs = malloc(maxTargets * sizeof(float));
  NSUInteger txCount = 0, tyCount = 0;

  // Canvas edges and center.
  targetXs[txCount++] = 0.0f;
  targetXs[txCount++] = 0.5f;
  targetXs[txCount++] = 1.0f;
  targetYs[tyCount++] = 0.0f;
  targetYs[tyCount++] = 0.5f;
  targetYs[tyCount++] = 1.0f;

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

  // Equal spacing snap.
  self.spacingSnapX = NO;
  self.spacingSnapY = NO;
  self.spacingRefX = NO;
  self.spacingRefY = NO;

  float spThresh = (pixelsPerUnit > 0) ? 5.0f / pixelsPerUnit : 0.003f;

  // Gather bboxes of non-selected visible paths.
  NSUInteger otherCount = 0;
  for (NSUInteger i = 0; i < self.paths.count; i++) {
    if ([selected containsIndex:i])
      continue;
    KKBezierPath *p = self.paths[i];
    if (p.hidden || p.isGroup || p.count == 0)
      continue;
    otherCount++;
  }

  if (otherCount >= 1) {
    float *oMinXs = malloc(otherCount * sizeof(float));
    float *oMaxXs = malloc(otherCount * sizeof(float));
    float *oMinYs = malloc(otherCount * sizeof(float));
    float *oMaxYs = malloc(otherCount * sizeof(float));
    NSUInteger oi = 0;
    for (NSUInteger i = 0; i < self.paths.count; i++) {
      if ([selected containsIndex:i])
        continue;
      KKBezierPath *p = self.paths[i];
      if (p.hidden || p.isGroup || p.count == 0)
        continue;
      simd_float2 pMin, pMax;
      [self boundsOfPath:p min:&pMin max:&pMax];
      oMinXs[oi] = pMin.x;
      oMaxXs[oi] = pMax.x;
      oMinYs[oi] = pMin.y;
      oMaxYs[oi] = pMax.y;
      oi++;
    }

    // Post-alignment-snap selection bounds.
    float adjSMinX = sMinX + (bestDistX < FLT_MAX ? snapAdjX : 0);
    float adjSMaxX = sMaxX + (bestDistX < FLT_MAX ? snapAdjX : 0);
    float adjSMinY = sMinY + (bestDistY < FLT_MAX ? snapAdjY : 0);
    float adjSMaxY = sMaxY + (bestDistY < FLT_MAX ? snapAdjY : 0);
    float midY = (adjSMinY + adjSMaxY) * 0.5f;
    float midX = (adjSMinX + adjSMaxX) * 0.5f;

    // --- X axis ---
    // Find nearest left/right neighbors. Canvas edges act as neighbors.
    float nearLeftEdge = 0.0f;  // canvas left edge
    float nearRightEdge = 1.0f; // canvas right edge
    for (NSUInteger k = 0; k < otherCount; k++) {
      if (oMaxXs[k] <= adjSMinX + spThresh && oMaxXs[k] > nearLeftEdge)
        nearLeftEdge = oMaxXs[k];
      if (oMinXs[k] >= adjSMaxX - spThresh && oMinXs[k] < nearRightEdge)
        nearRightEdge = oMinXs[k];
    }

    // Case 1: between two neighbors — equalize gaps.
    {
      float gapLeft = adjSMinX - nearLeftEdge;
      float gapRight = nearRightEdge - adjSMaxX;
      float diff = gapLeft - gapRight;
      if (fabsf(diff) < spThresh) {
        float adj = -diff * 0.5f;
        delta.x += adj;
        self.spacingSnapX = YES;
        self.spacingLeftEdge = nearLeftEdge;
        self.spacingSelLeft = adjSMinX + adj;
        self.spacingSelRight = adjSMaxX + adj;
        self.spacingRightEdge = nearRightEdge;
        self.spacingMidY = midY;
      }
    }

    // Case 2: gap to one neighbor matches an existing gap elsewhere.
    // Existing gaps include inter-object gaps AND object-to-canvas-edge gaps.
    if (!self.spacingSnapX) {
      // Collect existing gaps: (leftEdge, rightEdge, midY for drawing).
      NSUInteger maxGaps = otherCount * 2 + otherCount;
      float *gapLefts = malloc(maxGaps * sizeof(float));
      float *gapRights = malloc(maxGaps * sizeof(float));
      float *gapMidYs = malloc(maxGaps * sizeof(float));
      NSUInteger gapCount = 0;

      // Gaps from canvas edges to each object.
      for (NSUInteger k = 0; k < otherCount; k++) {
        float omy = (oMinYs[k] + oMaxYs[k]) * 0.5f;
        float edgeGapL = oMinXs[k] - 0.0f;
        if (edgeGapL > 0) {
          gapLefts[gapCount] = 0.0f;
          gapRights[gapCount] = oMinXs[k];
          gapMidYs[gapCount] = omy;
          gapCount++;
        }
        float edgeGapR = 1.0f - oMaxXs[k];
        if (edgeGapR > 0) {
          gapLefts[gapCount] = oMaxXs[k];
          gapRights[gapCount] = 1.0f;
          gapMidYs[gapCount] = omy;
          gapCount++;
        }
      }

      // Gaps between adjacent sorted objects.
      if (otherCount >= 2) {
        NSUInteger *sortedX = malloc(otherCount * sizeof(NSUInteger));
        for (NSUInteger k = 0; k < otherCount; k++)
          sortedX[k] = k;
        for (NSUInteger a = 0; a < otherCount; a++) {
          for (NSUInteger b = a + 1; b < otherCount; b++) {
            if (oMinXs[sortedX[b]] < oMinXs[sortedX[a]]) {
              NSUInteger tmp = sortedX[a];
              sortedX[a] = sortedX[b];
              sortedX[b] = tmp;
            }
          }
        }
        for (NSUInteger a = 0; a + 1 < otherCount; a++) {
          NSUInteger ai = sortedX[a], bi = sortedX[a + 1];
          float eg = oMinXs[bi] - oMaxXs[ai];
          if (eg > 0) {
            gapLefts[gapCount] = oMaxXs[ai];
            gapRights[gapCount] = oMinXs[bi];
            gapMidYs[gapCount] = ((oMinYs[ai] + oMaxYs[ai]) * 0.5f +
                                  (oMinYs[bi] + oMaxYs[bi]) * 0.5f) *
                                 0.5f;
            gapCount++;
          }
        }
        free(sortedX);
      }

      for (NSUInteger g = 0; g < gapCount; g++) {
        float existingGap = gapRights[g] - gapLefts[g];
        float refMY = gapMidYs[g];

        float gapL = adjSMinX - nearLeftEdge;
        float diffL = gapL - existingGap;
        if (fabsf(diffL) < spThresh) {
          delta.x -= diffL;
          self.spacingSnapX = YES;
          self.spacingLeftEdge = nearLeftEdge;
          self.spacingSelLeft = adjSMinX - diffL;
          self.spacingSelRight = adjSMaxX - diffL;
          self.spacingRightEdge = self.spacingSelRight;
          self.spacingMidY = midY;
          self.spacingRefX = YES;
          self.spacingRefLeftX = gapLefts[g];
          self.spacingRefRightX = gapRights[g];
          self.spacingRefMidYX = refMY;
          break;
        }
        float gapR = nearRightEdge - adjSMaxX;
        float diffR = gapR - existingGap;
        if (fabsf(diffR) < spThresh) {
          delta.x += diffR;
          self.spacingSnapX = YES;
          self.spacingSelLeft = adjSMinX + diffR;
          self.spacingSelRight = adjSMaxX + diffR;
          self.spacingLeftEdge = self.spacingSelLeft;
          self.spacingRightEdge = nearRightEdge;
          self.spacingMidY = midY;
          self.spacingRefX = YES;
          self.spacingRefLeftX = gapLefts[g];
          self.spacingRefRightX = gapRights[g];
          self.spacingRefMidYX = refMY;
          break;
        }
      }
      free(gapLefts);
      free(gapRights);
      free(gapMidYs);
    }

    // --- Y axis ---
    float nearTopEdge = 0.0f;
    float nearBottomEdge = 1.0f;
    for (NSUInteger k = 0; k < otherCount; k++) {
      if (oMaxYs[k] <= adjSMinY + spThresh && oMaxYs[k] > nearTopEdge)
        nearTopEdge = oMaxYs[k];
      if (oMinYs[k] >= adjSMaxY - spThresh && oMinYs[k] < nearBottomEdge)
        nearBottomEdge = oMinYs[k];
    }

    {
      float gapTop = adjSMinY - nearTopEdge;
      float gapBottom = nearBottomEdge - adjSMaxY;
      float diff = gapTop - gapBottom;
      if (fabsf(diff) < spThresh) {
        float adj = -diff * 0.5f;
        delta.y += adj;
        self.spacingSnapY = YES;
        self.spacingTopEdge = nearTopEdge;
        self.spacingSelTop = adjSMinY + adj;
        self.spacingSelBottom = adjSMaxY + adj;
        self.spacingBottomEdge = nearBottomEdge;
        self.spacingMidX = midX;
      }
    }

    if (!self.spacingSnapY) {
      NSUInteger maxGapsY = otherCount * 2 + otherCount;
      float *gapTops = malloc(maxGapsY * sizeof(float));
      float *gapBottoms = malloc(maxGapsY * sizeof(float));
      float *gapMidXs = malloc(maxGapsY * sizeof(float));
      NSUInteger gapCountY = 0;

      for (NSUInteger k = 0; k < otherCount; k++) {
        float omx = (oMinXs[k] + oMaxXs[k]) * 0.5f;
        float edgeGapT = oMinYs[k] - 0.0f;
        if (edgeGapT > 0) {
          gapTops[gapCountY] = 0.0f;
          gapBottoms[gapCountY] = oMinYs[k];
          gapMidXs[gapCountY] = omx;
          gapCountY++;
        }
        float edgeGapB = 1.0f - oMaxYs[k];
        if (edgeGapB > 0) {
          gapTops[gapCountY] = oMaxYs[k];
          gapBottoms[gapCountY] = 1.0f;
          gapMidXs[gapCountY] = omx;
          gapCountY++;
        }
      }

      if (otherCount >= 2) {
        NSUInteger *sortedY = malloc(otherCount * sizeof(NSUInteger));
        for (NSUInteger k = 0; k < otherCount; k++)
          sortedY[k] = k;
        for (NSUInteger a = 0; a < otherCount; a++) {
          for (NSUInteger b = a + 1; b < otherCount; b++) {
            if (oMinYs[sortedY[b]] < oMinYs[sortedY[a]]) {
              NSUInteger tmp = sortedY[a];
              sortedY[a] = sortedY[b];
              sortedY[b] = tmp;
            }
          }
        }
        for (NSUInteger a = 0; a + 1 < otherCount; a++) {
          NSUInteger ai = sortedY[a], bi = sortedY[a + 1];
          float eg = oMinYs[bi] - oMaxYs[ai];
          if (eg > 0) {
            gapTops[gapCountY] = oMaxYs[ai];
            gapBottoms[gapCountY] = oMinYs[bi];
            gapMidXs[gapCountY] = ((oMinXs[ai] + oMaxXs[ai]) * 0.5f +
                                   (oMinXs[bi] + oMaxXs[bi]) * 0.5f) *
                                  0.5f;
            gapCountY++;
          }
        }
        free(sortedY);
      }

      for (NSUInteger g = 0; g < gapCountY; g++) {
        float existingGap = gapBottoms[g] - gapTops[g];
        float refMX = gapMidXs[g];

        float gapT = adjSMinY - nearTopEdge;
        float diffT = gapT - existingGap;
        if (fabsf(diffT) < spThresh) {
          delta.y -= diffT;
          self.spacingSnapY = YES;
          self.spacingTopEdge = nearTopEdge;
          self.spacingSelTop = adjSMinY - diffT;
          self.spacingSelBottom = adjSMaxY - diffT;
          self.spacingBottomEdge = self.spacingSelBottom;
          self.spacingMidX = midX;
          self.spacingRefY = YES;
          self.spacingRefTopY = gapTops[g];
          self.spacingRefBottomY = gapBottoms[g];
          self.spacingRefMidXY = refMX;
          break;
        }
        float gapB = nearBottomEdge - adjSMaxY;
        float diffB = gapB - existingGap;
        if (fabsf(diffB) < spThresh) {
          delta.y += diffB;
          self.spacingSnapY = YES;
          self.spacingSelTop = adjSMinY + diffB;
          self.spacingSelBottom = adjSMaxY + diffB;
          self.spacingTopEdge = self.spacingSelTop;
          self.spacingBottomEdge = nearBottomEdge;
          self.spacingMidX = midX;
          self.spacingRefY = YES;
          self.spacingRefTopY = gapTops[g];
          self.spacingRefBottomY = gapBottoms[g];
          self.spacingRefMidXY = refMX;
          break;
        }
      }
      free(gapTops);
      free(gapBottoms);
      free(gapMidXs);
    }

    free(oMinXs);
    free(oMaxXs);
    free(oMinYs);
    free(oMaxYs);
  }

  return delta;
}

- (simd_float2)alignSnapPoint:(simd_float2)point
               excludingPaths:(NSIndexSet *)excluded
              excludingPoints:(NSIndexSet *)excludedPoints {
  self.alignSnappedX = NO;
  self.alignSnappedY = NO;

  BOOL snapActive = self.cmdSnapOverride ? !self.snapToGrid : self.snapToGrid;
  if (!snapActive || self.gridEnabled)
    return point;
  if (self.imageWidth <= 0 || self.imageHeight <= 0)
    return point;

  CGPoint originC = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint unitC = [self
      canvasPointFromObjectPoint:(simd_float2){1.0f / self.imageWidth, 0}];
  float pxPerSourcePx = (float)fabs(unitC.x - originC.x);
  float pixelsPerUnit = pxPerSourcePx * self.imageWidth;
  float thresh = (pixelsPerUnit > 0) ? 8.0f / pixelsPerUnit : 0.005f;

  // Count total targets: 3 (canvas edges+center) + per path (3 bbox + N pts).
  NSUInteger maxTargets = 3;
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

  // Canvas edges and center.
  targetXs[txCount++] = 0.0f;
  targetXs[txCount++] = 0.5f;
  targetXs[txCount++] = 1.0f;
  targetYs[tyCount++] = 0.0f;
  targetYs[tyCount++] = 0.5f;
  targetYs[tyCount++] = 1.0f;

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
  self.spacingSnapX = NO;
  self.spacingSnapY = NO;
  self.spacingRefX = NO;
  self.spacingRefY = NO;
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
  self.cmdSnapOverride = (modifiers & kFxModifierKey_COMMAND) != 0;
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
  self.cmdSnapOverride = (modifiers & kFxModifierKey_COMMAND) != 0;
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

  BOOL isCursorMode = (self.toolbar.activeTag == kOSCToolbarCursor);
  self.cmdSnapOverride = (modifiers & kFxModifierKey_COMMAND) != 0;

  // Snap the selection's bounding-box corner to grid, not the mouse position.
  // This ensures the object aligns to the actual grid lines regardless of
  // where the drag started within the object.
  simd_float2 rawDelta = objPos - self.dragOrigin;
  simd_float2 bmin, bmax;
  if (self.snapToGrid && self.gridEnabled && isCursorMode &&
      [self boundsOfSelectedPaths:&bmin max:&bmax]) {
    simd_float2 targetMin = bmin + rawDelta;
    simd_float2 snappedMin = [self snapToGridPosition:targetMin];
    rawDelta += (snappedMin - targetMin);
  } else {
    objPos = [self snapToGridPosition:objPos];
    rawDelta = objPos - self.dragOrigin;
  }
  simd_float2 delta = rawDelta;
  if (isCursorMode)
    delta = [self alignSnapDelta:delta
                forSelectedPaths:self.selectedPathIndices];
  self.dragOrigin += delta;
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
    self.cmdSnapOverride = (modifiers & kFxModifierKey_COMMAND) != 0;
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
    self.cmdSnapOverride = (modifiers & kFxModifierKey_COMMAND) != 0;
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
    self.dragOrigin += delta;
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
