/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MarkerTessellation.h"
#import "OSC_Private.h"

/// Fold a single (pMin,pMax) into a running bbox. On first call (`*found ==
/// NO`) seeds the accumulator; subsequent calls expand it with fminf/fmaxf.
static inline void _kkExpandBounds(BOOL *found, float *minX, float *minY,
                                   float *maxX, float *maxY, simd_float2 pMin,
                                   simd_float2 pMax) {
  if (!*found) {
    *minX = pMin.x;
    *minY = pMin.y;
    *maxX = pMax.x;
    *maxY = pMax.y;
    *found = YES;
  } else {
    *minX = fminf(*minX, pMin.x);
    *minY = fminf(*minY, pMin.y);
    *maxX = fmaxf(*maxX, pMax.x);
    *maxY = fmaxf(*maxY, pMax.y);
  }
}

static BOOL pointInTriangle(double px, double py, simd_float2 a, simd_float2 b,
                            simd_float2 c) {
  double d1 = (px - b.x) * (a.y - b.y) - (a.x - b.x) * (py - b.y);
  double d2 = (px - c.x) * (b.y - c.y) - (b.x - c.x) * (py - c.y);
  double d3 = (px - a.x) * (c.y - a.y) - (c.x - a.x) * (py - a.y);
  BOOL hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0);
  BOOL hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0);
  return !(hasNeg && hasPos);
}

static BOOL hitTestMarkerVerts(double px, double py, CanvasVertex *verts,
                               NSUInteger count, MTLPrimitiveType prim) {
  if (prim == MTLPrimitiveTypeTriangleStrip) {
    for (NSUInteger i = 0; i + 2 < count; i++) {
      if (pointInTriangle(px, py, verts[i].position, verts[i + 1].position,
                          verts[i + 2].position))
        return YES;
    }
  } else if (prim == MTLPrimitiveTypeTriangle) {
    for (NSUInteger i = 0; i + 2 < count; i += 3) {
      if (pointInTriangle(px, py, verts[i].position, verts[i + 1].position,
                          verts[i + 2].position))
        return YES;
    }
  }
  return NO;
}

static BOOL markerHitTest(CanvasOSC *osc, KKBezierPath *path, double px,
                          double py) {
  simd_float2 mouseObj = [osc objectPointFromCanvasPoint:CGPointMake(px, py)];

  // strokeWidth is in source pixels; convert to object space.
  float imgW = (osc.imageWidth > 0) ? osc.imageWidth : 1920.0f;
  float sw = path.strokeWidth / imgW;
  float ew = (path.endWidth > 0) ? path.endWidth / imgW : sw;

  if (path.endMarker != 0) {
    NSUInteger lastSeg = path.count - 2;
    NSUInteger lastIdx = path.count - 1;
    simd_float2 endPt = [path evaluatePointAtIndex:lastSeg
                                         nextIndex:lastIdx
                                               atT:1.0f];
    simd_float2 nearPt = [path evaluatePointAtIndex:lastSeg
                                          nextIndex:lastIdx
                                                atT:0.98f];
    simd_float2 dir = endPt - nearPt;
    float dirLen = simd_length(dir);
    simd_float2 eTan =
        dirLen > 0.001f ? dir / dirLen : (simd_float2){1.0f, 0.0f};
    simd_float2 eNorm = (simd_float2){-eTan.y, eTan.x};
    float eMsz = ew * path.endMarkerSize;

    CanvasVertex markerVerts[256];
    MTLPrimitiveType prim;
    NSUInteger mc = KKTessellateMarker(path.endMarker, endPt, eTan, eNorm, eMsz,
                                       ew, &prim, markerVerts);
    if (mc > 0 &&
        hitTestMarkerVerts(mouseObj.x, mouseObj.y, markerVerts, mc, prim))
      return YES;
  }

  if (path.startMarker != 0) {
    simd_float2 startPt = [path evaluatePointAtIndex:0 nextIndex:1 atT:0.0f];
    simd_float2 nearPt = [path evaluatePointAtIndex:0 nextIndex:1 atT:0.02f];
    simd_float2 dir = startPt - nearPt;
    float dirLen = simd_length(dir);
    simd_float2 sTan =
        dirLen > 0.001f ? dir / dirLen : (simd_float2){-1.0f, 0.0f};
    simd_float2 sNorm = (simd_float2){-sTan.y, sTan.x};
    float sMsz = sw * path.startMarkerSize;

    CanvasVertex markerVerts[256];
    MTLPrimitiveType prim;
    NSUInteger mc = KKTessellateMarker(path.startMarker, startPt, sTan, sNorm,
                                       sMsz, sw, &prim, markerVerts);
    if (mc > 0 &&
        hitTestMarkerVerts(mouseObj.x, mouseObj.y, markerVerts, mc, prim))
      return YES;
  }

  return NO;
}

@implementation CanvasOSC (Geometry)

- (NSInteger)pathIndexNearX:(double)x y:(double)y radius:(double)radius {
  // Convert mouse to object space for proximity checks.  Canvas-space
  // coordinates diverge from mouse coordinates at high FCP viewer zoom,
  // making distance checks unreliable.  Object space is stable.
  simd_float2 mouseObj = [self objectPointFromCanvasPoint:CGPointMake(x, y)];

  // Distance comparisons happen in *source-pixel* space because object space
  // is non-uniform (x normalized by imageWidth, y by imageHeight). An
  // isotropic radius in object space becomes an ellipse on screen - fat in
  // x, thin in y - so top/bottom edges of strokes miss while left/right hit.
  double imgW = (self.imageWidth > 0) ? (double)self.imageWidth : 1.0;
  double imgH = (self.imageHeight > 0) ? (double)self.imageHeight : 1.0;

  // Convert 4 screen-pixels of slop to source pixels in each axis, then take
  // the larger so the tolerance is forgiving in whichever direction is more
  // zoomed-out.
  simd_float2 padRefX =
      [self objectPointFromCanvasPoint:CGPointMake(x + 4.0, y)];
  simd_float2 padRefY =
      [self objectPointFromCanvasPoint:CGPointMake(x, y + 4.0)];
  double padPxX = fabs(padRefX.x - mouseObj.x) * imgW;
  double padPxY = fabs(padRefY.y - mouseObj.y) * imgH;
  double padPx = fmax(padPxX, padPxY);

  KKLogInfo(@"hitTest@(%.1f,%.1f) mouseObj=(%.4f,%.4f) imgW=%.1f imgH=%.1f "
            @"padPx=(%.2f,%.2f) paths=%lu",
            x, y, mouseObj.x, mouseObj.y, imgW, imgH, padPxX, padPxY,
            (unsigned long)self.paths.count);

  for (NSUInteger p = 0; p < self.paths.count; p++) {
    KKBezierPath *path = self.paths[p];
    if (path.hidden || path.locked || path.isGroup) {
      KKLogInfo(@"  path[%lu] skipped hidden=%d locked=%d group=%d",
                (unsigned long)p, path.hidden, path.locked, path.isGroup);
      continue;
    }

    KKLogInfo(@"  path[%lu] isImage=%d closed=%d count=%lu strokeW=%.2f "
              @"endW=%.2f fill=%d",
              (unsigned long)p, path.isImage, path.closed,
              (unsigned long)path.count, path.strokeWidth, path.endWidth,
              path.fillEnabled);

    if (path.isImage && path.count >= 4) {
      KKBezierPoint bl = [path pointAtIndex:0];
      KKBezierPoint tr = [path pointAtIndex:2];
      if (mouseObj.x >= MIN(bl.x, tr.x) && mouseObj.x <= MAX(bl.x, tr.x) &&
          mouseObj.y >= MIN(bl.y, tr.y) && mouseObj.y <= MAX(bl.y, tr.y))
        return (NSInteger)p;
      continue;
    }

    // strokeWidth/endWidth are in source pixels.
    // endWidth taper is only meaningful for open paths (per KKBezierPath.h);
    // closed paths can have stale endWidth values that must be ignored.
    double halfPx0 = path.strokeWidth * 0.5;
    double halfPx1 =
        (!path.closed && path.endWidth > 0) ? path.endWidth * 0.5 : halfPx0;

    NSUInteger contours = path.contourCount;

    for (NSUInteger ci = 0; ci < contours; ci++) {
      NSRange range = [path contourRangeAtIndex:ci];
      NSUInteger start = range.location;
      NSUInteger len = range.length;
      if (len < 2)
        continue;

      NSUInteger segCount = len - 1;
      if (path.closed && len >= 2)
        segCount = len;

      NSUInteger totalSamples = segCount * 65;
      simd_float2 *outline = malloc(totalSamples * sizeof(simd_float2));
      NSUInteger oc = 0;
      for (NSUInteger c = 0; c < segCount; c++) {
        NSUInteger curIdx = start + c;
        NSUInteger nextIdx = start + ((c + 1) % len);
        for (NSUInteger s = 0; s <= 64; s++) {
          float t = (float)s / 64.0f;
          outline[oc++] = [path evaluatePointAtIndex:curIdx
                                           nextIndex:nextIdx
                                                 atT:t];
        }
      }

      double minDistPx = INFINITY;
      double minHitRPx = 0.0;
      NSUInteger minIdx = 0;
      for (NSUInteger i = 0; i < oc; i++) {
        double t = (oc > 1) ? ((double)i / (double)(oc - 1)) : 0.0;
        double halfPx = halfPx0 + (halfPx1 - halfPx0) * t;
        double hitRPx = fmax(halfPx + padPx, padPx * 3.0);
        double dxPx = (mouseObj.x - outline[i].x) * imgW;
        double dyPx = (mouseObj.y - outline[i].y) * imgH;
        double dPx = hypot(dxPx, dyPx);
        if (dPx < minDistPx) {
          minDistPx = dPx;
          minHitRPx = hitRPx;
          minIdx = i;
        }
        if (dPx < hitRPx) {
          free(outline);
          KKLogInfo(@"  path[%lu] HIT contour=%lu i=%lu distPx=%.2f "
                    @"hitRPx=%.2f",
                    (unsigned long)p, (unsigned long)ci, (unsigned long)i, dPx,
                    hitRPx);
          return (NSInteger)p;
        }
      }
      KKLogInfo(@"  path[%lu] contour=%lu MISS minDistPx=%.2f hitRPx=%.2f "
                @"closestSample=(%.4f,%.4f) idx=%lu halfPx0=%.2f halfPx1=%.2f",
                (unsigned long)p, (unsigned long)ci, minDistPx, minHitRPx,
                outline[minIdx].x, outline[minIdx].y, (unsigned long)minIdx,
                halfPx0, halfPx1);

      if (path.fillEnabled && oc >= 2) {
        NSUInteger crossings = 0;
        for (NSUInteger i = 0; i < oc; i++) {
          NSUInteger j = (i + 1) % oc;
          float yi = outline[i].y, yj = outline[j].y;
          if ((yi <= mouseObj.y && yj > mouseObj.y) ||
              (yj <= mouseObj.y && yi > mouseObj.y)) {
            float xi = outline[i].x, xj = outline[j].x;
            float intersectX = xi + (mouseObj.y - yi) / (yj - yi) * (xj - xi);
            if (mouseObj.x < intersectX)
              crossings++;
          }
        }
        if (crossings & 1) {
          free(outline);
          return (NSInteger)p;
        }
      }

      free(outline);
    }

    if (!path.closed && path.count >= 2 &&
        (path.startMarker != 0 || path.endMarker != 0)) {
      if (markerHitTest(self, path, x, y))
        return (NSInteger)p;
    }
  }
  return -1;
}

- (NSInteger)segmentIndexNearX:(double)x
                             y:(double)y
                        radius:(double)radius
                        inPath:(KKBezierPath *)path {
  if (!path || path.count < 2)
    return -1;
  simd_float2 mouseObj = [self objectPointFromCanvasPoint:CGPointMake(x, y)];
  simd_float2 padRef =
      [self objectPointFromCanvasPoint:CGPointMake(x + 4.0, y)];
  double objPad = fabs(padRef.x - mouseObj.x);
  double objStrokeHalf =
      (self.imageWidth > 0) ? (path.strokeWidth * 0.5 / self.imageWidth) : 0.0;
  double objRadius = fmax(objStrokeHalf + objPad, objPad * 3.0);
  NSUInteger segCount = path.count - 1;
  if (path.closed && path.count >= 2)
    segCount = path.count;
  for (NSUInteger c = 0; c < segCount; c++) {
    NSUInteger nextIdx = (c + 1) % path.count;
    for (NSUInteger s = 0; s <= 64; s++) {
      float t = (float)s / 64.0f;
      simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      if (hypot(mouseObj.x - pos.x, mouseObj.y - pos.y) < objRadius)
        return (NSInteger)c;
    }
  }
  return -1;
}

- (void)boundsOfPath:(KKBezierPath *)path
                 min:(simd_float2 *)outMin
                 max:(simd_float2 *)outMax {
  if (path.count == 0)
    return;
  NSUInteger segCount = path.count - 1;
  if (path.closed && path.count >= 2)
    segCount = path.count;

  simd_float2 first = [path evaluatePointAtIndex:0 nextIndex:0 atT:0.0f];
  float minX = first.x, minY = first.y, maxX = first.x, maxY = first.y;

  for (NSUInteger c = 0; c < segCount; c++) {
    NSUInteger nextIdx = (c + 1) % path.count;
    for (NSUInteger s = 0; s <= 16; s++) {
      float t = (float)s / 16.0f;
      simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      minX = fminf(minX, pos.x);
      minY = fminf(minY, pos.y);
      maxX = fmaxf(maxX, pos.x);
      maxY = fmaxf(maxY, pos.y);
    }
  }
  *outMin = (simd_float2){minX, minY};
  *outMax = (simd_float2){maxX, maxY};
}

- (BOOL)boundsOfGroup:(KKBezierPath *)group
                  min:(simd_float2 *)outMin
                  max:(simd_float2 *)outMax {
  if (!group.isGroup || group.groupID.length == 0)
    return NO;
  NSMutableSet<NSString *> *frontier =
      [NSMutableSet setWithObject:group.groupID];
  __block BOOL found = NO;
  __block float minX = 0, minY = 0, maxX = 0, maxY = 0;
  // Descendants may be sub-groups; walk breadth-first by expanding the
  // frontier until no new groupIDs are added.
  BOOL grew;
  do {
    grew = NO;
    for (KKBezierPath *p in self.paths) {
      if (!p.parentGroupID.length || ![frontier containsObject:p.parentGroupID])
        continue;
      if (p.isGroup) {
        if (p.groupID.length && ![frontier containsObject:p.groupID]) {
          [frontier addObject:p.groupID];
          grew = YES;
        }
        continue;
      }
      if (p.count == 0)
        continue;
      simd_float2 pMin, pMax;
      [self boundsOfPath:p min:&pMin max:&pMax];
      _kkExpandBounds(&found, &minX, &minY, &maxX, &maxY, pMin, pMax);
    }
  } while (grew);
  if (found) {
    *outMin = (simd_float2){minX, minY};
    *outMax = (simd_float2){maxX, maxY};
  }
  return found;
}

- (BOOL)boundsOfSelectedPaths:(simd_float2 *)outMin max:(simd_float2 *)outMax {
  __block BOOL found = NO;
  __block float minX, minY, maxX, maxY;
  [self.selectedPathIndices
      enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx >= self.paths.count)
          return;
        KKBezierPath *path = self.paths[idx];
        if (path.count == 0)
          return;
        simd_float2 pMin, pMax;
        [self boundsOfPath:path min:&pMin max:&pMax];
        _kkExpandBounds(&found, &minX, &minY, &maxX, &maxY, pMin, pMax);
      }];
  if (found) {
    *outMin = (simd_float2){minX, minY};
    *outMax = (simd_float2){maxX, maxY};
  }
  return found;
}

- (CGPoint)cornerRadiusHandlePosition:(NSInteger)corner
                              forPath:(KKBezierPath *)path {
  simd_float2 bmin, bmax;
  [self boundsOfPath:path min:&bmin max:&bmax];
  CGPoint minC = [self canvasPointFromObjectPoint:bmin];
  CGPoint maxC = [self canvasPointFromObjectPoint:bmax];
  float inset = (float)[self strokeWidth] * 0.5f + 20.0f;
  float halfShort =
      fminf((float)fabs(maxC.x - minC.x), (float)fabs(maxC.y - minC.y)) * 0.5f;
  float travel = fminf(100.0f, fmaxf(0.0f, halfShort - inset));

  simd_float4 fracs = path.rectShape.radii;
  float f = fracs[corner];
  float offset = inset + f * travel;

  switch (corner) {
  case 0:
    return (CGPoint){minC.x + offset, maxC.y - offset};
  case 1:
    return (CGPoint){maxC.x - offset, maxC.y - offset};
  case 2:
    return (CGPoint){maxC.x - offset, minC.y + offset};
  case 3:
    return (CGPoint){minC.x + offset, minC.y + offset};
  default:
    return CGPointZero;
  }
}

- (CGPoint)resizeHandlePosition:(NSInteger)index
                       topRight:(CGPoint)tr
                     bottomLeft:(CGPoint)bl {
  double mx = (tr.x + bl.x) * 0.5;
  double my = (tr.y + bl.y) * 0.5;
  switch (index) {
  case 0:
    return (CGPoint){bl.x, tr.y};
  case 1:
    return (CGPoint){mx, tr.y};
  case 2:
    return (CGPoint){tr.x, tr.y};
  case 3:
    return (CGPoint){tr.x, my};
  case 4:
    return (CGPoint){tr.x, bl.y};
  case 5:
    return (CGPoint){mx, bl.y};
  case 6:
    return (CGPoint){bl.x, bl.y};
  case 7:
    return (CGPoint){bl.x, my};
  default:
    return CGPointZero;
  }
}

- (simd_float2)bboxCenterOfPath:(KKBezierPath *)path {
  simd_float2 bmin = (simd_float2){0, 0}, bmax = (simd_float2){0, 0};
  if (path.isGroup) {
    if (![self boundsOfGroup:path min:&bmin max:&bmax])
      return (simd_float2){0.5f, 0.5f};
  } else {
    [self boundsOfPath:path min:&bmin max:&bmax];
  }
  return (bmin + bmax) * 0.5f;
}

- (KKBezierPath *)selectedTransformablePath {
  if (self.selectedPathIndices.count != 1)
    return nil;
  NSUInteger idx = self.selectedPathIndices.firstIndex;
  if (idx >= self.paths.count)
    return nil;
  KKBezierPath *p = self.paths[idx];
  if (p.locked || !p.transformEnabled)
    return nil;
  if (p.isGroup) {
    simd_float2 unused1, unused2;
    if (![self boundsOfGroup:p min:&unused1 max:&unused2])
      return nil;
  }
  return p;
}

@end
