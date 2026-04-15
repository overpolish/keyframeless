/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"

@implementation CanvasOSC (Geometry)

- (NSInteger)pathIndexNearX:(double)x y:(double)y radius:(double)radius {
  for (NSUInteger p = 0; p < self.paths.count; p++) {
    KKBezierPath *path = self.paths[p];
    if (path.hidden || path.locked || path.isGroup)
      continue;

    NSUInteger segCount = path.count - 1;
    if (path.closed && path.count >= 2)
      segCount = path.count;

    NSUInteger totalSamples = segCount * 64 + segCount;
    CGPoint *outline = malloc(totalSamples * sizeof(CGPoint));
    NSUInteger oc = 0;
    for (NSUInteger c = 0; c < segCount; c++) {
      NSUInteger nextIdx = (c + 1) % path.count;
      for (NSUInteger s = 0; s <= 64; s++) {
        float t = (float)s / 64.0f;
        simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
        outline[oc++] = [self canvasPointFromObjectPoint:pos];
      }
    }

    double hitR = MAX(path.strokeWidth * 0.5 + 4.0, 12.0);
    for (NSUInteger i = 0; i < oc; i++) {
      if (hypot(x - outline[i].x, y - outline[i].y) < hitR) {
        free(outline);
        return (NSInteger)p;
      }
    }

    if (path.fillEnabled && oc >= 3) {
      NSUInteger crossings = 0;
      for (NSUInteger i = 0; i < oc; i++) {
        NSUInteger j = (i + 1) % oc;
        CGFloat yi = outline[i].y, yj = outline[j].y;
        if ((yi <= y && yj > y) || (yj <= y && yi > y)) {
          CGFloat xi = outline[i].x, xj = outline[j].x;
          CGFloat intersectX = xi + (y - yi) / (yj - yi) * (xj - xi);
          if (x < intersectX)
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
  return -1;
}

- (NSInteger)segmentIndexNearX:(double)x
                             y:(double)y
                        radius:(double)radius
                        inPath:(KKBezierPath *)path {
  if (!path || path.count < 2)
    return -1;
  NSUInteger segCount = path.count - 1;
  if (path.closed && path.count >= 2)
    segCount = path.count;
  for (NSUInteger c = 0; c < segCount; c++) {
    NSUInteger nextIdx = (c + 1) % path.count;
    for (NSUInteger s = 0; s <= 64; s++) {
      float t = (float)s / 64.0f;
      simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      CGPoint cur = [self canvasPointFromObjectPoint:pos];
      if (hypot(x - cur.x, y - cur.y) < radius)
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
        if (!found) {
          minX = pMin.x;
          minY = pMin.y;
          maxX = pMax.x;
          maxY = pMax.y;
          found = YES;
        } else {
          minX = fminf(minX, pMin.x);
          minY = fminf(minY, pMin.y);
          maxX = fmaxf(maxX, pMax.x);
          maxY = fmaxf(maxY, pMax.y);
        }
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

  float fracs[4] = {path.cornerRadiusTL, path.cornerRadiusTR,
                    path.cornerRadiusBR, path.cornerRadiusBL};
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

@end
