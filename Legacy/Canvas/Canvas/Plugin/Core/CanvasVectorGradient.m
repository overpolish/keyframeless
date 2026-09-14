/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The stroke/marker GRADIENT fill: one bbox+angle gradient computed from the
// drawn geometry and baked into the strip + marker verts so they share a single
// continuous gradient. Split out of CanvasLayerRender.m's per-layer encoder.

#import "CanvasLayerRenderInternal.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <simd/simd.h>

CanvasGradientFill
CanvasComputeGradientFill(KKBezierPath *geom, float imageWidth,
                          float imageHeight, float strokeStart, float strokeEnd,
                          float strokeScale, KKColorLanesValue cv,
                          const KKVertex2D *extra, NSUInteger extraCount) {
  simd_float2 bbMin = simd_make_float2(FLT_MAX, FLT_MAX);
  simd_float2 bbMax = simd_make_float2(-FLT_MAX, -FLT_MAX);
  for (NSUInteger pi = 0; pi < geom.count; pi++) {
    KKBezierPoint pt = [geom pointAtIndex:pi];
    float px = (pt.x - 0.5f) * imageWidth;
    float py = (pt.y - 0.5f) * imageHeight;
    bbMin = simd_make_float2(fminf(bbMin.x, px), fminf(bbMin.y, py));
    bbMax = simd_make_float2(fmaxf(bbMax.x, px), fmaxf(bbMax.y, py));
  }
  float pad = 0.5f * fmaxf(strokeStart, strokeEnd) * strokeScale;
  bbMin -= pad;
  bbMax += pad;
  for (NSUInteger i = 0; i < extraCount; i++) {
    simd_float2 p = extra[i].position;
    bbMin = simd_make_float2(fminf(bbMin.x, p.x), fminf(bbMin.y, p.y));
    bbMax = simd_make_float2(fmaxf(bbMax.x, p.x), fmaxf(bbMax.y, p.y));
  }
  simd_float2 bbCenter = (bbMin + bbMax) * 0.5f;
  simd_float2 bbSize = simd_make_float2(fmaxf(bbMax.x - bbMin.x, 1.0f),
                                        fmaxf(bbMax.y - bbMin.y, 1.0f));
  float th = cv.gradientAngle;
  simd_float2 dir = simd_make_float2(sinf(th), cosf(th));
  CanvasGradientFill g;
  g.center = bbCenter;
  g.dir = dir;
  // Half the bbox extent measured along `dir` (its support function), so the
  // gradient reaches t=0/1 at the bbox edge in the gradient direction.
  g.halfExtent = fmaxf(
      0.5f * bbSize.x * fabsf(dir.x) + 0.5f * bbSize.y * fabsf(dir.y), 1.0e-3f);
  g.maxDim = fmaxf(bbSize.x, bbSize.y);
  g.type = cv.gradientType;
  return g;
}

void CanvasApplyGradientFill(KKVertex2D *verts, NSUInteger vc,
                             CanvasGradientFill g) {
  for (NSUInteger vi = 0; vi < vc; vi++) {
    simd_float2 d = verts[vi].position - g.center;
    float gt = (g.type == 1)
                   ? simd_dot(d, g.dir) / (2.0f * g.halfExtent) + 0.5f // linear
                   : 2.0f * simd_length(d) / fmaxf(g.maxDim, 1.0f);    // radial
    gt = gt < 0.0f ? 0.0f : (gt > 1.0f ? 1.0f : gt);
    verts[vi].textureCoordinate.x = gt;
  }
}
