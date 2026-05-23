/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "SketchFill.h"
#import <simd/simd.h>

static const NSUInteger kSegsPerCurve = 16;

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

static int compareFloats(const void *a, const void *b) {
  float fa = *(const float *)a;
  float fb = *(const float *)b;
  return (fa > fb) - (fa < fb);
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
  qsort(xs, count, sizeof(float), compareFloats);
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

// --- Fill geometry cache ---
// Direct-mapped cache keyed by a hash of path geometry + fill parameters.
// Avoids regenerating hachure lines when inputs haven't changed.

#define FILL_CACHE_SIZE 64

typedef struct {
  uint64_t key;
  KKHachureLine *lines;
  NSUInteger lineCount;
} KKFillCacheEntry;

static KKFillCacheEntry s_fillCache[FILL_CACHE_SIZE];

static uint64_t fillCacheKey(KKBezierPath *path, float outputWidth,
                             float outputHeight, uint8_t fillStyle, float gap,
                             float angle, float roughness, uint32_t seed) {
  // FNV-1a 64-bit hash over the distinguishing inputs.
  uint64_t h = 14695981039346656037ULL;
#define FNV_MIX(bytes, len)                                                    \
  do {                                                                         \
    const uint8_t *_p = (const uint8_t *)(bytes);                              \
    for (NSUInteger _i = 0; _i < (len); _i++) {                                \
      h ^= _p[_i];                                                             \
      h *= 1099511628211ULL;                                                   \
    }                                                                          \
  } while (0)

  // Path geometry fingerprint: point count, closed flag, contour count,
  // and first/last point coordinates.
  NSUInteger cnt = path.count;
  BOOL closed = path.closed;
  NSUInteger cc = path.contourCount;
  FNV_MIX(&cnt, sizeof(cnt));
  FNV_MIX(&closed, sizeof(closed));
  FNV_MIX(&cc, sizeof(cc));
  if (cnt > 0) {
    KKBezierPoint first = [path pointAtIndex:0];
    KKBezierPoint last = [path pointAtIndex:cnt - 1];
    FNV_MIX(&first, sizeof(first));
    FNV_MIX(&last, sizeof(last));
  }
  FNV_MIX(&outputWidth, sizeof(outputWidth));
  FNV_MIX(&outputHeight, sizeof(outputHeight));
  FNV_MIX(&fillStyle, sizeof(fillStyle));
  FNV_MIX(&gap, sizeof(gap));
  FNV_MIX(&angle, sizeof(angle));
  FNV_MIX(&roughness, sizeof(roughness));
  FNV_MIX(&seed, sizeof(seed));
#undef FNV_MIX
  if (h == 0)
    h = 1; // reserve 0 as "empty slot"
  return h;
}

NSUInteger KKGenerateHachureLines(KKBezierPath *path, float outputWidth,
                                  float outputHeight, uint8_t fillStyle,
                                  float gap, float angle, float roughness,
                                  uint32_t seed, KKHachureLine **outLines) {
  if (path.count < 3 || gap < 1.0f) {
    *outLines = NULL;
    return 0;
  }

  // Check cache.
  uint64_t key = fillCacheKey(path, outputWidth, outputHeight, fillStyle, gap,
                              angle, roughness, seed);
  NSUInteger slot = (NSUInteger)(key % FILL_CACHE_SIZE);
  KKFillCacheEntry *ce = &s_fillCache[slot];
  if (ce->key == key && ce->lines) {
    // Cache hit - return a copy so caller can free independently.
    NSUInteger bytes = ce->lineCount * sizeof(KKHachureLine);
    KKHachureLine *copy = malloc(bytes);
    memcpy(copy, ce->lines, bytes);
    *outLines = copy;
    return ce->lineCount;
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

  // Cross-hatch: add lines at angle + 90 degrees, reusing the sampled polygon.
  if (fillStyle == 2) {
    float angle2 = -angle + (float)(M_PI / 2.0);
    float cos_b = cosf(angle2);
    float sin_b = sinf(angle2);

    simd_float2 *rotPoly2 = malloc(polyCount * sizeof(simd_float2));
    float minY2 = HUGE_VALF, maxY2 = -HUGE_VALF;
    for (NSUInteger i = 0; i < polyCount; i++) {
      rotPoly2[i] = rotatePoint(poly[i], center, cos_b, sin_b);
      if (rotPoly2[i].y < minY2)
        minY2 = rotPoly2[i].y;
      if (rotPoly2[i].y > maxY2)
        maxY2 = rotPoly2[i].y;
    }

    float *xs2 = malloc((polyCount + 2) * sizeof(float));
    for (float y = minY2 + gap; y < maxY2; y += gap) {
      float scanY2 = y + (roughness > 0.0001f ? fillRand() * jitterAmt : 0.0f);
      NSUInteger xCount = scanlineIntersections(
          rotPoly2, polyCount, scanY2, xs2, contourStarts, contourCount);
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
  }

  free(contourStarts);
  free(poly);

  // Zigzag: replace each hachure line with a zigzag wave along its length.
  if (fillStyle == 3 && lineCount > 0) {
    float zigAmp = gap * 0.5f;
    float zigPeriod = gap;
    NSUInteger maxZigLines = 0;
    for (NSUInteger i = 0; i < lineCount; i++) {
      float dx = lines[i].b.x - lines[i].a.x;
      float dy = lines[i].b.y - lines[i].a.y;
      float len = sqrtf(dx * dx + dy * dy);
      NSUInteger segs = (NSUInteger)(len / (zigPeriod * 0.5f)) + 1;
      maxZigLines += segs;
    }
    KKHachureLine *zigLines = malloc(maxZigLines * sizeof(KKHachureLine));
    NSUInteger zi = 0;
    for (NSUInteger i = 0; i < lineCount; i++) {
      simd_float2 a = lines[i].a;
      simd_float2 b = lines[i].b;
      float dx = b.x - a.x, dy = b.y - a.y;
      float len = sqrtf(dx * dx + dy * dy);
      if (len < 0.001f)
        continue;
      simd_float2 dir = {dx / len, dy / len};
      simd_float2 perp = {-dir.y, dir.x};
      float halfPeriod = zigPeriod * 0.5f;
      NSUInteger segs = (NSUInteger)(len / halfPeriod);
      if (segs < 1)
        segs = 1;
      float step = len / (float)segs;
      simd_float2 prev = a;
      for (NSUInteger s = 1; s <= segs; s++) {
        float d = step * (float)s;
        float side = (s % 2 == 1) ? zigAmp : -zigAmp;
        simd_float2 pt = {a.x + dir.x * d + perp.x * side,
                          a.y + dir.y * d + perp.y * side};
        if (s == segs)
          pt = b; // snap last point to endpoint
        if (zi >= maxZigLines) {
          maxZigLines *= 2;
          zigLines = realloc(zigLines, maxZigLines * sizeof(KKHachureLine));
        }
        zigLines[zi].a = prev;
        zigLines[zi].b = pt;
        zi++;
        prev = pt;
      }
    }
    free(lines);
    lines = zigLines;
    lineCount = zi;
  }

  // Store in cache.
  free(ce->lines);
  NSUInteger cacheBytes = lineCount * sizeof(KKHachureLine);
  ce->lines = malloc(cacheBytes);
  memcpy(ce->lines, lines, cacheBytes);
  ce->lineCount = lineCount;
  ce->key = key;

  *outLines = lines;
  return lineCount;
}
