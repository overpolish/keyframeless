/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC_Private.h"

// Per-axis bounding box arrays for non-selected paths.
typedef struct {
  float *mins;
  float *maxs;
  float *crossMins; // cross-axis mins (for midpoint calculation)
  float *crossMaxs;
  NSUInteger count;
} KKAxisBounds;

static KKAxisBounds KKAxisBoundsCreate(NSUInteger capacity) {
  return (KKAxisBounds){
      .mins = malloc(capacity * sizeof(float)),
      .maxs = malloc(capacity * sizeof(float)),
      .crossMins = malloc(capacity * sizeof(float)),
      .crossMaxs = malloc(capacity * sizeof(float)),
      .count = 0,
  };
}

static void KKAxisBoundsFree(KKAxisBounds *b) {
  free(b->mins);
  free(b->maxs);
  free(b->crossMins);
  free(b->crossMaxs);
}

// Find nearest neighbor edges along one axis.
static void findNeighborEdges(KKAxisBounds *b, float selMin, float selMax,
                              float threshold, float *outNearMin,
                              float *outNearMax) {
  *outNearMin = 0.0f; // canvas edge
  *outNearMax = 1.0f; // canvas edge
  for (NSUInteger k = 0; k < b->count; k++) {
    if (b->maxs[k] <= selMin + threshold && b->maxs[k] > *outNearMin)
      *outNearMin = b->maxs[k];
    if (b->mins[k] >= selMax - threshold && b->mins[k] < *outNearMax)
      *outNearMax = b->mins[k];
  }
}

// Result of a single-axis spacing snap attempt.
typedef struct {
  float deltaAdj;
  BOOL snapped;
  float snapStart;
  float snapSelMin;
  float snapSelMax;
  float snapEnd;
  float snapCrossMid;
  BOOL hasRef;
  float refStart;
  float refEnd;
  float refCrossMid;
} KKSpacingSnapResult;

// Try centering between two neighbors (equal gap on both sides).
static BOOL tryCenterSnap(float selMin, float selMax, float nearMin,
                          float nearMax, float threshold, float *outAdj) {
  float gapBefore = selMin - nearMin;
  float gapAfter = nearMax - selMax;
  float diff = gapBefore - gapAfter;
  if (fabsf(diff) < threshold) {
    *outAdj = -diff * 0.5f;
    return YES;
  }
  return NO;
}

// Collect existing gaps (inter-object and object-to-canvas-edge) along one
// axis. Returns arrays of gap edges and cross-axis midpoints for drawing.
typedef struct {
  float *starts;
  float *ends;
  float *crossMids;
  NSUInteger count;
} KKGapList;

static KKGapList collectExistingGaps(KKAxisBounds *b) {
  NSUInteger maxGaps = b->count * 3;
  KKGapList g = {
      .starts = malloc(maxGaps * sizeof(float)),
      .ends = malloc(maxGaps * sizeof(float)),
      .crossMids = malloc(maxGaps * sizeof(float)),
      .count = 0,
  };

  // Gaps from canvas edges to each object.
  for (NSUInteger k = 0; k < b->count; k++) {
    float crossMid = (b->crossMins[k] + b->crossMaxs[k]) * 0.5f;
    if (b->mins[k] > 0.0f) {
      g.starts[g.count] = 0.0f;
      g.ends[g.count] = b->mins[k];
      g.crossMids[g.count] = crossMid;
      g.count++;
    }
    if (b->maxs[k] < 1.0f) {
      g.starts[g.count] = b->maxs[k];
      g.ends[g.count] = 1.0f;
      g.crossMids[g.count] = crossMid;
      g.count++;
    }
  }

  // Gaps between adjacent sorted objects.
  if (b->count >= 2) {
    NSUInteger *sorted = malloc(b->count * sizeof(NSUInteger));
    for (NSUInteger k = 0; k < b->count; k++)
      sorted[k] = k;
    for (NSUInteger a = 0; a < b->count; a++) {
      for (NSUInteger c = a + 1; c < b->count; c++) {
        if (b->mins[sorted[c]] < b->mins[sorted[a]]) {
          NSUInteger tmp = sorted[a];
          sorted[a] = sorted[c];
          sorted[c] = tmp;
        }
      }
    }
    for (NSUInteger a = 0; a + 1 < b->count; a++) {
      NSUInteger ai = sorted[a], bi = sorted[a + 1];
      float gap = b->mins[bi] - b->maxs[ai];
      if (gap > 0) {
        g.starts[g.count] = b->maxs[ai];
        g.ends[g.count] = b->mins[bi];
        g.crossMids[g.count] = ((b->crossMins[ai] + b->crossMaxs[ai]) * 0.5f +
                                (b->crossMins[bi] + b->crossMaxs[bi]) * 0.5f) *
                               0.5f;
        g.count++;
      }
    }
    free(sorted);
  }
  return g;
}

static void KKGapListFree(KKGapList *g) {
  free(g->starts);
  free(g->ends);
  free(g->crossMids);
}

// Try to match selection gap to an existing gap.
// Returns YES if a match was found; outAdj receives the delta adjustment.
static BOOL tryGapMatchSnap(KKGapList *gaps, float selMin, float selMax,
                            float nearMin, float nearMax, float threshold,
                            float *outAdj, float *outRefStart, float *outRefEnd,
                            float *outRefCrossMid) {
  for (NSUInteger g = 0; g < gaps->count; g++) {
    float existingGap = gaps->ends[g] - gaps->starts[g];

    // Try matching gap before selection.
    float gapBefore = selMin - nearMin;
    float diffBefore = gapBefore - existingGap;
    if (fabsf(diffBefore) < threshold) {
      *outAdj = -diffBefore;
      *outRefStart = gaps->starts[g];
      *outRefEnd = gaps->ends[g];
      *outRefCrossMid = gaps->crossMids[g];
      return YES;
    }

    // Try matching gap after selection.
    float gapAfter = nearMax - selMax;
    float diffAfter = gapAfter - existingGap;
    if (fabsf(diffAfter) < threshold) {
      *outAdj = diffAfter;
      *outRefStart = gaps->starts[g];
      *outRefEnd = gaps->ends[g];
      *outRefCrossMid = gaps->crossMids[g];
      return YES;
    }
  }
  return NO;
}

// Find the best snap target on one axis (closest within threshold).
static BOOL findBestSnap(const float *targets, NSUInteger count,
                         const float *selValues, int selCount, float threshold,
                         float *outMatchedTarget, float *outAdj) {
  float bestDist = FLT_MAX;
  for (int si = 0; si < selCount; si++) {
    for (NSUInteger ti = 0; ti < count; ti++) {
      float d = fabsf(selValues[si] - targets[ti]);
      if (d < threshold && d < bestDist) {
        bestDist = d;
        *outAdj = targets[ti] - selValues[si];
        *outMatchedTarget = targets[ti];
      }
    }
  }
  return bestDist < FLT_MAX;
}

@implementation CanvasOSC (Snap)

- (float)snapThresholdForCanvasPixels:(float)pixels {
  CGPoint originC = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint unitC = [self
      canvasPointFromObjectPoint:(simd_float2){1.0f / self.imageWidth, 0}];
  float pxPerSourcePx = (float)fabs(unitC.x - originC.x);
  float pixelsPerUnit = pxPerSourcePx * self.imageWidth;
  return (pixelsPerUnit > 0) ? pixels / pixelsPerUnit : 0.005f;
}

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

- (void)collectOtherBoundsX:(KKAxisBounds *)bx
                          Y:(KKAxisBounds *)by
                  excluding:(NSIndexSet *)selected {
  for (NSUInteger i = 0; i < self.paths.count; i++) {
    if ([selected containsIndex:i])
      continue;
    KKBezierPath *p = self.paths[i];
    if (p.hidden || p.isGroup || p.count == 0)
      continue;
    simd_float2 pMin, pMax;
    [self boundsOfPath:p min:&pMin max:&pMax];
    NSUInteger idx = bx->count;
    bx->mins[idx] = pMin.x;
    bx->maxs[idx] = pMax.x;
    bx->crossMins[idx] = pMin.y;
    bx->crossMaxs[idx] = pMax.y;
    by->mins[idx] = pMin.y;
    by->maxs[idx] = pMax.y;
    by->crossMins[idx] = pMin.x;
    by->crossMaxs[idx] = pMax.x;
    bx->count++;
    by->count++;
  }
}

- (KKSpacingSnapResult)spacingSnapOnAxis:(KKAxisBounds *)bounds
                                  selMin:(float)selMin
                                  selMax:(float)selMax
                                crossMid:(float)crossMid
                               threshold:(float)threshold {
  KKSpacingSnapResult r = {0};

  if (bounds->count < 1)
    return r;

  float nearMin, nearMax;
  findNeighborEdges(bounds, selMin, selMax, threshold, &nearMin, &nearMax);

  // Case 1: center between two neighbors.
  float adj = 0;
  if (tryCenterSnap(selMin, selMax, nearMin, nearMax, threshold, &adj)) {
    r.deltaAdj = adj;
    r.snapped = YES;
    r.snapStart = nearMin;
    r.snapSelMin = selMin + adj;
    r.snapSelMax = selMax + adj;
    r.snapEnd = nearMax;
    r.snapCrossMid = crossMid;
    return r;
  }

  // Case 2: match an existing gap.
  KKGapList gaps = collectExistingGaps(bounds);
  float refS, refE, refCM;
  if (tryGapMatchSnap(&gaps, selMin, selMax, nearMin, nearMax, threshold, &adj,
                      &refS, &refE, &refCM)) {
    r.deltaAdj = adj;
    r.snapped = YES;
    if (adj <= 0) {
      r.snapStart = nearMin;
      r.snapSelMin = selMin + adj;
      r.snapSelMax = selMax + adj;
      r.snapEnd = r.snapSelMax;
    } else {
      r.snapSelMin = selMin + adj;
      r.snapSelMax = selMax + adj;
      r.snapStart = r.snapSelMin;
      r.snapEnd = nearMax;
    }
    r.snapCrossMid = crossMid;
    r.hasRef = YES;
    r.refStart = refS;
    r.refEnd = refE;
    r.refCrossMid = refCM;
  }
  KKGapListFree(&gaps);
  return r;
}

- (simd_float2)alignSnapDelta:(simd_float2)delta
             forSelectedPaths:(NSIndexSet *)selected {
  self.alignSnappedX = NO;
  self.alignSnappedY = NO;
  self.spacingSnapX = NO;
  self.spacingSnapY = NO;
  self.spacingRefX = NO;
  self.spacingRefY = NO;

  BOOL snapActive = self.cmdSnapOverride ? !self.snapToGrid : self.snapToGrid;
  if (!snapActive || self.gridEnabled)
    return delta;
  if (self.imageWidth <= 0 || self.imageHeight <= 0)
    return delta;
  if (selected.count == 0)
    return delta;

  float thresh = [self snapThresholdForCanvasPixels:8.0f];

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

  // Collect snap targets from non-selected visible paths.
  NSUInteger maxTargets = (self.paths.count + 1) * 3 + 3;
  float *targetXs = malloc(maxTargets * sizeof(float));
  float *targetYs = malloc(maxTargets * sizeof(float));
  NSUInteger txCount = 0, tyCount = 0;

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

  // Alignment snap per axis.
  float selXs[3] = {sMinX, sCenterX, sMaxX};
  float selYs[3] = {sMinY, sCenterY, sMaxY};
  float snapAdjX = 0, matchedTargetX = 0;
  float snapAdjY = 0, matchedTargetY = 0;
  BOOL didSnapX = findBestSnap(targetXs, txCount, selXs, 3, thresh,
                               &matchedTargetX, &snapAdjX);
  BOOL didSnapY = findBestSnap(targetYs, tyCount, selYs, 3, thresh,
                               &matchedTargetY, &snapAdjY);

  free(targetXs);
  free(targetYs);

  if (didSnapX) {
    self.alignSnappedX = YES;
    self.alignSnapValueX = matchedTargetX;
    delta.x += snapAdjX;
  }
  if (didSnapY) {
    self.alignSnappedY = YES;
    self.alignSnapValueY = matchedTargetY;
    delta.y += snapAdjY;
  }

  // Equal spacing snap.
  self.spacingSnapX = NO;
  self.spacingSnapY = NO;
  self.spacingRefX = NO;
  self.spacingRefY = NO;

  float spThresh = [self snapThresholdForCanvasPixels:5.0f];

  // Count non-selected visible paths.
  NSUInteger otherCount = 0;
  for (NSUInteger i = 0; i < self.paths.count; i++) {
    if ([selected containsIndex:i])
      continue;
    KKBezierPath *p = self.paths[i];
    if (!p.hidden && !p.isGroup && p.count > 0)
      otherCount++;
  }

  if (otherCount >= 1) {
    KKAxisBounds bx = KKAxisBoundsCreate(otherCount);
    KKAxisBounds by = KKAxisBoundsCreate(otherCount);
    [self collectOtherBoundsX:&bx Y:&by excluding:selected];

    float adjSMinX = sMinX + (didSnapX ? snapAdjX : 0);
    float adjSMaxX = sMaxX + (didSnapX ? snapAdjX : 0);
    float adjSMinY = sMinY + (didSnapY ? snapAdjY : 0);
    float adjSMaxY = sMaxY + (didSnapY ? snapAdjY : 0);
    float midY = (adjSMinY + adjSMaxY) * 0.5f;
    float midX = (adjSMinX + adjSMaxX) * 0.5f;

    KKSpacingSnapResult rx = [self spacingSnapOnAxis:&bx
                                              selMin:adjSMinX
                                              selMax:adjSMaxX
                                            crossMid:midY
                                           threshold:spThresh];
    if (rx.snapped) {
      delta.x += rx.deltaAdj;
      self.spacingSnapX = YES;
      self.spacingLeftEdge = rx.snapStart;
      self.spacingSelLeft = rx.snapSelMin;
      self.spacingSelRight = rx.snapSelMax;
      self.spacingRightEdge = rx.snapEnd;
      self.spacingMidY = rx.snapCrossMid;
      self.spacingRefX = rx.hasRef;
      self.spacingRefLeftX = rx.refStart;
      self.spacingRefRightX = rx.refEnd;
      self.spacingRefMidYX = rx.refCrossMid;
    }

    KKSpacingSnapResult ry = [self spacingSnapOnAxis:&by
                                              selMin:adjSMinY
                                              selMax:adjSMaxY
                                            crossMid:midX
                                           threshold:spThresh];
    if (ry.snapped) {
      delta.y += ry.deltaAdj;
      self.spacingSnapY = YES;
      self.spacingTopEdge = ry.snapStart;
      self.spacingSelTop = ry.snapSelMin;
      self.spacingSelBottom = ry.snapSelMax;
      self.spacingBottomEdge = ry.snapEnd;
      self.spacingMidX = ry.snapCrossMid;
      self.spacingRefY = ry.hasRef;
      self.spacingRefTopY = ry.refStart;
      self.spacingRefBottomY = ry.refEnd;
      self.spacingRefMidXY = ry.refCrossMid;
    }

    KKAxisBoundsFree(&bx);
    KKAxisBoundsFree(&by);
  }

  return delta;
}

- (simd_float2)alignSnapPoint:(simd_float2)point
               excludingPaths:(nullable NSIndexSet *)excluded
              excludingPoints:(nullable NSIndexSet *)excludedPoints {
  self.alignSnappedX = NO;
  self.alignSnappedY = NO;
  self.spacingSnapX = NO;
  self.spacingSnapY = NO;
  self.spacingRefX = NO;
  self.spacingRefY = NO;

  BOOL snapActive = self.cmdSnapOverride ? !self.snapToGrid : self.snapToGrid;
  if (!snapActive || self.gridEnabled)
    return point;
  if (self.imageWidth <= 0 || self.imageHeight <= 0)
    return point;

  float thresh = [self snapThresholdForCanvasPixels:8.0f];

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

  float matchedX = point.x, adjX = 0;
  float matchedY = point.y, adjY = 0;
  float px = point.x, py = point.y;
  if (findBestSnap(targetXs, txCount, &px, 1, thresh, &matchedX, &adjX)) {
    self.alignSnappedX = YES;
    self.alignSnapValueX = matchedX;
    point.x = matchedX;
  }
  if (findBestSnap(targetYs, tyCount, &py, 1, thresh, &matchedY, &adjY)) {
    self.alignSnappedY = YES;
    self.alignSnapValueY = matchedY;
    point.y = matchedY;
  }

  free(targetXs);
  free(targetYs);
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

@end
