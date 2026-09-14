/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The DRAW-ON stroke geometry: the progressive write-on reveal that shows only
// the visible arc window [Start, End] of a single contour (open OR closed),
// rotated by Offset. Split out of CanvasStrokeTessellate.m (the plain solid /
// dashed strip) since it sits ON TOP of that file's contour sampling + strip
// emitter (CanvasEmitContourStrip, shared via the internal header) rather than
// being part of it.

#import "CanvasStrokeTessellate.h"
#import "CanvasStrokeTessellateInternal.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <simd/simd.h>

float CanvasContourTotalArc(KKBezierPath *path, float outputWidth,
                            float outputHeight) {
  if (path.count < 2)
    return 0.0f;
  NSUInteger nc = path.contourCount;
  BOOL closed = CanvasContourClosed(path, nc);
  NSUInteger polyCap = CanvasMaxContourPolyCap(path, closed);
  if (polyCap == 0)
    return 0.0f;
  // Sum every contour's length so draw-on activates on multi-contour paths too
  // (each contour reveals per-contour in the tessellator). Single contour is
  // the contour-0 length as before.
  simd_float2 *pts = malloc(sizeof(simd_float2) * polyCap);
  float total = 0.0f;
  for (NSUInteger ci = 0; ci < nc; ci++) {
    NSRange r = [path contourRangeAtIndex:ci];
    NSUInteger n = CanvasBuildContourPolyline(path, r, closed, outputWidth,
                                              outputHeight, pts, polyCap);
    if (n >= 2)
      total += CanvasContourArcLength(pts, n, closed);
  }
  free(pts);
  return total;
}

// Extract the sub-polyline of a point sequence (seq[0..sn), cumulative arc
// seqCum[0..sn)) covering the arc interval [lo, hi], interpolating the two
// boundary points. Fills outPts + a per-vertex GLOBAL taper fraction (for the
// width lerp; `wrapFrac` makes a closed loop's taper repeat per turn via
// fmod(arc, fracMod)) + a per-vertex LOCAL arc (0 at lo, for the dash pattern).
// Returns the vertex count (0 if the interval is empty / degenerate). Output
// buffers must hold at least sn + 2.
static NSUInteger CanvasExtractSubArc(const simd_float2 *seq,
                                      const float *seqCum, NSUInteger sn,
                                      float lo, float hi, float fracMod,
                                      BOOL wrapFrac, simd_float2 *outPts,
                                      float *outGFrac, float *outLArc,
                                      NSUInteger maxOut) {
  if (sn < 2 || hi - lo < 1e-3f)
    return 0;
  float seqTotal = seqCum[sn - 1];
  if (lo < 0.0f)
    lo = 0.0f;
  if (hi > seqTotal)
    hi = seqTotal;
  if (hi - lo < 1e-3f || fracMod < 1e-6f)
    return 0;
  NSUInteger m = 0;
  NSUInteger s = 0;
  while (s + 1 < sn && seqCum[s + 1] <= lo)
    s++;
  float bp = lo;
  for (;;) {
    float c0 = seqCum[s], c1 = seqCum[s + 1];
    float seg = c1 - c0;
    float u = seg > 1e-6f ? (bp - c0) / seg : 0.0f;
    u = fmaxf(0.0f, fminf(1.0f, u));
    simd_float2 p = seq[s] + (seq[s + 1] - seq[s]) * u;
    if ((m == 0 || simd_distance(outPts[m - 1], p) > 1e-4f) && m < maxOut) {
      outPts[m] = p;
      float gf = wrapFrac ? fmodf(bp, fracMod) / fracMod : bp / fracMod;
      outGFrac[m] = fmaxf(0.0f, fminf(1.0f, gf));
      outLArc[m] = bp - lo;
      m++;
    }
    if (bp >= hi - 1e-4f)
      break;
    if (c1 < hi - 1e-4f && s + 2 < sn) {
      bp = c1;
      s++;
    } else {
      bp = hi;
    }
  }
  return m >= 2 ? m : 0;
}

// Build the per-vertex half-width (global-arc taper) + arc buffers for one
// extracted draw-on piece and emit it as an open strip (caps at both cut ends).
static NSUInteger CanvasEmitDrawOnPiece(KKVertex2D *outVerts, NSUInteger vc,
                                        NSUInteger maxVerts, simd_float2 *sub,
                                        const float *gfrac, const float *larc,
                                        NSUInteger m, float startHW,
                                        float endHW, float *hw, float *arcv,
                                        uint8_t lineCap, uint8_t lineJoin,
                                        BOOL bridge, float *outArc) {
  if (m < 2)
    return vc;
  for (NSUInteger i = 0; i < m; i++)
    hw[i] = startHW + (endHW - startHW) * gfrac[i];
  hw[m] = hw[m - 1];
  if (arcv) {
    for (NSUInteger i = 0; i < m; i++)
      arcv[i] = larc[i];
    arcv[m] = larc[m - 1];
  }
  return CanvasEmitContourStrip(outVerts, vc, maxVerts, sub, m, NO, hw, arcv,
                                lineCap, lineJoin, bridge, outArc);
}

// Emit ONE contour's visible draw-on window (the [Start,End] arc rotated by
// Offset, pulled back behind end markers) into outVerts at vc. `bridgeFirst`
// stitches the first piece onto a prior strip (multi-contour loop). Buffers are
// local. Returns the running vertex count.
static NSUInteger CanvasEmitDrawOnWindow(const simd_float2 *pts, NSUInteger n,
                                         BOOL closed, float L, float a, float b,
                                         float off, float visLen, float startHW,
                                         float endHW, float startPullbackPx,
                                         float endPullbackPx, uint8_t lineCap,
                                         uint8_t lineJoin, BOOL bridgeFirst,
                                         KKVertex2D *outVerts, NSUInteger vc,
                                         NSUInteger maxVerts, float *outArc) {
  NSUInteger subCap = (closed ? 2 * n : n) + 4;
  simd_float2 *sub = malloc(sizeof(simd_float2) * subCap);
  float *gfrac = malloc(sizeof(float) * subCap);
  float *larc = malloc(sizeof(float) * subCap);
  float *hw = malloc(sizeof(float) * subCap);
  float *arcv = outArc ? malloc(sizeof(float) * subCap) : NULL;

  if (closed) {
    NSUInteger sn = 2 * n + 1;
    simd_float2 *seq = malloc(sizeof(simd_float2) * sn);
    float *cum = malloc(sizeof(float) * sn);
    for (NSUInteger k = 0; k < sn; k++)
      seq[k] = pts[k % n];
    cum[0] = 0.0f;
    for (NSUInteger k = 1; k < sn; k++)
      cum[k] = cum[k - 1] + simd_distance(seq[k], seq[k - 1]);
    float winStart = fmodf(off + a, L);
    if (winStart < 0.0f)
      winStart += L;
    NSUInteger m = CanvasExtractSubArc(seq, cum, sn, winStart + startPullbackPx,
                                       winStart + visLen - endPullbackPx, L,
                                       YES, sub, gfrac, larc, subCap);
    vc = CanvasEmitDrawOnPiece(outVerts, vc, maxVerts, sub, gfrac, larc, m,
                               startHW, endHW, hw, arcv, lineCap, lineJoin,
                               bridgeFirst, outArc);
    free(seq);
    free(cum);
  } else {
    float *cum = malloc(sizeof(float) * n);
    cum[0] = 0.0f;
    for (NSUInteger k = 1; k < n; k++)
      cum[k] = cum[k - 1] + simd_distance(pts[k], pts[k - 1]);
    if (off <= 0.5f) {
      float lo = a + startPullbackPx;
      float hi = (L - b) - endPullbackPx;
      NSUInteger m = CanvasExtractSubArc(pts, cum, n, lo, hi, L, NO, sub, gfrac,
                                         larc, subCap);
      vc = CanvasEmitDrawOnPiece(outVerts, vc, maxVerts, sub, gfrac, larc, m,
                                 startHW, endHW, hw, arcv, lineCap, lineJoin,
                                 bridgeFirst, outArc);
    } else {
      float w0 = fmodf(off + a, L);
      if (w0 < 0.0f)
        w0 += L;
      float w1 = w0 + visLen;
      BOOL wraps = w1 > L + 0.5f;
      float aHi = wraps ? L : (w1 - endPullbackPx);
      NSUInteger mA = CanvasExtractSubArc(pts, cum, n, w0 + startPullbackPx,
                                          aHi, L, NO, sub, gfrac, larc, subCap);
      vc = CanvasEmitDrawOnPiece(outVerts, vc, maxVerts, sub, gfrac, larc, mA,
                                 startHW, endHW, hw, arcv, lineCap, lineJoin,
                                 bridgeFirst, outArc);
      if (wraps) {
        NSUInteger mB =
            CanvasExtractSubArc(pts, cum, n, 0.0f, (w1 - L) - endPullbackPx, L,
                                NO, sub, gfrac, larc, subCap);
        vc = CanvasEmitDrawOnPiece(outVerts, vc, maxVerts, sub, gfrac, larc, mB,
                                   startHW, endHW, hw, arcv, lineCap, lineJoin,
                                   vc > 0, outArc);
      }
    }
    free(cum);
  }
  free(sub);
  free(gfrac);
  free(larc);
  free(hw);
  free(arcv);
  return vc;
}

// Emit a FULLY-revealed contour's strip with the global-arc width taper (used
// by the multi-contour draw-on when one branch is wholly visible).
static NSUInteger CanvasEmitFullContour(simd_float2 *pts, NSUInteger n,
                                        BOOL closed, float L, float startHW,
                                        float endHW, uint8_t lineCap,
                                        uint8_t lineJoin, BOOL bridge,
                                        KKVertex2D *outVerts, NSUInteger vc,
                                        NSUInteger maxVerts, float *outArc) {
  float *cum = malloc(sizeof(float) * n);
  float *hw = malloc(sizeof(float) * (n + 1));
  float *arcv = outArc ? malloc(sizeof(float) * (n + 1)) : NULL;
  cum[0] = 0.0f;
  for (NSUInteger k = 1; k < n; k++)
    cum[k] = cum[k - 1] + simd_distance(pts[k], pts[k - 1]);
  for (NSUInteger i = 0; i < n; i++) {
    float f = L > 1e-6f ? cum[i] / L : 0.0f;
    hw[i] = startHW + (endHW - startHW) * fminf(1.0f, f);
    if (arcv)
      arcv[i] = cum[i];
  }
  hw[n] = hw[n - 1];
  if (arcv)
    arcv[n] = cum[n - 1];
  vc = CanvasEmitContourStrip(outVerts, vc, maxVerts, pts, n, closed, hw, arcv,
                              lineCap, lineJoin, bridge, outArc);
  free(cum);
  free(hw);
  free(arcv);
  return vc;
}

NSUInteger CanvasTessellateStrokeDrawOn(
    KKBezierPath *path, float startWidth, float endWidth, float outputWidth,
    float outputHeight, uint8_t lineCap, uint8_t lineJoin, float drawStart01,
    float drawEnd01, float offset01, float startPullbackPx, float endPullbackPx,
    KKVertex2D *outVerts, NSUInteger maxVerts, float *outArc) {
  if (path.count < 2 || !outVerts || maxVerts < 4)
    return 0;
  NSUInteger nc = path.contourCount;
  BOOL closed = CanvasContourClosed(path, nc);

  // Multi-contour: draw EACH contour (branch) independently with the same
  // Start/End/Offset. No end markers on a multi-contour path -> no pullback.
  if (nc != 1) {
    NSUInteger polyCap = CanvasMaxContourPolyCap(path, closed);
    if (polyCap == 0)
      return 0;
    simd_float2 *pts = malloc(sizeof(simd_float2) * polyCap);
    NSUInteger vc = 0;
    for (NSUInteger ci = 0; ci < nc; ci++) {
      NSRange r = [path contourRangeAtIndex:ci];
      NSUInteger n = CanvasBuildContourPolyline(path, r, closed, outputWidth,
                                                outputHeight, pts, polyCap);
      if (n < 2)
        continue;
      float L = CanvasContourArcLength(pts, n, closed);
      if (L < 1e-3f)
        continue;
      float a = fmaxf(0.0f, fminf(1.0f, drawStart01)) * L;
      float b = (1.0f - fmaxf(0.0f, fminf(1.0f, drawEnd01))) * L;
      float off = fmaxf(0.0f, fminf(1.0f, offset01)) * L;
      float visLen = L - a - b;
      if (visLen <= 0.5f)
        continue;
      float startHW = startWidth * 0.5f + kCanvasAAPaddingPx;
      float endHW = endWidth * 0.5f + kCanvasAAPaddingPx;
      if (visLen >= L - 0.5f && (closed || off <= 0.5f))
        vc = CanvasEmitFullContour(pts, n, closed, L, startHW, endHW, lineCap,
                                   lineJoin, vc > 0, outVerts, vc, maxVerts,
                                   outArc);
      else
        vc = CanvasEmitDrawOnWindow(
            pts, n, closed, L, a, b, off, visLen, startHW, endHW, 0.0f, 0.0f,
            lineCap, lineJoin, vc > 0, outVerts, vc, maxVerts, outArc);
    }
    free(pts);
    return vc;
  }
  NSUInteger polyCap = CanvasMaxContourPolyCap(path, closed);
  if (polyCap == 0)
    return 0;
  simd_float2 *pts = malloc(sizeof(simd_float2) * polyCap);
  NSRange r = [path contourRangeAtIndex:0];
  NSUInteger n = CanvasBuildContourPolyline(path, r, closed, outputWidth,
                                            outputHeight, pts, polyCap);
  if (n < 2) {
    free(pts);
    return 0;
  }
  float L = CanvasContourArcLength(pts, n, closed);
  if (L < 1e-3f) {
    free(pts);
    return 0;
  }
  float a = fmaxf(0.0f, fminf(1.0f, drawStart01)) * L;
  float b = (1.0f - fmaxf(0.0f, fminf(1.0f, drawEnd01))) * L;
  float off = fmaxf(0.0f, fminf(1.0f, offset01)) * L;
  float visLen = L - a - b;
  if (visLen <= 0.5f) {
    free(pts);
    return 0;
  }
  // Whole contour visible and no offset: tessellate normally (a closed loop
  // wraps with no seam caps; an open path keeps its endpoint-marker pullback).
  // An OPEN path WITH offset keeps the wrap path even at full reveal, so the
  // cut/seam (and its markers) stays where the offset puts it instead of
  // snapping back to the natural ends. A closed loop is always seamless when
  // full (offset is a no-op there).
  if (visLen >= L - 0.5f && (closed || off <= 0.5f)) {
    free(pts);
    return CanvasTessellateStrokeArc(
        path, startWidth, endWidth, outputWidth, outputHeight, lineCap,
        lineJoin, outVerts, maxVerts, closed ? 0.0f : startPullbackPx,
        closed ? 0.0f : endPullbackPx, NULL, outArc);
  }

  float startHW = startWidth * 0.5f + kCanvasAAPaddingPx;
  float endHW = endWidth * 0.5f + kCanvasAAPaddingPx;
  NSUInteger vc = CanvasEmitDrawOnWindow(
      pts, n, closed, L, a, b, off, visLen, startHW, endHW, startPullbackPx,
      endPullbackPx, lineCap, lineJoin, NO, outVerts, 0, maxVerts, outArc);
  free(pts);
  return vc;
}
