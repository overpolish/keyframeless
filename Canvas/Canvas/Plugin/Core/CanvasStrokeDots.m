/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The DOTTED stroke geometry. A dot is an independent filled disc (triangle
// list); dashes are NOT geometry (the solid stroke is tessellated once with
// perfect corners and the dash pattern is masked per-pixel by arc length in
// KKStrokeDashFragment - see CanvasStrokeTessellate.m). textureCoordinate.y
// carries the signed edge distance (rim ±1, centre 0) for KKLineFragment's AA.

#import "CanvasStrokeTessellate.h"
#import "CanvasStrokeTessellateInternal.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <simd/simd.h>

static inline NSUInteger CanvasTri(KKVertex2D *o, NSUInteger vc, NSUInteger max,
                                   simd_float2 a, float aty, simd_float2 b,
                                   float bty, simd_float2 c, float cty) {
  if (vc + 3 > max)
    return vc;
  o[vc].position = a;
  o[vc].textureCoordinate = simd_make_float2(0.0f, aty);
  vc++;
  o[vc].position = b;
  o[vc].textureCoordinate = simd_make_float2(0.0f, bty);
  vc++;
  o[vc].position = c;
  o[vc].textureCoordinate = simd_make_float2(0.0f, cty);
  vc++;
  return vc;
}

// A filled disc (a dot) as a triangle fan around `center`.
static NSUInteger CanvasEmitDiscTris(KKVertex2D *o, NSUInteger vc,
                                     NSUInteger max, simd_float2 center,
                                     float hw) {
  NSUInteger segs = kCanvasCapSegs * 2; // full circle
  for (NSUInteger s = 0; s < segs; s++) {
    float a0 = (float)s / (float)segs * 2.0f * (float)M_PI;
    float a1 = (float)(s + 1) / (float)segs * 2.0f * (float)M_PI;
    simd_float2 d0 = simd_make_float2(cosf(a0), sinf(a0));
    simd_float2 d1 = simd_make_float2(cosf(a1), sinf(a1));
    vc = CanvasTri(o, vc, max, center, 0.0f, center + d0 * hw, 1.0f,
                   center + d1 * hw, 1.0f);
  }
  return vc;
}

// Point on the arc-parameterised polyline `wp` (cumulative lengths `arc`, count
// `m`) at distance `a`, clamped to the ends. Binary search keeps a dotted walk
// of a many-vertex contour off an O(n) scan per dot.
static simd_float2 CanvasSampleArc(const simd_float2 *wp, const float *arc,
                                   NSUInteger m, float a) {
  if (m == 0)
    return simd_make_float2(0.0f, 0.0f);
  if (a <= arc[0])
    return wp[0];
  if (a >= arc[m - 1])
    return wp[m - 1];
  NSUInteger lo = 0, hi = m - 1;
  while (hi - lo > 1) {
    NSUInteger mid = (lo + hi) / 2;
    if (arc[mid] <= a)
      lo = mid;
    else
      hi = mid;
  }
  float seg = arc[hi] - arc[lo];
  float t = seg > 1e-6f ? (a - arc[lo]) / seg : 0.0f;
  return wp[lo] + (wp[hi] - wp[lo]) * t;
}

NSUInteger CanvasDottedStrokeVertexCapacity(KKBezierPath *path, float dotWidth,
                                            float dotGap, float outputWidth,
                                            float outputHeight) {
  if (path.count < 2)
    return 0;
  NSUInteger nc = path.contourCount;
  BOOL closed = CanvasContourClosed(path, nc);
  NSUInteger polyCap = CanvasMaxContourPolyCap(path, closed);
  if (polyCap == 0)
    return 0;
  simd_float2 *tmp = malloc(sizeof(simd_float2) * polyCap);
  NSUInteger discTris = kCanvasCapSegs * 2 * 3; // a dot = 2*kCanvasCapSegs tris
  (void)dotWidth;
  NSUInteger total = 0;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
    NSUInteger n = CanvasBuildContourPolyline(path, r, closed, outputWidth,
                                              outputHeight, tmp, polyCap);
    if (n < 2)
      continue;
    float arc = CanvasContourArcLength(tmp, n, closed);
    float spacing = fmaxf(dotGap, 1.0f); // lower bound (over-counts -> safe)
    NSUInteger dots = (NSUInteger)(arc / spacing) + 4;
    total += dots * discTris;
  }
  free(tmp);
  return total + 64;
}

NSUInteger CanvasTessellateDottedStroke(KKBezierPath *path, float startWidth,
                                        float endWidth, float outputWidth,
                                        float outputHeight, float dotGap,
                                        float phase, float drawStart01,
                                        float drawEnd01, float offset01,
                                        KKVertex2D *outVerts,
                                        NSUInteger maxVerts) {
  if (path.count < 2 || !outVerts || maxVerts < 4)
    return 0;

  NSUInteger nc = path.contourCount;
  BOOL closed = CanvasContourClosed(path, nc);
  // Draw-on only reveals a single contour's arc (open or closed); a compound
  // path emits every dot.
  BOOL drawOn =
      (nc == 1) && (drawStart01 > 0.0f || drawEnd01 < 1.0f || offset01 > 0.0f);
  NSUInteger polyCap = CanvasMaxContourPolyCap(path, closed);
  if (polyCap == 0)
    return 0;

  // Render-only path, so malloc/free locally. `wp`/`arc` carry the closing edge
  // for a closed contour (one extra slot) so dots are placed by arc length.
  simd_float2 *pts = malloc(sizeof(simd_float2) * polyCap);
  simd_float2 *wp = malloc(sizeof(simd_float2) * (polyCap + 1));
  float *arc = malloc(sizeof(float) * (polyCap + 1));

  float startHW = startWidth * 0.5f + kCanvasAAPaddingPx;
  float endHW = endWidth * 0.5f + kCanvasAAPaddingPx;
  NSUInteger vc = 0;

  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
    NSUInteger n = CanvasBuildContourPolyline(path, r, closed, outputWidth,
                                              outputHeight, pts, polyCap);
    if (n < 2)
      continue;

    NSUInteger m = n;
    for (NSUInteger i = 0; i < n; i++)
      wp[i] = pts[i];
    if (closed) {
      wp[n] = pts[0];
      m = n + 1;
    }
    arc[0] = 0.0f;
    for (NSUInteger i = 1; i < m; i++)
      arc[i] = arc[i - 1] + simd_distance(wp[i], wp[i - 1]);
    float totalArc = arc[m - 1];
    if (totalArc < 1e-3f)
      continue;

    // Draw-on visible window in this contour's cyclic arc space. A dot is shown
    // when its arc position is within `visLen` of `winStart` (cyclically) -
    // which also gives the offset wrap for free (an open path's window past the
    // end selects low-arc dots = the path's start, the two-piece reveal).
    float winStart = 0.0f, visLen = totalArc;
    if (drawOn) {
      float aDso = fmaxf(0.0f, fminf(1.0f, drawStart01)) * totalArc;
      float bDso = (1.0f - fmaxf(0.0f, fminf(1.0f, drawEnd01))) * totalArc;
      visLen = totalArc - aDso - bDso;
      if (visLen <= 0.5f)
        continue;
      winStart =
          fmodf(fmaxf(0.0f, fminf(1.0f, offset01)) * totalArc + aDso, totalArc);
      if (winStart < 0.0f)
        winStart += totalArc;
    }

    // A disc every `spacing` along the arc, shifted forward by `phase`.
    float spacing = startWidth + dotGap;
    if (spacing < 1.0f)
      spacing = 1.0f;
    float pshift = fmodf(phase, spacing);
    if (pshift < 0.0f)
      pshift += spacing;
    for (float a = pshift; a <= totalArc + 1e-3f; a += spacing) {
      if (drawOn) {
        float d = fmodf(a - winStart + totalArc, totalArc);
        if (d > visLen + 1e-3f)
          continue; // dot outside the revealed window
      }
      simd_float2 c = CanvasSampleArc(wp, arc, m, a);
      float f = a / totalArc;
      if (f > 1.0f)
        f = 1.0f;
      float hwd = startHW + (endHW - startHW) * f;
      vc = CanvasEmitDiscTris(outVerts, vc, maxVerts, c, hwd);
    }
  }

  free(pts);
  free(wp);
  free(arc);
  return vc;
}
