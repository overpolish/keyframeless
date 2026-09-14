/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPathEditGeometry.h"
#import <KeyframelessKit/KKBezierPath.h>

double CanvasDistPtToSeg(double px, double py, CGPoint a, CGPoint b,
                         double *outT) {
  double dx = b.x - a.x, dy = b.y - a.y;
  double l2 = dx * dx + dy * dy;
  double t = l2 > 1e-9 ? ((px - a.x) * dx + (py - a.y) * dy) / l2 : 0.0;
  t = fmin(fmax(t, 0.0), 1.0);
  double cx = a.x + dx * t, cy = a.y + dy * t;
  *outT = t;
  return (px - cx) * (px - cx) + (py - cy) * (py - cy);
}

KKBezierPath *CanvasPathByInsertingAnchor(KKBezierPath *path, NSUInteger seg,
                                          double tIn) {
  NSUInteger count = path.count;
  if (count < 2)
    return [path copy];
  NSUInteger next = (seg + 1) % count;
  KKBezierPoint A = [path pointAtIndex:seg];
  KKBezierPoint B = [path pointAtIndex:next];
  float t = (float)fmin(fmax(tIn, 0.0), 1.0);
  KKBezierPath *out = [path copy];
  NSUInteger ni = seg + 1; // inserted anchor index
  NSUInteger bIdx =
      (next > seg) ? next + 1 : next; // B's index after the insert

  simd_float2 P0 = {A.x, A.y}, P3 = {B.x, B.y};
  if (A.type == KKBezierPointLinear && B.type == KKBezierPointLinear) {
    [out insertAtIndex:ni position:CanvasLerp2(P0, P3, t)];
    [out setType:KKBezierPointLinear atIndex:ni];
    return out;
  }
  simd_float2 P1 = {A.x + A.outX, A.y + A.outY};
  simd_float2 P2 = {B.x + B.inX, B.y + B.inY};
  simd_float2 P01 = CanvasLerp2(P0, P1, t);
  simd_float2 P12 = CanvasLerp2(P1, P2, t);
  simd_float2 P23 = CanvasLerp2(P2, P3, t);
  simd_float2 P012 = CanvasLerp2(P01, P12, t);
  simd_float2 P123 = CanvasLerp2(P12, P23, t);
  simd_float2 P0123 = CanvasLerp2(P012, P123, t);
  [out setOutHandle:simd_make_float2(P01.x - P0.x, P01.y - P0.y) atIndex:seg];
  [out insertAtIndex:ni position:P0123];
  [out setType:KKBezierPointBezier atIndex:ni];
  [out setInHandle:simd_make_float2(P012.x - P0123.x, P012.y - P0123.y)
           atIndex:ni];
  [out setOutHandle:simd_make_float2(P123.x - P0123.x, P123.y - P0123.y)
            atIndex:ni];
  [out setInHandle:simd_make_float2(P23.x - P3.x, P23.y - P3.y) atIndex:bIdx];
  return out;
}

void CanvasPathAutoSmoothAnchor(KKBezierPath *path, NSUInteger i,
                                float aspect) {
  NSUInteger n = path.count;
  if (n < 2 || i >= n)
    return;
  if (aspect <= 0)
    aspect = 1.0f;
  KKBezierPoint c = [path pointAtIndex:i];
  simd_float2 P = simd_make_float2(c.x * aspect, c.y);
  BOOL hasPrev = (i > 0) || path.closed;
  BOOL hasNext = (i + 1 < n) || path.closed;
  NSUInteger pi = i > 0 ? i - 1 : n - 1;
  NSUInteger ni = i + 1 < n ? i + 1 : 0;
  KKBezierPoint pp = [path pointAtIndex:pi], pn = [path pointAtIndex:ni];
  simd_float2 Pp = simd_make_float2(pp.x * aspect, pp.y);
  simd_float2 Pn = simd_make_float2(pn.x * aspect, pn.y);
  simd_float2 dir = (hasPrev && hasNext) ? (Pn - Pp)
                    : hasNext            ? (Pn - P)
                                         : (P - Pp);
  float len = simd_length(dir);
  if (len < 1e-5f)
    return;
  dir /= len;
  const float k = 1.0f / 3.0f;
  [path setType:KKBezierPointBezier atIndex:i];
  simd_float2 out =
      hasNext ? dir * (simd_distance(P, Pn) * k) : simd_make_float2(0, 0);
  simd_float2 in =
      hasPrev ? -dir * (simd_distance(P, Pp) * k) : simd_make_float2(0, 0);
  [path setOutHandle:simd_make_float2(out.x / aspect, out.y) atIndex:i];
  [path setInHandle:simd_make_float2(in.x / aspect, in.y) atIndex:i];
}
