/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Stroke endpoint markers (arrow / circle / square / open arrowhead / tick).
// Reworked from the pre-v3 _Attic MarkerTessellation: every marker is now ONE
// triangle LIST so the start + end markers batch into a single buffer + draw,
// and they carry the same textureCoordinate.y edge-distance the stroke + dotted
// disc use (rim ±1, interior 0) so KKLineFragment antialiases their edges the
// same way - the old flat 3-vertex arrow had no AA, which is what read as
// rough.

#import "CanvasMarkerTessellate.h"
#import "CanvasStrokeTessellateInternal.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <simd/simd.h>

// Marker geometry proportions (fractions of the marker size).
static const float kArrowWingFrac = 0.55f; // half-spread of an arrow/chevron
static const int kMarkerCircleMaxSegs = 96;

static inline simd_float2 CanvasMkPerp(simd_float2 d) {
  return simd_make_float2(-d.y, d.x);
}

static inline NSUInteger CanvasMkTri(KKVertex2D *o, NSUInteger vc,
                                     NSUInteger max, simd_float2 a, float aty,
                                     simd_float2 b, float bty, simd_float2 c,
                                     float cty) {
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

// Chord segments so a disc of `radius` stays smooth (chord error <= 0.25 px),
// clamped. Mirrors the _Attic circle metric.
static NSUInteger CanvasMkCircleSegs(float radius) {
  if (radius < 1.0f)
    return 16;
  float c = 1.0f - 0.25f / radius;
  if (c < -1.0f)
    c = -1.0f;
  NSUInteger segs = (NSUInteger)ceilf((float)M_PI / acosf(c));
  if (segs < 16)
    segs = 16;
  if (segs > (NSUInteger)kMarkerCircleMaxSegs)
    segs = kMarkerCircleMaxSegs;
  return segs;
}

// A filled convex polygon (<= 8 corners) as an AA triangle fan: each corner is
// pushed `pad` px outward from the centroid so the solid core reaches the asked
// size and KKLineFragment fades the outer ~1px (rim ty=1, centroid ty=0). The
// closing edge between the first/last corner is included.
static NSUInteger CanvasMkFilledFan(KKVertex2D *o, NSUInteger vc,
                                    NSUInteger max, const simd_float2 *corners,
                                    NSUInteger n, float pad) {
  if (n < 3)
    return vc;
  simd_float2 centroid = simd_make_float2(0.0f, 0.0f);
  for (NSUInteger i = 0; i < n; i++)
    centroid += corners[i];
  centroid /= (float)n;
  simd_float2 rim[8];
  if (n > 8)
    n = 8;
  for (NSUInteger i = 0; i < n; i++) {
    simd_float2 out = corners[i] - centroid;
    float l = simd_length(out);
    rim[i] = (l > 1e-4f) ? corners[i] + out / l * pad : corners[i];
  }
  for (NSUInteger i = 0; i < n; i++)
    vc = CanvasMkTri(o, vc, max, centroid, 0.0f, rim[i], 1.0f, rim[(i + 1) % n],
                     1.0f);
  return vc;
}

// A filled disc (centre ty=0, rim ty=1), like the dotted-stroke dot.
static NSUInteger CanvasMkDisc(KKVertex2D *o, NSUInteger vc, NSUInteger max,
                               simd_float2 center, float radius) {
  NSUInteger segs = CanvasMkCircleSegs(radius);
  for (NSUInteger s = 0; s < segs; s++) {
    float a0 = (float)s / (float)segs * 2.0f * (float)M_PI;
    float a1 = (float)(s + 1) / (float)segs * 2.0f * (float)M_PI;
    simd_float2 d0 = simd_make_float2(cosf(a0), sinf(a0));
    simd_float2 d1 = simd_make_float2(cosf(a1), sinf(a1));
    vc = CanvasMkTri(o, vc, max, center, 0.0f, center + d0 * radius, 1.0f,
                     center + d1 * radius, 1.0f);
  }
  return vc;
}

// A thick straight bar from p0 to p1 (an open marker's arm / tick), as two
// triangles. The two long edges carry ty ±1 so KKLineFragment rail-AAs them;
// the half-thickness includes the AA pad so the core reaches `halfThick`.
static NSUInteger CanvasMkBar(KKVertex2D *o, NSUInteger vc, NSUInteger max,
                              simd_float2 p0, simd_float2 p1, float halfThick) {
  simd_float2 d = p1 - p0;
  if (simd_length_squared(d) < 1e-10f)
    return vc;
  simd_float2 perp = CanvasMkPerp(simd_normalize(d));
  float ht = halfThick + kCanvasAAPaddingPx;
  simd_float2 a0 = p0 + perp * ht, a1 = p0 - perp * ht;
  simd_float2 b0 = p1 + perp * ht, b1 = p1 - perp * ht;
  vc = CanvasMkTri(o, vc, max, a0, 1.0f, a1, -1.0f, b0, 1.0f);
  vc = CanvasMkTri(o, vc, max, a1, -1.0f, b1, -1.0f, b0, 1.0f);
  return vc;
}

// One marker at `endpoint`, oriented by the OUTWARD unit `tangent` (pointing
// away from the path) and its `normal`. `size` is the marker extent, `strokeW`
// the open-marker bar thickness (both scaled px).
static NSUInteger CanvasMkOne(KKVertex2D *o, NSUInteger vc, NSUInteger max,
                              uint8_t type, simd_float2 endpoint,
                              simd_float2 tangent, simd_float2 normal,
                              float size, float strokeW) {
  if (type == CanvasMarkerNone || size <= 0.0f)
    return vc;
  float wing = size * kArrowWingFrac;
  float halfThick = strokeW * 0.5f;
  switch (type) {
  case CanvasMarkerArrow: {
    simd_float2 base = endpoint - tangent * size;
    simd_float2 corners[3] = {base + normal * wing, endpoint,
                              base - normal * wing};
    return CanvasMkFilledFan(o, vc, max, corners, 3, kCanvasAAPaddingPx);
  }
  case CanvasMarkerCircle:
    return CanvasMkDisc(o, vc, max, endpoint, size * 0.5f + kCanvasAAPaddingPx);
  case CanvasMarkerSquare: {
    float h = size * 0.5f;
    simd_float2 f = tangent * h, s = normal * h;
    simd_float2 corners[4] = {endpoint - f + s, endpoint + f + s,
                              endpoint + f - s, endpoint - f - s};
    return CanvasMkFilledFan(o, vc, max, corners, 4, kCanvasAAPaddingPx);
  }
  case CanvasMarkerArrowhead: {
    simd_float2 base = endpoint - tangent * size;
    vc = CanvasMkBar(o, vc, max, base + normal * wing, endpoint, halfThick);
    vc = CanvasMkBar(o, vc, max, base - normal * wing, endpoint, halfThick);
    return vc;
  }
  case CanvasMarkerLine: {
    float half = size * 0.5f;
    return CanvasMkBar(o, vc, max, endpoint + normal * half,
                       endpoint - normal * half, halfThick);
  }
  default:
    return vc;
  }
}

NSUInteger CanvasMarkerVertexCapacity(void) {
  // Worst case per end is a max-segment disc; both ends + slack.
  return (NSUInteger)(2 * kMarkerCircleMaxSegs * 3 + 64);
}

float CanvasMarkerPullback(uint8_t markerType, float markerSizePx) {
  // Arrow: end the stroke ~0.88 of the way back from the tip so it stops near
  // the wide BASE of the filled triangle - a curved approach offsets the stroke
  // end from the arrow's straight axis, and the base is wide enough to still
  // cover it (a shallower pullback let the curve poke out the narrowing sides).
  // The other types either centre on the endpoint (Circle/Square) or are open /
  // perpendicular (Arrowhead/Line), so the stroke runs right to the endpoint.
  return (markerType == CanvasMarkerArrow) ? markerSizePx * 0.88f : 0.0f;
}

// The point at arc length `target` measured inward from an end of the polyline
// (`fromStart`: from pts[0]; else from pts[n-1]). Clamps to the far end when
// `target` runs past the polyline.
static void CanvasMkPointAtArcFromEnd(const simd_float2 *pts, NSUInteger n,
                                      BOOL fromStart, float target,
                                      simd_float2 *out) {
  if (target <= 0.0f) {
    *out = fromStart ? pts[0] : pts[n - 1];
    return;
  }
  float acc = 0.0f;
  if (fromStart) {
    for (NSUInteger i = 0; i + 1 < n; i++) {
      float seg = simd_distance(pts[i + 1], pts[i]);
      if (acc + seg >= target) {
        float t = seg > 1e-6f ? (target - acc) / seg : 0.0f;
        *out = pts[i] + (pts[i + 1] - pts[i]) * t;
        return;
      }
      acc += seg;
    }
    *out = pts[n - 1];
  } else {
    for (NSInteger i = (NSInteger)n - 1; i > 0; i--) {
      float seg = simd_distance(pts[i - 1], pts[i]);
      if (acc + seg >= target) {
        float t = seg > 1e-6f ? (target - acc) / seg : 0.0f;
        *out = pts[i] + (pts[i - 1] - pts[i]) * t;
        return;
      }
      acc += seg;
    }
    *out = pts[0];
  }
}

// Anchor point + outward unit tangent at arc `offset` inward from an end, on
// the FULL polyline. Each marker anchors INDEPENDENTLY (no shared trim), so two
// markers riding toward each other (both Arrows on a shrinking draw-on span)
// can't collapse the polyline and vanish - they just shrink past each other.
// The tangent is measured over `window` px (robust on curves) and points from
// the far sample toward the anchor (i.e. outward, toward that end). `offset`
// past the polyline clamps to the far end. NO if degenerate.
static BOOL CanvasMkAnchorAtArc(const simd_float2 *pts, NSUInteger n,
                                BOOL fromStart, float offset, float window,
                                simd_float2 *outPoint,
                                simd_float2 *outTangent) {
  if (n < 2)
    return NO;
  float off = fmaxf(0.0f, offset);
  simd_float2 anchor, far;
  CanvasMkPointAtArcFromEnd(pts, n, fromStart, off, &anchor);
  CanvasMkPointAtArcFromEnd(pts, n, fromStart, off + window, &far);
  simd_float2 d = anchor - far; // outward (away from the path interior)
  if (simd_length_squared(d) < 1e-10f)
    return NO;
  *outPoint = anchor;
  *outTangent = simd_normalize(d);
  return YES;
}

NSUInteger CanvasTessellateMarkers(KKBezierPath *path, float outputWidth,
                                   float outputHeight, uint8_t startMarker,
                                   uint8_t endMarker, float startSizePx,
                                   float endSizePx, float startStrokePx,
                                   float endStrokePx, float trimStartPx,
                                   float trimEndPx, KKVertex2D *outVerts,
                                   NSUInteger maxVerts) {
  if (!outVerts || maxVerts < 3 || path.count < 2)
    return 0;
  if (startMarker == CanvasMarkerNone && endMarker == CanvasMarkerNone)
    return 0;
  // Open free ends only: a closed or compound path has none.
  if (path.contourCount > 1 || path.closed)
    return 0;

  NSRange r = [path contourRangeAtIndex:0];
  NSUInteger polyCap = CanvasMaxContourPolyCap(path, NO);
  if (polyCap == 0)
    return 0;
  simd_float2 *pts = malloc(sizeof(simd_float2) * polyCap);
  NSUInteger n = CanvasBuildContourPolyline(path, r, NO, outputWidth,
                                            outputHeight, pts, polyCap);
  if (n < 2) {
    free(pts);
    return 0;
  }
  // Anchor each marker INDEPENDENTLY at its arc offset (trimStartPx /
  // trimEndPx) on the full polyline so a marker riding a draw-on tip (the
  // Arrow) doesn't disturb the other end. Tangent window per type: only the big
  // FILLED arrow reads best aligned over its whole FOOTPRINT (the marker size =
  // a chord); the centred square, the tick and the open arrowhead align with
  // the LINE's LOCAL direction (the stroke-width scale), and the circle is
  // rotation-free either way.
  NSUInteger vc = 0;
  if (startMarker != CanvasMarkerNone) {
    float window = (startMarker == CanvasMarkerArrow)
                       ? fmaxf(startSizePx, 4.0f)
                       : fmaxf(startStrokePx, 6.0f);
    simd_float2 anchor, tangent;
    if (CanvasMkAnchorAtArc(pts, n, YES, trimStartPx, window, &anchor,
                            &tangent))
      vc = CanvasMkOne(outVerts, vc, maxVerts, startMarker, anchor, tangent,
                       CanvasMkPerp(tangent), startSizePx, startStrokePx);
  }
  if (endMarker != CanvasMarkerNone) {
    float window = (endMarker == CanvasMarkerArrow) ? fmaxf(endSizePx, 4.0f)
                                                    : fmaxf(endStrokePx, 6.0f);
    simd_float2 anchor, tangent;
    if (CanvasMkAnchorAtArc(pts, n, NO, trimEndPx, window, &anchor, &tangent))
      vc = CanvasMkOne(outVerts, vc, maxVerts, endMarker, anchor, tangent,
                       CanvasMkPerp(tangent), endSizePx, endStrokePx);
  }

  free(pts);
  return vc;
}
