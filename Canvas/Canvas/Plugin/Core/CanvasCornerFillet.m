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

// The [start, end) index range of the contour containing anchor `i`. A
// multi-contour path (e.g. a boolean result) must wrap a corner's neighbours
// WITHIN its own subpath - using the whole-path ends would build the corner
// from a point in another subpath, mis-validating contour-boundary corners.
static void CanvasContourBoundsForIndex(KKBezierPath *path, NSUInteger i,
                                        NSUInteger *outStart,
                                        NSUInteger *outEnd) {
  NSUInteger nc = path.contourCount;
  for (NSUInteger c = 0; c < nc; c++) {
    NSRange r = [path contourRangeAtIndex:c];
    if (i >= r.location && i < NSMaxRange(r)) {
      *outStart = r.location;
      *outEnd = NSMaxRange(r);
      return;
    }
  }
  *outStart = 0;
  *outEnd = path.count;
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
// space): the unit edge directions, the edge lengths, the interior angle and
// the interior bisector. Shared by the fillet expander (local space) and the
// widget (projected space) - they differ only in which points they feed in.
// `valid` is NO for a degenerate / near-straight corner.
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
// A corner only surfaces a (resting) radius widget when it's a genuine sharp
// corner: the turn must exceed this, and the anchor must not be a smooth bezier
// point. A corner that already HAS a radius always shows (so it stays
// adjustable / clearable).
static const float kCornerMinTurnRad = 0.349f; // ~20 degrees off straight

CanvasCornerWidget CanvasCornerWidgetObj(NSArray<KKBezierPath *> *layers,
                                         KKBezierPath *path, double frac,
                                         float aspect, NSUInteger i) {
  CanvasProjCtx ctx = CanvasProjCtxMake(layers, path, frac, aspect);
  return CanvasCornerWidgetObjCtx(path, i, &ctx);
}

// Context-reusing variant: the caller builds the projection context ONCE (it is
// invariant across the path) and passes it in, so a per-anchor corner-widget
// pass is O(N) instead of O(N^2) - the old form rebuilt the layer transform +
// object centre + group xforms on each of the 3 per-corner projections.
CanvasCornerWidget CanvasCornerWidgetObjCtx(KKBezierPath *path, NSUInteger i,
                                            const CanvasProjCtx *ctx) {
  CanvasCornerWidget w = {0};
  if (!path || !ctx)
    return w;
  NSUInteger n = path.count;
  if (n < 3)
    return w; // need an interior corner (two neighbours)
  float aspect = ctx->aspect;
  if (aspect <= 0)
    aspect = 1.0f;
  NSUInteger cs, ce;
  CanvasContourBoundsForIndex(path, i, &cs, &ce);
  // A subpath of a multi-contour result is a closed loop; the whole-path closed
  // flag governs a lone contour (e.g. an open pen path).
  BOOL contourClosed = (path.contourCount > 1) ? YES : path.closed;
  if (!(contourClosed || i > cs) || !(contourClosed || i + 1 < ce))
    return w;
  if (ce - cs < 3)
    return w; // a too-small contour has no interior corner
  NSUInteger pi = (i > cs) ? i - 1 : ce - 1;
  NSUInteger ni = (i + 1 < ce) ? i + 1 : cs;
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
  simd_float2 Po = CanvasProjectWithCtx(ctx, P.x, P.y);
  simd_float2 Ao = CanvasProjectWithCtx(ctx, A.x, A.y);
  simd_float2 Bo = CanvasProjectWithCtx(ctx, B.x, B.y);
  simd_float2 Ppx = simd_make_float2(Po.x * aspect, Po.y);
  simd_float2 Apx = simd_make_float2(Ao.x * aspect, Ao.y);
  simd_float2 Bpx = simd_make_float2(Bo.x * aspect, Bo.y);
  CanvasCornerBasis basis = CanvasCornerBasisPx(Ppx, Apx, Bpx);
  if (!basis.valid)
    return w;

  // Smart visibility: a corner with no radius yet only shows its widget when
  // it's a real sharp corner - skip near-straight points and smooth bezier
  // points (tangent-continuous), which clutter detailed imported paths. A
  // corner that already has a radius set bypasses this so it stays adjustable.
  if ([path cornerRadiusAtIndex:i] <= 1e-5f) {
    if (basis.theta > (double)(M_PI - kCornerMinTurnRad))
      return w; // too close to straight - nothing to round
    simd_float2 hin = simd_make_float2(P.inX, P.inY);
    simd_float2 hout = simd_make_float2(P.outX, P.outY);
    float li = simd_length(hin), lo = simd_length(hout);
    if (li > 1e-5f && lo > 1e-5f && simd_dot(hin / li, hout / lo) < -0.95f)
      return w; // smooth tangent point - already a continuous curve
  }

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
    return out; // nothing rounded (or too few points to have an interior
                // corner)
  if (aspect <= 0)
    aspect = 1.0f;
  NSUInteger n = path.count;
  BOOL closed = path.closed;
  NSUInteger nc = path.contourCount;

  // Worst case every anchor splits into two.
  KKBezierPoint *pts = malloc(2 * n * sizeof(KKBezierPoint));
  NSUInteger m = 0;
  // New contour starts (in the EXPANDED index space), one per contour after the
  // first - rounding adds points, so the original boundaries shift. Without
  // this a multi-contour boolean result (e.g. an XOR of two rects) would
  // collapse to a single contour and the renderer would join its subpaths with
  // a stray seam.
  NSMutableArray<NSNumber *> *newStarts = [NSMutableArray array];

  for (NSUInteger c = 0; c < nc; c++) {
    NSRange range = [path contourRangeAtIndex:c];
    NSUInteger cs = range.location, ce = NSMaxRange(range); // [cs, ce)
    NSUInteger cn = range.length;
    if (c > 0)
      [newStarts addObject:@(m)]; // this contour begins here post-expansion
    // A multi-contour path's subpaths are always closed loops (boolean
    // results); the whole-path `closed` flag governs a lone contour (e.g. an
    // open pen path).
    BOOL contourClosed = (nc > 1) ? YES : closed;
    for (NSUInteger i = cs; i < ce; i++) {
      KKBezierPoint cur = [path pointAtIndex:i];
      float r = [path cornerRadiusAtIndex:i];
      BOOL hasPrev = contourClosed || i > cs;
      BOOL hasNext = contourClosed || i + 1 < ce;
      if (r <= 0 || !hasPrev || !hasNext || cn < 3) {
        pts[m++] =
            cur; // sharp anchor (or an open-contour endpoint) passes through
        continue;
      }
      // Prev / next wrap WITHIN this contour, not across the whole path - else
      // a contour-boundary corner would build its basis from a neighbour in
      // another subpath and round wrong (or get skipped as degenerate).
      NSUInteger pi = (i > cs) ? i - 1 : ce - 1;
      NSUInteger ni = (i + 1 < ce) ? i + 1 : cs;
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
      // Clamp so the two tangent points stay on their edges and adjacent
      // corners don't overlap (leave each edge half to its neighbour).
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
  }

  [out setBezierPoints:pts count:m closed:closed];
  // Re-establish the (shifted) contour boundaries; single-contour paths leave
  // this empty so nothing changes for them.
  if (newStarts.count > 0)
    [out setContourStarts:newStarts];
  free(pts);
  return out;
}

NSUInteger CanvasPathFilletArcs(KKBezierPath *path, float aspect,
                                CanvasFilletArc *out, NSUInteger maxOut) {
  if (!path || !out || maxOut == 0 || !path.hasCornerRadii || path.count < 3)
    return 0;
  if (aspect <= 0)
    aspect = 1.0f;
  NSUInteger nc = path.contourCount;
  BOOL closed = path.closed;
  NSUInteger m = 0;
  for (NSUInteger c = 0; c < nc && m < maxOut; c++) {
    NSRange range = [path contourRangeAtIndex:c];
    NSUInteger cs = range.location, ce = NSMaxRange(range);
    NSUInteger cn = range.length;
    BOOL contourClosed = (nc > 1) ? YES : closed;
    for (NSUInteger i = cs; i < ce && m < maxOut; i++) {
      float r = [path cornerRadiusAtIndex:i];
      BOOL hasPrev = contourClosed || i > cs;
      BOOL hasNext = contourClosed || i + 1 < ce;
      if (r <= 0 || !hasPrev || !hasNext || cn < 3)
        continue;
      KKBezierPoint cur = [path pointAtIndex:i];
      NSUInteger pi = (i > cs) ? i - 1 : ce - 1;
      NSUInteger ni = (i + 1 < ce) ? i + 1 : cs;
      KKBezierPoint pp = [path pointAtIndex:pi], pn = [path pointAtIndex:ni];
      simd_float2 P = ToPx(simd_make_float2(cur.x, cur.y), aspect);
      simd_float2 A = ToPx(simd_make_float2(pp.x, pp.y), aspect);
      simd_float2 B = ToPx(simd_make_float2(pn.x, pn.y), aspect);
      CanvasCornerBasis basis = CanvasCornerBasisPx(P, A, B);
      if (!basis.valid)
        continue;
      double d = CanvasCornerInsetForRadius(r, basis.theta);
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
      out[m].t1 = T1;
      out[m].c1 = T1 + T1out;
      out[m].c2 = T2 + T2in;
      out[m].t2 = T2;
      m++;
    }
  }
  return m;
}
