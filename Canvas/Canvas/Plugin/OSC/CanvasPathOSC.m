/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPathOSC.h"
#import "CanvasCornerFillet.h" // corner widget geometry
#import "CanvasLayerRender.h"  // CanvasProjectLayerPointsObj
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
                           BOOL ghost, BOOL showCornerWidgets) {
  NSUInteger count = path.count;
  if (!surface || count < 1)
    return;

  // The guide curve is drawn from the corner-expanded geometry so it traces the
  // rounded stroke (the anchors below stay at the stored sharp corners). Project
  // through the SAME path's transform - the expansion only changes local points.
  KKBezierPath *curvePath =
      path.hasCornerRadii ? CanvasPathByExpandingCorners(path, aspect) : path;
  NSUInteger curveCount = curvePath.count;
  if (curveCount >= 2) {
    NSUInteger segs = curvePath.closed ? curveCount : curveCount - 1;
    NSUInteger cap = segs * kPathOSCSteps + 2;
    simd_float2 *local = malloc(sizeof(simd_float2) * cap);
    NSUInteger n = CanvasPathOSCFlatten(curvePath, local, cap);
    if (n >= 2) {
      simd_float2 *proj = malloc(sizeof(simd_float2) * n);
      CanvasProjectLayerPointsObj(layers, curvePath, frac, aspect, local, proj,
                                  n);
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
  // non-zero handle end, with the surface's handle endpoint dot. A corner with a
  // radius set hides its handles - the rounding owns that corner now, and the
  // stored (sharp) handles would read as a stale, contradictory control. They
  // come back when the radius is cleared (default).
  for (NSUInteger i = 0; i < count; i++) {
    if ([path cornerRadiusAtIndex:i] > 0.0f)
      continue;
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

  // Live-corner widgets: an accent handle just inside each interior corner
  // (along the bisector), drawn on top of the anchors. Click-drag rounds that
  // corner (CanvasPathEditController). Cursor tool only (not interactive while
  // pen-drawing); hidden while this is a reveal ghost.
  if (showCornerWidgets && !ghost) {
    for (NSUInteger i = 0; i < count; i++) {
      CanvasCornerWidget w =
          CanvasCornerWidgetObj(layers, path, frac, aspect, i);
      if (!w.valid)
        continue;
      [surface penDrawRingAtObj:CGPointMake(w.widgetObj.x, w.widgetObj.y)
                          maxed:w.atMax];
    }
  }

  // Rubber-band on top of everything (surface points - no projection).
  if (marqueeActive)
    [surface penDrawMarqueeRect:marqueeSurfaceRect];
}
