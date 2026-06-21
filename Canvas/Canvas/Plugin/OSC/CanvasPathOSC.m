/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPathOSC.h"
#import "CanvasLayerRender.h"   // CanvasProjectLayerPointsObj
#import "CanvasPenController.h" // CanvasPenSurface draw primitives
#import <KeyframelessKit/KKBezierPath.h>
#import <simd/simd.h>

// Coarser than the render tessellation - the OSC line only needs to read as the
// path's shape, not be pixel-exact.
static const NSUInteger kPathOSCSteps = 16;

// Flatten the path to a local normalized polyline (Y-up), the raw geometry
// CanvasProjectLayerPointsObj then projects. Returns the sample count.
static NSUInteger CanvasPathOSCFlatten(KKBezierPath *path, simd_float2 *out,
                                       NSUInteger cap) {
  NSUInteger count = path.count;
  if (count < 2)
    return 0;
  BOOL closed = path.closed;
  NSUInteger segs = closed ? count : count - 1;
  NSUInteger n = 0;
  for (NSUInteger c = 0; c < segs; c++) {
    NSUInteger next = (c + 1) % count;
    for (NSUInteger i = 0; i < kPathOSCSteps; i++) {
      float t = (float)i / (float)kPathOSCSteps;
      simd_float2 p = [path evaluatePointAtIndex:c nextIndex:next atT:t];
      if (n > 0 && simd_distance_squared(p, out[n - 1]) < 1e-9f)
        continue;
      if (n < cap)
        out[n++] = p;
    }
  }
  if (closed) {
    if (n > 0 && n < cap)
      out[n++] = out[0]; // close the loop back to the start
  } else {
    simd_float2 p = [path evaluatePointAtIndex:segs - 1
                                     nextIndex:segs
                                           atT:1.0f];
    if ((n == 0 || simd_distance_squared(p, out[n - 1]) > 1e-9f) && n < cap)
      out[n++] = p; // open path's terminal anchor (the loop stops before t=1)
  }
  return n;
}

void CanvasDrawPathEditOSC(id<CanvasPenSurface> surface,
                           NSArray<KKBezierPath *> *layers, KKBezierPath *path,
                           double frac, float aspect, NSIndexSet *selected,
                           BOOL marqueeActive, CGRect marqueeSurfaceRect,
                           BOOL ghost) {
  NSUInteger count = path.count;
  if (!surface || count < 1)
    return;

  // The line: flatten -> project -> draw as one curve strip.
  if (count >= 2) {
    NSUInteger segs = path.closed ? count : count - 1;
    NSUInteger cap = segs * kPathOSCSteps + 2;
    simd_float2 *local = malloc(sizeof(simd_float2) * cap);
    NSUInteger n = CanvasPathOSCFlatten(path, local, cap);
    if (n >= 2) {
      simd_float2 *proj = malloc(sizeof(simd_float2) * n);
      CanvasProjectLayerPointsObj(layers, path, frac, aspect, local, proj, n);
      CGPoint *cg = malloc(sizeof(CGPoint) * n);
      for (NSUInteger i = 0; i < n; i++)
        cg[i] = CGPointMake(proj[i].x, proj[i].y);
      [surface penDrawCurveObjPoints:cg count:n];
      free(proj);
      free(cg);
    }
    free(local);
  }

  // Project the raw anchors once.
  simd_float2 *aLocal = malloc(sizeof(simd_float2) * count);
  for (NSUInteger i = 0; i < count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    aLocal[i] = simd_make_float2(pt.x, pt.y);
  }
  simd_float2 *aProj = malloc(sizeof(simd_float2) * count);
  CanvasProjectLayerPointsObj(layers, path, frac, aspect, aLocal, aProj, count);

  // Tangent handles (under the anchor dots): a line from the anchor to each
  // non-zero handle end, with the surface's handle endpoint dot.
  for (NSUInteger i = 0; i < count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    CGPoint a = CGPointMake(aProj[i].x, aProj[i].y);
    if (fabsf(pt.outX) + fabsf(pt.outY) > 1e-6f) {
      simd_float2 b = CanvasProjectLayerPointObj(
          layers, path, frac, aspect, pt.x + pt.outX, pt.y + pt.outY);
      [surface penDrawHandleFromObj:a toObj:CGPointMake(b.x, b.y)];
    }
    if (fabsf(pt.inX) + fabsf(pt.inY) > 1e-6f) {
      simd_float2 b = CanvasProjectLayerPointObj(layers, path, frac, aspect,
                                                 pt.x + pt.inX, pt.y + pt.inY);
      [surface penDrawHandleFromObj:a toObj:CGPointMake(b.x, b.y)];
    }
  }

  // Anchor dots on top - selected ones draw active (host accent); all dimmed
  // when this is a hidden-Points reveal ghost.
  for (NSUInteger i = 0; i < count; i++)
    [surface penDrawDotAtObj:CGPointMake(aProj[i].x, aProj[i].y)
                       ghost:ghost
                     hovered:NO
                      active:[selected containsIndex:i]];
  free(aLocal);
  free(aProj);

  // Rubber-band on top of everything (surface points - no projection).
  if (marqueeActive)
    [surface penDrawMarqueeRect:marqueeSurfaceRect];
}
