/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasCornerFillet.h"
#import "CanvasLayerRender.h" // CanvasProjectLayerPointObj
#import <KeyframelessKit/KKBezierPath.h>
#import <simd/simd.h>

double CanvasCornerInsetForRadius(double r, double theta) {
  double t = tan(theta * 0.5);
  if (t < 1e-6)
    return 0.0;
  return r / t;
}

double CanvasCornerRadiusForInset(double d, double theta) {
  return d * tan(theta * 0.5);
}

// Object <-> pixel (aspect-corrected) space: arcs/angles are computed in pixel
// space so they read circular on a non-square canvas; geometry is stored in
// object space.
static inline simd_float2 ToPx(simd_float2 p, float aspect) {
  return simd_make_float2(p.x * aspect, p.y);
}
static inline simd_float2 ToObj(simd_float2 p, float aspect) {
  return simd_make_float2(aspect > 0 ? p.x / aspect : p.x, p.y);
}

// The geometry of a corner at P with neighbours A, B (all in the SAME pixel
// space): the unit edge directions, the edge lengths, the interior angle and the
// interior bisector. Shared by the fillet expander (local space) and the widget
// (projected space) - they differ only in which points they feed in. `valid` is
// NO for a degenerate / near-straight corner.
typedef struct {
  BOOL valid;
  simd_float2 u, v; // unit dirs P->A, P->B
  simd_float2 bis;  // unit interior bisector
  float la, lb;     // edge lengths |PA|, |PB|
  double theta;     // interior angle (radians)
} CanvasCornerBasis;

static CanvasCornerBasis CanvasCornerBasisPx(simd_float2 Ppx, simd_float2 Apx,
                                             simd_float2 Bpx) {
  CanvasCornerBasis b = {0};
  simd_float2 ud = Apx - Ppx, vd = Bpx - Ppx;
  float la = simd_length(ud), lb = simd_length(vd);
  if (la < 1e-6f || lb < 1e-6f)
    return b;
  simd_float2 u = ud / la, v = vd / lb;
  double dot = fmin(fmax((double)simd_dot(u, v), -1.0), 1.0);
  double theta = acos(dot);
  if (theta < 1e-3 || theta > M_PI - 1e-3)
    return b; // straight / degenerate: no corner
  simd_float2 bis = u + v;
  float bl = simd_length(bis);
  if (bl < 1e-6f)
    return b;
  b.valid = YES;
  b.u = u;
  b.v = v;
  b.bis = bis / bl;
  b.la = la;
  b.lb = lb;
  b.theta = theta;
  return b;
}

// Resting offset of the widget from the corner (radius 0), as a fraction of the
// canvas height (object pixel space). ~Rounded's minDim*0.05 inset - a fixed
// canvas-relative gap, so the handle doesn't creep as the shape scales.
static const float kCornerWidgetBaseOffsetObjPx = 0.05f;

CanvasCornerWidget CanvasCornerWidgetObj(NSArray<KKBezierPath *> *layers,
                                         KKBezierPath *path, double frac,
                                         float aspect, NSUInteger i) {
  CanvasCornerWidget w = {0};
  if (!path)
    return w;
  NSUInteger n = path.count;
  if (n < 3)
    return w; // need an interior corner (two neighbours)
  if (aspect <= 0)
    aspect = 1.0f;
  BOOL closed = path.closed;
  if (!(closed || i > 0) || !(closed || i + 1 < n))
    return w;
  NSUInteger pi = i > 0 ? i - 1 : n - 1;
  NSUInteger ni = i + 1 < n ? i + 1 : 0;
  KKBezierPoint P = [path pointAtIndex:i];
  KKBezierPoint A = [path pointAtIndex:pi];
  KKBezierPoint B = [path pointAtIndex:ni];

  // Local edge lengths (pixel space) - for the object<->local radius scale.
  simd_float2 Plpx = simd_make_float2(P.x * aspect, P.y);
  simd_float2 Alpx = simd_make_float2(A.x * aspect, A.y);
  simd_float2 Blpx = simd_make_float2(B.x * aspect, B.y);
  float laL = simd_length(Alpx - Plpx), lbL = simd_length(Blpx - Plpx);
  if (laL < 1e-6f || lbL < 1e-6f)
    return w;

  // Project the corner + neighbours through the layer transform, then work in
  // object pixel space so the offset is canvas-relative.
  simd_float2 Po = CanvasProjectLayerPointObj(layers, path, frac, aspect, P.x, P.y);
  simd_float2 Ao = CanvasProjectLayerPointObj(layers, path, frac, aspect, A.x, A.y);
  simd_float2 Bo = CanvasProjectLayerPointObj(layers, path, frac, aspect, B.x, B.y);
  simd_float2 Ppx = simd_make_float2(Po.x * aspect, Po.y);
  simd_float2 Apx = simd_make_float2(Ao.x * aspect, Ao.y);
  simd_float2 Bpx = simd_make_float2(Bo.x * aspect, Bo.y);
  CanvasCornerBasis basis = CanvasCornerBasisPx(Ppx, Apx, Bpx);
  if (!basis.valid)
    return w;
  simd_float2 bis = basis.bis;

  float maxRObj =
      0.5f * fminf(basis.la, basis.lb) * (float)tan(basis.theta * 0.5);
  // local <-> object scale (shorter edge): radiusObj = radiusLocal × s.
  float s = fminf(basis.la / laL, basis.lb / lbL);
  if (s < 1e-6f)
    s = 1.0f;
  float rObjRaw = [path cornerRadiusAtIndex:i] * s;
  float rObj = rObjRaw > maxRObj ? maxRObj : rObjRaw;
  simd_float2 widgetPx = Ppx + bis * (kCornerWidgetBaseOffsetObjPx + rObj);

  w.valid = YES;
  w.widgetObj = simd_make_float2(widgetPx.x / aspect, widgetPx.y);
  w.anchorObjPx = Ppx;
  w.bisObj = bis;
  w.baseOffsetObjPx = kCornerWidgetBaseOffsetObjPx;
  w.maxRadiusObjPx = maxRObj;
  w.localPerObjScale = 1.0f / s;
  // Flag "at the clamp" only when actually rounded (so a sharp corner's resting
  // widget doesn't read as maxed).
  w.atMax = (rObjRaw > 1e-5f) && (rObjRaw >= maxRObj - 1e-4f);
  return w;
}

KKBezierPath *CanvasPathByExpandingCorners(KKBezierPath *path, float aspect) {
  KKBezierPath *out = [path copy];
  if (!path || !path.hasCornerRadii || path.count < 3)
    return out; // nothing rounded (or too few points to have an interior corner)
  if (aspect <= 0)
    aspect = 1.0f;
  NSUInteger n = path.count;
  BOOL closed = path.closed;

  // Worst case every anchor splits into two.
  KKBezierPoint *pts = malloc(2 * n * sizeof(KKBezierPoint));
  NSUInteger m = 0;

  for (NSUInteger i = 0; i < n; i++) {
    KKBezierPoint cur = [path pointAtIndex:i];
    float r = [path cornerRadiusAtIndex:i];
    BOOL hasPrev = closed || i > 0;
    BOOL hasNext = closed || i + 1 < n;
    if (r <= 0 || !hasPrev || !hasNext) {
      pts[m++] = cur; // sharp anchor (or an open-path endpoint) passes through
      continue;
    }
    NSUInteger pi = i > 0 ? i - 1 : n - 1;
    NSUInteger ni = i + 1 < n ? i + 1 : 0;
    KKBezierPoint pp = [path pointAtIndex:pi], pn = [path pointAtIndex:ni];

    simd_float2 P = ToPx(simd_make_float2(cur.x, cur.y), aspect);
    simd_float2 A = ToPx(simd_make_float2(pp.x, pp.y), aspect);
    simd_float2 B = ToPx(simd_make_float2(pn.x, pn.y), aspect);
    CanvasCornerBasis basis = CanvasCornerBasisPx(P, A, B);
    if (!basis.valid) {
      pts[m++] = cur; // degenerate / straight: nothing to round
      continue;
    }
    double d = CanvasCornerInsetForRadius(r, basis.theta);
    // Clamp so the two tangent points stay on their edges and adjacent corners
    // don't overlap (leave each edge half to its neighbour).
    double dMax = 0.5 * fmin((double)basis.la, (double)basis.lb);
    if (d > dMax)
      d = dMax;
    double rEff = CanvasCornerRadiusForInset(d, basis.theta);
    double phi = M_PI - basis.theta;
    double h = (4.0 / 3.0) * tan(phi * 0.25) * rEff;

    simd_float2 T1px = P + basis.u * (float)d, T2px = P + basis.v * (float)d;
    simd_float2 T1outPx = -basis.u * (float)h, T2inPx = -basis.v * (float)h;
    simd_float2 T1 = ToObj(T1px, aspect), T2 = ToObj(T2px, aspect);
    simd_float2 T1out = ToObj(T1outPx, aspect), T2in = ToObj(T2inPx, aspect);

    pts[m++] = (KKBezierPoint){.x = T1.x,
                               .y = T1.y,
                               .inX = 0,
                               .inY = 0,
                               .outX = T1out.x,
                               .outY = T1out.y,
                               .type = KKBezierPointBezier};
    pts[m++] = (KKBezierPoint){.x = T2.x,
                               .y = T2.y,
                               .inX = T2in.x,
                               .inY = T2in.y,
                               .outX = 0,
                               .outY = 0,
                               .type = KKBezierPointBezier};
  }

  [out setBezierPoints:pts count:m closed:closed];
  free(pts);
  return out;
}
