/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "SketchFill.h"
#import <simd/simd.h>

static const NSUInteger kSegsPerCurve = 64;

/// Sample the path outline into a dense polygon in pixel space.
/// Multiple contours are stored sequentially; outContourStarts and
/// outContourCount describe where each contour begins so that
/// scanlineIntersections can avoid creating edges between contours.
/// Caller must free outPoly and outContourStarts.
static NSUInteger sampleOutline(KKBezierPath *path, float outputWidth,
                                float outputHeight, simd_float2 **outPoly,
                                NSUInteger **outContourStarts,
                                NSUInteger *outContourCount) {
  NSUInteger nc = path.contourCount;
  NSUInteger totalMax = 0;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
    totalMax += r.length * kSegsPerCurve + 1;
  }

  simd_float2 *poly = malloc(totalMax * sizeof(simd_float2));
  NSUInteger *contourStarts = malloc((nc + 1) * sizeof(NSUInteger));
  NSUInteger n = 0;

  for (NSUInteger ci = 0; ci < nc; ci++) {
    contourStarts[ci] = n;
    NSRange r = [path contourRangeAtIndex:ci];
    NSUInteger cStart = r.location;
    NSUInteger cLen = r.length;
    BOOL isClosed = path.closed;
    NSUInteger curveCount = isClosed ? cLen : (cLen > 0 ? cLen - 1 : 0);

    for (NSUInteger c = 0; c < curveCount; c++) {
      NSUInteger idx = cStart + c;
      NSUInteger nextIdx =
          isClosed ? cStart + ((c + 1) % cLen) : (cStart + c + 1);
      for (NSUInteger s = 0; s < kSegsPerCurve; s++) {
        float t = (float)s / (float)kSegsPerCurve;
        simd_float2 pos = [path evaluatePointAtIndex:idx
                                           nextIndex:nextIdx
                                                 atT:t];
        poly[n++] = (simd_float2){pos.x * outputWidth, pos.y * outputHeight};
      }
    }
    if (!isClosed && curveCount > 0) {
      NSUInteger lastIdx = cStart + curveCount - 1;
      NSUInteger lastNext = cStart + curveCount;
      simd_float2 pos = [path evaluatePointAtIndex:lastIdx
                                         nextIndex:lastNext
                                               atT:1.0f];
      poly[n++] = (simd_float2){pos.x * outputWidth, pos.y * outputHeight};
    }
  }
  contourStarts[nc] = n; // sentinel

  *outPoly = poly;
  *outContourStarts = contourStarts;
  *outContourCount = nc;
  return n;
}

/// Rotate a point around a center by angle (radians).
static simd_float2 rotatePoint(simd_float2 p, simd_float2 center, float cos_a,
                               float sin_a) {
  float dx = p.x - center.x;
  float dy = p.y - center.y;
  return (simd_float2){center.x + dx * cos_a - dy * sin_a,
                       center.y + dx * sin_a + dy * cos_a};
}

/// Compute intersections of a horizontal scanline at y with the polygon edges.
/// Contour boundaries are respected so that edges are only formed within each
/// closed contour, not between the last point of one and the first of the next.
/// Returns the number of intersections found. xs must be large enough.
static NSUInteger scanlineIntersections(const simd_float2 *poly, NSUInteger n,
                                        float y, float *xs,
                                        const NSUInteger *contourStarts,
                                        NSUInteger contourCount) {
  NSUInteger count = 0;
  for (NSUInteger ci = 0; ci < contourCount; ci++) {
    NSUInteger cStart = contourStarts[ci];
    NSUInteger cEnd = contourStarts[ci + 1];
    NSUInteger cLen = cEnd - cStart;
    if (cLen < 2)
      continue;
    for (NSUInteger i = 0; i < cLen; i++) {
      NSUInteger ai = cStart + i;
      NSUInteger bi = cStart + ((i + 1) % cLen);
      float y0 = poly[ai].y, y1 = poly[bi].y;
      if ((y0 <= y && y1 > y) || (y1 <= y && y0 > y)) {
        float t = (y - y0) / (y1 - y0);
        xs[count++] = poly[ai].x + t * (poly[bi].x - poly[ai].x);
      }
    }
  }
  // Sort intersections.
  for (NSUInteger a = 0; a < count; a++) {
    for (NSUInteger b = a + 1; b < count; b++) {
      if (xs[b] < xs[a]) {
        float tmp = xs[a];
        xs[a] = xs[b];
        xs[b] = tmp;
      }
    }
  }
  return count;
}

// Seeded PRNG for scanline jitter (xorshift32). Returns float in [-1, 1).
static uint32_t s_fillRNG;

static void fillSeedRNG(uint32_t seed) { s_fillRNG = seed ? seed : 1; }

static float fillRand(void) {
  s_fillRNG ^= s_fillRNG << 13;
  s_fillRNG ^= s_fillRNG >> 17;
  s_fillRNG ^= s_fillRNG << 5;
  return (float)(s_fillRNG & 0xFFFF) / 32768.0f - 1.0f; // [-1, 1)
}

NSUInteger KKGenerateHachureLines(KKBezierPath *path, float outputWidth,
                                  float outputHeight, uint8_t fillStyle,
                                  float gap, float angle, float roughness,
                                  uint32_t seed, KKHachureLine **outLines) {
  if (path.count < 3 || gap < 1.0f) {
    *outLines = NULL;
    return 0;
  }

  // Sample the outline (contour-aware).
  simd_float2 *poly = NULL;
  NSUInteger *contourStarts = NULL;
  NSUInteger contourCount = 0;
  NSUInteger polyCount = sampleOutline(path, outputWidth, outputHeight, &poly,
                                       &contourStarts, &contourCount);
  if (polyCount < 3) {
    free(poly);
    free(contourStarts);
    *outLines = NULL;
    return 0;
  }

  // Negate angle to correct for Y-down pixel space.
  float cos_a = cosf(-angle);
  float sin_a = sinf(-angle);

  // Compute center of polygon.
  simd_float2 center = {0, 0};
  for (NSUInteger i = 0; i < polyCount; i++)
    center += poly[i];
  center /= (float)polyCount;

  // Rotate polygon so hachure lines are horizontal.
  simd_float2 *rotPoly = malloc(polyCount * sizeof(simd_float2));
  float minY = HUGE_VALF, maxY = -HUGE_VALF;
  for (NSUInteger i = 0; i < polyCount; i++) {
    rotPoly[i] = rotatePoint(poly[i], center, cos_a, sin_a);
    if (rotPoly[i].y < minY)
      minY = rotPoly[i].y;
    if (rotPoly[i].y > maxY)
      maxY = rotPoly[i].y;
  }

  // Generate scanlines.
  NSUInteger maxLines = (NSUInteger)((maxY - minY) / gap + 1) * 4;
  KKHachureLine *lines = malloc(maxLines * sizeof(KKHachureLine));
  NSUInteger lineCount = 0;

  // Seed the RNG for deterministic scanline jitter.
  fillSeedRNG(seed ^ 0xABCD5678);
  // Jitter magnitude: up to 40% of gap at roughness=1, scaled by roughness.
  float jitterAmt = gap * 0.4f * fminf(roughness, 3.0f) / 3.0f;

  float *xs = malloc((polyCount + 2) * sizeof(float));

  for (float y = minY + gap; y < maxY; y += gap) {
    float scanY = y + (roughness > 0.0001f ? fillRand() * jitterAmt : 0.0f);
    NSUInteger xCount = scanlineIntersections(rotPoly, polyCount, scanY, xs,
                                              contourStarts, contourCount);
    // Pair up intersections: each consecutive pair is a fill line.
    for (NSUInteger k = 0; k + 1 < xCount; k += 2) {
      if (lineCount >= maxLines) {
        maxLines *= 2;
        lines = realloc(lines, maxLines * sizeof(KKHachureLine));
      }
      // Rotate the endpoints back to original space.
      simd_float2 a = {xs[k], scanY};
      simd_float2 b = {xs[k + 1], scanY};
      lines[lineCount].a = rotatePoint(a, center, cos_a, -sin_a);
      lines[lineCount].b = rotatePoint(b, center, cos_a, -sin_a);
      lineCount++;
    }
  }

  free(xs);
  free(rotPoly);
  free(poly);

  // Cross-hatch: duplicate all lines at angle + 90 degrees.
  if (fillStyle == 2) {
    float angle2 = -angle + (float)(M_PI / 2.0);
    float cos_b = cosf(angle2);
    float sin_b = sinf(angle2);

    simd_float2 *poly2 = NULL;
    NSUInteger *contourStarts2 = NULL;
    NSUInteger contourCount2 = 0;
    NSUInteger poly2Count =
        sampleOutline(path, outputWidth, outputHeight, &poly2, &contourStarts2,
                      &contourCount2);
    simd_float2 *rotPoly2 = malloc(poly2Count * sizeof(simd_float2));
    float minY2 = HUGE_VALF, maxY2 = -HUGE_VALF;
    for (NSUInteger i = 0; i < poly2Count; i++) {
      rotPoly2[i] = rotatePoint(poly2[i], center, cos_b, sin_b);
      if (rotPoly2[i].y < minY2)
        minY2 = rotPoly2[i].y;
      if (rotPoly2[i].y > maxY2)
        maxY2 = rotPoly2[i].y;
    }

    float *xs2 = malloc((poly2Count + 2) * sizeof(float));
    for (float y = minY2 + gap; y < maxY2; y += gap) {
      float scanY2 = y + (roughness > 0.0001f ? fillRand() * jitterAmt : 0.0f);
      NSUInteger xCount = scanlineIntersections(
          rotPoly2, poly2Count, scanY2, xs2, contourStarts2, contourCount2);
      for (NSUInteger k = 0; k + 1 < xCount; k += 2) {
        if (lineCount >= maxLines) {
          maxLines *= 2;
          lines = realloc(lines, maxLines * sizeof(KKHachureLine));
        }
        simd_float2 a = {xs2[k], scanY2};
        simd_float2 b = {xs2[k + 1], scanY2};
        lines[lineCount].a = rotatePoint(a, center, cos_b, -sin_b);
        lines[lineCount].b = rotatePoint(b, center, cos_b, -sin_b);
        lineCount++;
      }
    }
    free(xs2);
    free(rotPoly2);
    free(poly2);
    free(contourStarts2);
  }

  free(contourStarts);

  // Zigzag: connect consecutive line endpoints.
  if (fillStyle == 3 && lineCount > 1) {
    NSUInteger zigCount = lineCount + (lineCount - 1);
    KKHachureLine *zigLines = malloc(zigCount * sizeof(KKHachureLine));
    NSUInteger zi = 0;
    for (NSUInteger i = 0; i < lineCount; i++) {
      zigLines[zi++] = lines[i];
      if (i + 1 < lineCount) {
        // Connect end of this line to start of next.
        zigLines[zi].a = lines[i].b;
        zigLines[zi].b = lines[i + 1].a;
        zi++;
      }
    }
    free(lines);
    lines = zigLines;
    lineCount = zi;
  }

  *outLines = lines;
  return lineCount;
}
