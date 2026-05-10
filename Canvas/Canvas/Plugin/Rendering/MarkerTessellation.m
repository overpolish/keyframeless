/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MarkerTessellation.h"
#import <Foundation/Foundation.h>

static inline CanvasVertex markerVert(simd_float2 pos) {
  return (CanvasVertex){pos, 0.0f, 0.0f};
}

static inline CanvasVertex markerVertCap(simd_float2 pos, float capDistance) {
  return (CanvasVertex){pos, 0.0f, capDistance};
}

// Segments needed so chord error ≤ 0.25 px at the given radius.
// n = π / acos(1 - 0.25/r). Clamped to [16, 96].
static inline NSUInteger circleSegmentsForRadius(float radius) {
  if (radius < 1.0f)
    return 16;
  float c = 1.0f - 0.25f / radius;
  if (c < -1.0f)
    c = -1.0f;
  float n = (float)M_PI / acosf(c);
  NSUInteger segs = (NSUInteger)ceilf(n);
  if (segs < 16)
    segs = 16;
  if (segs > 96)
    segs = 96;
  return segs;
}

static uint32_t s_markerRng;
static void markerSeedRNG(uint32_t seed) { s_markerRng = seed ? seed : 1; }
static float markerRandUnit(void) {
  s_markerRng ^= s_markerRng << 13;
  s_markerRng ^= s_markerRng >> 17;
  s_markerRng ^= s_markerRng << 5;
  return (float)(s_markerRng & 0xFFFF) / 65536.0f;
}
static float markerOffset(float amplitude, float roughness) {
  return roughness * (markerRandUnit() * 2.0f * amplitude - amplitude);
}

/// Arrow marker: tip at endpoint, base pulled back by depth.
/// Emits a triangle strip: left, tip, right (1 triangle, 3 verts).
static NSUInteger tessellateArrow(simd_float2 endpoint, simd_float2 tangent,
                                  simd_float2 normal, float size,
                                  CanvasVertex *v) {
  float wingSpread = size * 0.5f;
  simd_float2 base = endpoint - tangent * size;
  simd_float2 left = base + normal * wingSpread;
  simd_float2 right = base - normal * wingSpread;

  NSUInteger vc = 0;
  v[vc++] = markerVert(left);
  v[vc++] = markerVert(endpoint);
  v[vc++] = markerVert(right);
  return vc;
}

/// Circle marker: far edge at endpoint, center pulled back by radius.
/// Triangle fan as strip: center, rim0, center, rim1, ...
static NSUInteger tessellateCircle(simd_float2 endpoint, simd_float2 tangent,
                                   float radius, CanvasVertex *v) {
  NSUInteger segments = circleSegmentsForRadius(radius);
  NSUInteger vc = 0;
  for (NSUInteger i = 0; i <= segments; i++) {
    float angle = (float)i / (float)segments * 2.0f * (float)M_PI;
    simd_float2 rim =
        endpoint + (simd_float2){cosf(angle) * radius, sinf(angle) * radius};
    v[vc++] = markerVertCap(endpoint, 0.0f);
    v[vc++] = markerVertCap(rim, 1.0f);
  }
  return vc;
}

/// Square marker: far edge at endpoint, center pulled back by halfSide.
/// Triangle strip: a, b, c, d forming a quad.
static NSUInteger tessellateSquare(simd_float2 endpoint, simd_float2 tangent,
                                   simd_float2 normal, float halfSide,
                                   CanvasVertex *v) {
  simd_float2 fwd = tangent * halfSide;
  simd_float2 side = normal * halfSide;

  // Strip order: top-left, bottom-left, top-right, bottom-right.
  NSUInteger vc = 0;
  v[vc++] = markerVert(endpoint - fwd + side);
  v[vc++] = markerVert(endpoint - fwd - side);
  v[vc++] = markerVert(endpoint + fwd + side);
  v[vc++] = markerVert(endpoint + fwd - side);
  return vc;
}

// Forward declarations — sketch versions serve as the canonical implementation
// for arrowhead and line markers; regular versions call with roughness=0.
static inline simd_float2 jitterPt(simd_float2 pt, float amp, float roughness);
static NSUInteger tessellateSketchArrowhead(simd_float2 endpoint,
                                            simd_float2 tangent,
                                            simd_float2 normal, float size,
                                            float strokeWidth, float roughness,
                                            CanvasVertex *v);
static NSUInteger tessellateSketchLine(simd_float2 endpoint,
                                       simd_float2 tangent, simd_float2 normal,
                                       float size, float strokeWidth,
                                       float roughness, CanvasVertex *v);

float KKMarkerPullback(uint8_t markerType, float markerSize) {
  // Stroke ends slightly inside the marker so it's fully covered by the fill.
  // The fraction is chosen so the stroke never pokes out the sides, even at
  // small marker sizes (arrow narrows toward the tip, so we stay near the
  // base).
  switch (markerType) {
  case 1:
    return markerSize * 0.7f; // arrow: 30% inside from base
  case 2:
    return 0.0f; // circle: centered on endpoint
  case 3:
    return 0.0f; // square: centered on endpoint
  case 4:
    return 0.0f; // arrowhead: open, stroke extends to tip
  case 5:
    return 0.0f; // line: bar sits at endpoint
  default:
    return 0.0f;
  }
}

NSUInteger KKTessellateMarker(uint8_t markerType, simd_float2 endpoint,
                              simd_float2 tangent, simd_float2 normal,
                              float markerSize, float strokeWidth,
                              MTLPrimitiveType *primitiveType,
                              CanvasVertex *vertices) {
  if (markerType == 0)
    return 0;

  switch (markerType) {
  case 1: // Arrow
    *primitiveType = MTLPrimitiveTypeTriangleStrip;
    return tessellateArrow(endpoint, tangent, normal, markerSize, vertices);
  case 2: // Circle
    *primitiveType = MTLPrimitiveTypeTriangleStrip;
    return tessellateCircle(endpoint, tangent, markerSize * 0.5f, vertices);
  case 3: // Square
    *primitiveType = MTLPrimitiveTypeTriangleStrip;
    return tessellateSquare(endpoint, tangent, normal, markerSize * 0.5f,
                            vertices);
  case 4: // Arrowhead
    *primitiveType = MTLPrimitiveTypeTriangle;
    return tessellateSketchArrowhead(endpoint, tangent, normal, markerSize,
                                     strokeWidth, 0.0f, vertices);
  case 5: // Line
    *primitiveType = MTLPrimitiveTypeTriangleStrip;
    return tessellateSketchLine(endpoint, tangent, normal, markerSize,
                                strokeWidth, 0.0f, vertices);
  default:
    return 0;
  }
}

/// Triangle fan from outline points (center/rim alternating strip, same
/// pattern as tessellateCircle).
static NSUInteger emitFan(simd_float2 *outline, NSUInteger count,
                          CanvasVertex *v) {
  if (count < 3)
    return 0;
  simd_float2 center = {0, 0};
  for (NSUInteger i = 0; i < count; i++)
    center += outline[i];
  center /= (float)count;

  NSUInteger vc = 0;
  for (NSUInteger i = 0; i <= count; i++) {
    v[vc++] = markerVert(center);
    v[vc++] = markerVert(outline[i % count]);
  }
  return vc;
}

/// Subdivide polygon edges and jitter each subdivision point.
static NSUInteger subdivideAndJitter(simd_float2 *corners,
                                     NSUInteger cornerCount,
                                     NSUInteger subsPerEdge, float jitterAmp,
                                     float roughness, simd_float2 *outline) {
  NSUInteger oc = 0;
  for (NSUInteger i = 0; i < cornerCount; i++) {
    simd_float2 a = corners[i];
    simd_float2 b = corners[(i + 1) % cornerCount];
    simd_float2 edge = b - a;
    float edgeLen = simd_length(edge);
    simd_float2 edgeDir =
        edgeLen > 0.0001f ? edge / edgeLen : (simd_float2){1, 0};
    simd_float2 edgeNorm = {-edgeDir.y, edgeDir.x};

    for (NSUInteger s = 0; s < subsPerEdge; s++) {
      float t = (float)s / (float)subsPerEdge;
      simd_float2 pt = a + edge * t;
      float amp = (s == 0) ? jitterAmp * 0.3f : jitterAmp;
      float perpOff = markerOffset(amp, roughness);
      float tangOff = markerOffset(amp * 0.3f, roughness);
      outline[oc++] = pt + edgeNorm * perpOff + edgeDir * tangOff;
    }
  }
  return oc;
}

static NSUInteger tessellateSketchArrow(simd_float2 endpoint,
                                        simd_float2 tangent, simd_float2 normal,
                                        float size, float roughness,
                                        CanvasVertex *v) {
  float wingSpread = size * 0.5f;
  simd_float2 base = endpoint - tangent * size;
  simd_float2 corners[3] = {base + normal * wingSpread, endpoint,
                            base - normal * wingSpread};
  float jitterAmp = size * 0.035f;
  simd_float2 outline[24];
  NSUInteger oc =
      subdivideAndJitter(corners, 3, 8, jitterAmp, roughness, outline);
  return emitFan(outline, oc, v);
}

static NSUInteger tessellateSketchCircle(simd_float2 endpoint,
                                         simd_float2 tangent, float radius,
                                         float roughness, CanvasVertex *v) {
  NSUInteger segments = circleSegmentsForRadius(radius);
  if (segments > 96)
    segments = 96;
  float jitterAmp = radius * 0.07f;
  simd_float2 outline[96];
  for (NSUInteger i = 0; i < segments; i++) {
    float angle = (float)i / (float)segments * 2.0f * (float)M_PI;
    float r = radius + markerOffset(jitterAmp, roughness);
    outline[i] = endpoint + (simd_float2){cosf(angle) * r, sinf(angle) * r};
  }
  return emitFan(outline, segments, v);
}

static NSUInteger tessellateSketchSquare(simd_float2 endpoint,
                                         simd_float2 tangent,
                                         simd_float2 normal, float halfSide,
                                         float roughness, CanvasVertex *v) {
  simd_float2 fwd = tangent * halfSide;
  simd_float2 side = normal * halfSide;
  simd_float2 corners[4] = {endpoint - fwd + side, endpoint + fwd + side,
                            endpoint + fwd - side, endpoint - fwd - side};
  float jitterAmp = halfSide * 0.06f;
  simd_float2 outline[24];
  NSUInteger oc =
      subdivideAndJitter(corners, 4, 6, jitterAmp, roughness, outline);
  return emitFan(outline, oc, v);
}

static inline simd_float2 jitterPt(simd_float2 pt, float amp, float roughness) {
  float dx = markerOffset(amp, roughness);
  float dy = markerOffset(amp, roughness);
  return pt + (simd_float2){dx, dy};
}

static NSUInteger tessellateSketchArrowhead(simd_float2 endpoint,
                                            simd_float2 tangent,
                                            simd_float2 normal, float size,
                                            float strokeWidth, float roughness,
                                            CanvasVertex *v) {
  float wingSpread = size * 0.5f;
  float halfThick = strokeWidth * 0.5f;
  simd_float2 base = endpoint - tangent * size;
  simd_float2 left = base + normal * wingSpread;
  simd_float2 right = base - normal * wingSpread;

  simd_float2 leftEdge = endpoint - left;
  float leftLen = simd_length(leftEdge);
  simd_float2 leftDir = leftLen > 0.001f ? leftEdge / leftLen : tangent;
  simd_float2 leftPerp = (simd_float2){-leftDir.y, leftDir.x};

  simd_float2 rightEdge = endpoint - right;
  float rightLen = simd_length(rightEdge);
  simd_float2 rightDir = rightLen > 0.001f ? rightEdge / rightLen : tangent;
  simd_float2 rightPerp = (simd_float2){-rightDir.y, rightDir.x};

  float amp = size * 0.035f;
  simd_float2 la = jitterPt(left + leftPerp * halfThick, amp, roughness);
  simd_float2 lb = jitterPt(left - leftPerp * halfThick, amp, roughness);
  simd_float2 lc = jitterPt(endpoint + leftPerp * halfThick, amp, roughness);
  simd_float2 ld = jitterPt(endpoint - leftPerp * halfThick, amp, roughness);
  simd_float2 ra = jitterPt(endpoint + rightPerp * halfThick, amp, roughness);
  simd_float2 rb = jitterPt(endpoint - rightPerp * halfThick, amp, roughness);
  simd_float2 rc = jitterPt(right + rightPerp * halfThick, amp, roughness);
  simd_float2 rd = jitterPt(right - rightPerp * halfThick, amp, roughness);

  NSUInteger vc = 0;
  // Left arm: two triangles
  v[vc++] = markerVert(la);
  v[vc++] = markerVert(lb);
  v[vc++] = markerVert(lc);
  v[vc++] = markerVert(lb);
  v[vc++] = markerVert(ld);
  v[vc++] = markerVert(lc);
  // Right arm: two triangles
  v[vc++] = markerVert(ra);
  v[vc++] = markerVert(rb);
  v[vc++] = markerVert(rc);
  v[vc++] = markerVert(rb);
  v[vc++] = markerVert(rd);
  v[vc++] = markerVert(rc);
  return vc;
}

static NSUInteger tessellateSketchLine(simd_float2 endpoint,
                                       simd_float2 tangent, simd_float2 normal,
                                       float size, float strokeWidth,
                                       float roughness, CanvasVertex *v) {
  float halfSpread = size * 0.5f;
  float halfThick = strokeWidth * 0.5f;
  simd_float2 top = endpoint + normal * halfSpread;
  simd_float2 bottom = endpoint - normal * halfSpread;
  float amp = size * 0.035f;
  NSUInteger vc = 0;
  v[vc++] = markerVert(jitterPt(top + tangent * halfThick, amp, roughness));
  v[vc++] = markerVert(jitterPt(top - tangent * halfThick, amp, roughness));
  v[vc++] = markerVert(jitterPt(bottom + tangent * halfThick, amp, roughness));
  v[vc++] = markerVert(jitterPt(bottom - tangent * halfThick, amp, roughness));
  return vc;
}

NSUInteger KKTessellateSketchMarker(uint8_t markerType, simd_float2 endpoint,
                                    simd_float2 tangent, simd_float2 normal,
                                    float markerSize, float strokeWidth,
                                    float roughness, uint32_t seed,
                                    MTLPrimitiveType *primitiveType,
                                    CanvasVertex *vertices) {
  if (markerType == 0)
    return 0;
  markerSeedRNG(seed ^ 0xA770A770);
  switch (markerType) {
  case 1:
    *primitiveType = MTLPrimitiveTypeTriangleStrip;
    return tessellateSketchArrow(endpoint, tangent, normal, markerSize,
                                 roughness, vertices);
  case 2:
    *primitiveType = MTLPrimitiveTypeTriangleStrip;
    return tessellateSketchCircle(endpoint, tangent, markerSize * 0.5f,
                                  roughness, vertices);
  case 3:
    *primitiveType = MTLPrimitiveTypeTriangleStrip;
    return tessellateSketchSquare(endpoint, tangent, normal, markerSize * 0.5f,
                                  roughness, vertices);
  case 4:
    *primitiveType = MTLPrimitiveTypeTriangle;
    return tessellateSketchArrowhead(endpoint, tangent, normal, markerSize,
                                     strokeWidth, roughness, vertices);
  case 5:
    *primitiveType = MTLPrimitiveTypeTriangleStrip;
    return tessellateSketchLine(endpoint, tangent, normal, markerSize,
                                strokeWidth, roughness, vertices);
  default:
    return 0;
  }
}
