/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Hachure fill-line generation: scanline-fill the shape with parallel lines at
// an angle (clipped to the contour by the scanline intersections), plus the
// cross-hatch (second perpendicular set) and zigzag variants. Ported from the
// pre-v3 SketchFill, pared to a CLEAN fill (no hand-drawn jitter - that's the
// Sketch feature's roughness, separate). Output is CENTERED-PIXEL object space
// to match the fill fan + model matrix. Results cached per path+params.

#import "CanvasHachure.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <simd/simd.h>

static const NSUInteger kSegsPerCurve = 16;

// Sample the path outline into a dense polygon in CENTERED-PIXEL space
// ((norm - 0.5) * size). Contours are stored sequentially; outContourStarts
// (length nc+1, last = sentinel) bounds each so scanline edges never bridge
// contours. Caller frees outPoly + outContourStarts.
static NSUInteger CanvasHachureSampleOutline(KKBezierPath *path, float outW,
                                             float outH, simd_float2 **outPoly,
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
    BOOL isClosed = (nc > 1) ? YES : path.closed;
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
        poly[n++] = (simd_float2){(pos.x - 0.5f) * outW, (pos.y - 0.5f) * outH};
      }
    }
    if (!isClosed && curveCount > 0) {
      NSUInteger lastIdx = cStart + curveCount - 1;
      simd_float2 pos = [path evaluatePointAtIndex:lastIdx
                                         nextIndex:lastIdx + 1
                                               atT:1.0f];
      poly[n++] = (simd_float2){(pos.x - 0.5f) * outW, (pos.y - 0.5f) * outH};
    }
  }
  contourStarts[nc] = n;
  *outPoly = poly;
  *outContourStarts = contourStarts;
  *outContourCount = nc;
  return n;
}

static simd_float2 CanvasHachureRotate(simd_float2 p, simd_float2 center,
                                       float cos_a, float sin_a) {
  float dx = p.x - center.x, dy = p.y - center.y;
  return (simd_float2){center.x + dx * cos_a - dy * sin_a,
                       center.y + dx * sin_a + dy * cos_a};
}

static int CanvasHachureCmpFloat(const void *a, const void *b) {
  float fa = *(const float *)a, fb = *(const float *)b;
  return (fa > fb) - (fa < fb);
}

// Intersections of the horizontal scanline at `y` with the polygon edges, per
// contour (so edges never bridge contours), sorted ascending. `xs` must hold n.
static NSUInteger CanvasHachureScanline(const simd_float2 *poly, float y,
                                        float *xs,
                                        const NSUInteger *contourStarts,
                                        NSUInteger contourCount) {
  NSUInteger count = 0;
  for (NSUInteger ci = 0; ci < contourCount; ci++) {
    NSUInteger cStart = contourStarts[ci];
    NSUInteger cLen = contourStarts[ci + 1] - cStart;
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
  qsort(xs, count, sizeof(float), CanvasHachureCmpFloat);
  return count;
}

#define CANVAS_HACHURE_CACHE 64

typedef struct {
  uint64_t key;
  CanvasHachureLine *lines;
  NSUInteger lineCount;
} CanvasHachureCacheEntry;

static CanvasHachureCacheEntry sCache[CANVAS_HACHURE_CACHE];

static uint64_t CanvasHachureKey(KKBezierPath *path, float outW, float outH,
                                 uint8_t style, float gap, float angle) {
  uint64_t h = 14695981039346656037ULL;
#define FNV(bytes, len)                                                        \
  do {                                                                         \
    const uint8_t *_p = (const uint8_t *)(bytes);                              \
    for (NSUInteger _i = 0; _i < (len); _i++) {                                \
      h ^= _p[_i];                                                             \
      h *= 1099511628211ULL;                                                   \
    }                                                                          \
  } while (0)
  NSUInteger cnt = path.count, cc = path.contourCount;
  BOOL closed = path.closed;
  FNV(&cnt, sizeof(cnt));
  FNV(&closed, sizeof(closed));
  FNV(&cc, sizeof(cc));
  if (cnt > 0) {
    KKBezierPoint first = [path pointAtIndex:0];
    KKBezierPoint last = [path pointAtIndex:cnt - 1];
    FNV(&first, sizeof(first));
    FNV(&last, sizeof(last));
  }
  FNV(&outW, sizeof(outW));
  FNV(&outH, sizeof(outH));
  FNV(&style, sizeof(style));
  FNV(&gap, sizeof(gap));
  FNV(&angle, sizeof(angle));
#undef FNV
  return h ? h : 1;
}

// Fill `lines`/`*lineCount` (growing the buffer) with the hachure scanlines for
// `rotPoly` (the outline rotated so the lines are horizontal), rotated back
// into object space by (cos_a, -sin_a).
static void CanvasHachureEmit(const simd_float2 *rotPoly, NSUInteger polyCount,
                              const NSUInteger *contourStarts,
                              NSUInteger contourCount, simd_float2 center,
                              float cos_a, float sin_a, float gap, float *xs,
                              CanvasHachureLine **lines, NSUInteger *lineCount,
                              NSUInteger *maxLines) {
  float minY = HUGE_VALF, maxY = -HUGE_VALF;
  for (NSUInteger i = 0; i < polyCount; i++) {
    if (rotPoly[i].y < minY)
      minY = rotPoly[i].y;
    if (rotPoly[i].y > maxY)
      maxY = rotPoly[i].y;
  }
  for (float y = minY + gap; y < maxY; y += gap) {
    NSUInteger xc =
        CanvasHachureScanline(rotPoly, y, xs, contourStarts, contourCount);
    for (NSUInteger k = 0; k + 1 < xc; k += 2) {
      if (*lineCount >= *maxLines) {
        *maxLines *= 2;
        *lines = realloc(*lines, *maxLines * sizeof(CanvasHachureLine));
      }
      simd_float2 a = {xs[k], y}, b = {xs[k + 1], y};
      (*lines)[*lineCount].a = CanvasHachureRotate(a, center, cos_a, -sin_a);
      (*lines)[*lineCount].b = CanvasHachureRotate(b, center, cos_a, -sin_a);
      (*lineCount)++;
    }
  }
}

NSUInteger CanvasGenerateHachureLines(KKBezierPath *path, float outW,
                                      float outH, uint8_t fillStyle, float gap,
                                      float angle,
                                      CanvasHachureLine **outLines) {
  if (path.count < 3 || gap < 1.0f) {
    *outLines = NULL;
    return 0;
  }
  uint64_t key = CanvasHachureKey(path, outW, outH, fillStyle, gap, angle);
  CanvasHachureCacheEntry *ce =
      &sCache[(NSUInteger)(key % CANVAS_HACHURE_CACHE)];
  if (ce->key == key && ce->lines) {
    NSUInteger bytes = ce->lineCount * sizeof(CanvasHachureLine);
    CanvasHachureLine *copy = malloc(bytes ?: 1);
    memcpy(copy, ce->lines, bytes);
    *outLines = copy;
    return ce->lineCount;
  }

  simd_float2 *poly = NULL;
  NSUInteger *contourStarts = NULL, contourCount = 0;
  NSUInteger polyCount = CanvasHachureSampleOutline(
      path, outW, outH, &poly, &contourStarts, &contourCount);
  if (polyCount < 3) {
    free(poly);
    free(contourStarts);
    *outLines = NULL;
    return 0;
  }

  simd_float2 center = {0, 0};
  for (NSUInteger i = 0; i < polyCount; i++)
    center += poly[i];
  center /= (float)polyCount;

  // Negate the angle for Y-down rotation, then rotate the outline so the
  // scanlines are horizontal.
  float cos_a = cosf(-angle), sin_a = sinf(-angle);
  simd_float2 *rotPoly = malloc(polyCount * sizeof(simd_float2));
  for (NSUInteger i = 0; i < polyCount; i++)
    rotPoly[i] = CanvasHachureRotate(poly[i], center, cos_a, sin_a);

  NSUInteger maxLines = 64;
  CanvasHachureLine *lines = malloc(maxLines * sizeof(CanvasHachureLine));
  NSUInteger lineCount = 0;
  float *xs = malloc((polyCount + 2) * sizeof(float));
  CanvasHachureEmit(rotPoly, polyCount, contourStarts, contourCount, center,
                    cos_a, sin_a, gap, xs, &lines, &lineCount, &maxLines);
  free(rotPoly);

  // Cross-hatch: a second set rotated +90 degrees.
  if (fillStyle == 2) {
    float a2 = -angle + (float)(M_PI / 2.0);
    float cos_b = cosf(a2), sin_b = sinf(a2);
    simd_float2 *rotPoly2 = malloc(polyCount * sizeof(simd_float2));
    for (NSUInteger i = 0; i < polyCount; i++)
      rotPoly2[i] = CanvasHachureRotate(poly[i], center, cos_b, sin_b);
    CanvasHachureEmit(rotPoly2, polyCount, contourStarts, contourCount, center,
                      cos_b, sin_b, gap, xs, &lines, &lineCount, &maxLines);
    free(rotPoly2);
  }
  free(xs);
  free(contourStarts);
  free(poly);

  // Zigzag: replace each line with a triangle wave along its length.
  if (fillStyle == 3 && lineCount > 0) {
    float zigAmp = gap * 0.5f, zigPeriod = gap;
    NSUInteger maxZig = lineCount * 4 + 4;
    CanvasHachureLine *zig = malloc(maxZig * sizeof(CanvasHachureLine));
    NSUInteger zi = 0;
    for (NSUInteger i = 0; i < lineCount; i++) {
      simd_float2 a = lines[i].a, b = lines[i].b;
      float dx = b.x - a.x, dy = b.y - a.y;
      float len = sqrtf(dx * dx + dy * dy);
      if (len < 0.001f)
        continue;
      simd_float2 dir = {dx / len, dy / len};
      simd_float2 perp = {-dir.y, dir.x};
      NSUInteger segs = (NSUInteger)(len / (zigPeriod * 0.5f));
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
          pt = b;
        if (zi >= maxZig) {
          maxZig *= 2;
          zig = realloc(zig, maxZig * sizeof(CanvasHachureLine));
        }
        zig[zi].a = prev;
        zig[zi].b = pt;
        zi++;
        prev = pt;
      }
    }
    free(lines);
    lines = zig;
    lineCount = zi;
  }

  free(ce->lines);
  NSUInteger cacheBytes = lineCount * sizeof(CanvasHachureLine);
  ce->lines = malloc(cacheBytes ?: 1);
  memcpy(ce->lines, lines, cacheBytes);
  ce->lineCount = lineCount;
  ce->key = key;

  *outLines = lines;
  return lineCount;
}

// Emit one quad (p0-p1-p2 / p1-p3-p2) into the triangle list `v` at `n`,
// guarded by `cap`. Returns the new vertex count.
static NSUInteger CanvasHachureQuad(KKVertex2D *v, NSUInteger n, NSUInteger cap,
                                    simd_float2 p0, simd_float2 p1,
                                    simd_float2 p2, simd_float2 p3) {
  if (n + 6 > cap)
    return n;
  simd_float2 q[6] = {p0, p1, p2, p1, p3, p2};
  for (int k = 0; k < 6; k++) {
    v[n].position = q[k];
    // OBJECT-SPACE position so a gradient-mode hachure samples the gradient
    // per-pixel (the solid colour fragment ignores it).
    v[n].textureCoordinate = q[k];
    n++;
  }
  return n;
}

// Segments per Dots-style disc (the dot pattern draws round dots, not square
// quads).
static const int kCanvasDotSegments = 14;

// Emit a filled disc (triangle-list, `kCanvasDotSegments` wedges) of `radius`
// centred at `c` into `v` at `n`, guarded by `cap`. Object-space texcoords so a
// gradient-mode dot fill still samples the gradient per pixel.
static NSUInteger CanvasHachureDisc(KKVertex2D *v, NSUInteger n, NSUInteger cap,
                                    simd_float2 c, float radius) {
  if (n + (NSUInteger)kCanvasDotSegments * 3 > cap)
    return n;
  for (int k = 0; k < kCanvasDotSegments; k++) {
    float a0 = (float)k / kCanvasDotSegments * 2.0f * (float)M_PI;
    float a1 = (float)(k + 1) / kCanvasDotSegments * 2.0f * (float)M_PI;
    simd_float2 tri[3] = {
        c, c + simd_make_float2(cosf(a0), sinf(a0)) * radius,
        c + simd_make_float2(cosf(a1), sinf(a1)) * radius};
    for (int j = 0; j < 3; j++) {
      v[n].position = tri[j];
      v[n].textureCoordinate = tri[j];
      n++;
    }
  }
  return n;
}

NSUInteger CanvasHachureTriangles(const CanvasHachureLine *lines,
                                  NSUInteger lineCount, uint8_t style, float gap,
                                  float weight, KKVertex2D **outVerts) {
  float hw = fmaxf(weight, 0.5f) * 0.5f;
  NSUInteger cap = 0;
  if (style == 4) {
    float step = fmaxf(gap, 1.0f);
    for (NSUInteger i = 0; i < lineCount; i++) {
      float len = simd_length(lines[i].b - lines[i].a);
      cap += ((NSUInteger)(len / step) + 2) * (NSUInteger)(kCanvasDotSegments * 3);
    }
  } else {
    cap = lineCount * 6;
  }
  if (cap == 0) {
    *outVerts = NULL;
    return 0;
  }
  KKVertex2D *v = malloc(sizeof(KKVertex2D) * cap);
  NSUInteger n = 0;
  float dotHw = fmaxf(weight, gap * 0.18f) * 0.5f;
  for (NSUInteger i = 0; i < lineCount; i++) {
    simd_float2 a = lines[i].a, b = lines[i].b;
    simd_float2 d = b - a;
    float len = simd_length(d);
    if (len < 1e-4f)
      continue;
    simd_float2 dir = d / len;
    if (style == 4) {
      for (float s = 0.0f; s <= len; s += gap) {
        simd_float2 c = a + dir * s;
        n = CanvasHachureDisc(v, n, cap, c, dotHw);
      }
    } else {
      simd_float2 perp = simd_make_float2(-dir.y, dir.x) * hw;
      n = CanvasHachureQuad(v, n, cap, a + perp, a - perp, b + perp, b - perp);
    }
  }
  *outVerts = v;
  return n;
}
