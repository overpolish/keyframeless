/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "MarkerTessellation.h"
#import <Foundation/Foundation.h>

static inline CanvasVertex markerVert(simd_float2 pos) {
  return (CanvasVertex){pos, 0.0f, 0.0f};
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
  simd_float2 center = endpoint - tangent * radius;
  NSUInteger segments = 24;
  NSUInteger vc = 0;
  for (NSUInteger i = 0; i <= segments; i++) {
    float angle = (float)i / (float)segments * 2.0f * (float)M_PI;
    simd_float2 rim =
        center + (simd_float2){cosf(angle) * radius, sinf(angle) * radius};
    v[vc++] = markerVert(center);
    v[vc++] = markerVert(rim);
  }
  return vc;
}

/// Square marker: far edge at endpoint, center pulled back by halfSide.
/// Triangle strip: a, b, c, d forming a quad.
static NSUInteger tessellateSquare(simd_float2 endpoint, simd_float2 tangent,
                                   simd_float2 normal, float halfSide,
                                   CanvasVertex *v) {
  simd_float2 center = endpoint - tangent * halfSide;
  simd_float2 fwd = tangent * halfSide;
  simd_float2 side = normal * halfSide;

  // Strip order: top-left, bottom-left, top-right, bottom-right.
  NSUInteger vc = 0;
  v[vc++] = markerVert(center - fwd + side);
  v[vc++] = markerVert(center - fwd - side);
  v[vc++] = markerVert(center + fwd + side);
  v[vc++] = markerVert(center + fwd - side);
  return vc;
}

/// Arrowhead marker (open chevron): two thick arms meeting at the tip.
/// Emits two quads with a degenerate bridge between them (10 verts).
static NSUInteger tessellateArrowhead(simd_float2 endpoint, simd_float2 tangent,
                                      simd_float2 normal, float size,
                                      float strokeWidth, CanvasVertex *v) {
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

  NSUInteger vc = 0;
  // Left arm quad
  v[vc++] = markerVert(left + leftPerp * halfThick);
  v[vc++] = markerVert(left - leftPerp * halfThick);
  v[vc++] = markerVert(endpoint + leftPerp * halfThick);
  v[vc++] = markerVert(endpoint - leftPerp * halfThick);
  // Degenerate bridge
  v[vc] = v[vc - 1];
  vc++;
  v[vc++] = markerVert(endpoint + rightPerp * halfThick);
  // Right arm quad
  v[vc++] = markerVert(endpoint + rightPerp * halfThick);
  v[vc++] = markerVert(endpoint - rightPerp * halfThick);
  v[vc++] = markerVert(right + rightPerp * halfThick);
  v[vc++] = markerVert(right - rightPerp * halfThick);
  return vc;
}

/// Line marker: perpendicular bar at the endpoint.
/// Single quad (4 verts).
static NSUInteger tessellateLine(simd_float2 endpoint, simd_float2 tangent,
                                 simd_float2 normal, float size,
                                 float strokeWidth, CanvasVertex *v) {
  float halfSpread = size * 0.5f;
  float halfThick = strokeWidth * 0.5f;
  simd_float2 top = endpoint + normal * halfSpread;
  simd_float2 bottom = endpoint - normal * halfSpread;

  NSUInteger vc = 0;
  v[vc++] = markerVert(top + tangent * halfThick);
  v[vc++] = markerVert(top - tangent * halfThick);
  v[vc++] = markerVert(bottom + tangent * halfThick);
  v[vc++] = markerVert(bottom - tangent * halfThick);
  return vc;
}

float KKMarkerPullback(uint8_t markerType, float markerSize) {
  // Stroke ends slightly inside the marker so it's fully covered by the fill.
  // The fraction is chosen so the stroke never pokes out the sides, even at
  // small marker sizes (arrow narrows toward the tip, so we stay near the
  // base).
  switch (markerType) {
  case 1:
    return markerSize * 0.7f; // arrow: 30% inside from base
  case 2:
    return markerSize * 0.3f; // circle: ~20% past center
  case 3:
    return markerSize * 0.3f; // square: ~20% past center
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
                              CanvasVertex *vertices) {
  if (markerType == 0)
    return 0;

  switch (markerType) {
  case 1: // Arrow
    return tessellateArrow(endpoint, tangent, normal, markerSize, vertices);
  case 2: // Circle
    return tessellateCircle(endpoint, tangent, markerSize * 0.5f, vertices);
  case 3: // Square
    return tessellateSquare(endpoint, tangent, normal, markerSize * 0.5f,
                            vertices);
  case 4: // Arrowhead
    return tessellateArrowhead(endpoint, tangent, normal, markerSize,
                               strokeWidth, vertices);
  case 5: // Line
    return tessellateLine(endpoint, tangent, normal, markerSize, strokeWidth,
                          vertices);
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
  simd_float2 center = endpoint - tangent * radius;
  NSUInteger segments = 24;
  float jitterAmp = radius * 0.07f;
  simd_float2 outline[24];
  for (NSUInteger i = 0; i < segments; i++) {
    float angle = (float)i / (float)segments * 2.0f * (float)M_PI;
    float r = radius + markerOffset(jitterAmp, roughness);
    outline[i] = center + (simd_float2){cosf(angle) * r, sinf(angle) * r};
  }
  return emitFan(outline, segments, v);
}

static NSUInteger tessellateSketchSquare(simd_float2 endpoint,
                                         simd_float2 tangent,
                                         simd_float2 normal, float halfSide,
                                         float roughness, CanvasVertex *v) {
  simd_float2 center = endpoint - tangent * halfSide;
  simd_float2 fwd = tangent * halfSide;
  simd_float2 side = normal * halfSide;
  simd_float2 corners[4] = {center - fwd + side, center + fwd + side,
                            center + fwd - side, center - fwd - side};
  float jitterAmp = halfSide * 0.06f;
  simd_float2 outline[24];
  NSUInteger oc =
      subdivideAndJitter(corners, 4, 6, jitterAmp, roughness, outline);
  return emitFan(outline, oc, v);
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

  float jitterAmp = size * 0.035f;
  NSUInteger vc = 0;

  // Left arm as jittered quad
  simd_float2 lc[4] = {
      left + leftPerp * halfThick, endpoint + leftPerp * halfThick,
      endpoint - leftPerp * halfThick, left - leftPerp * halfThick};
  simd_float2 lo[24];
  NSUInteger loc = subdivideAndJitter(lc, 4, 6, jitterAmp, roughness, lo);
  vc += emitFan(lo, loc, v + vc);

  // Degenerate bridge to right arm
  v[vc] = v[vc - 1];
  vc++;

  simd_float2 rc[4] = {
      endpoint + rightPerp * halfThick, right + rightPerp * halfThick,
      right - rightPerp * halfThick, endpoint - rightPerp * halfThick};
  simd_float2 ro[24];
  NSUInteger roc = subdivideAndJitter(rc, 4, 6, jitterAmp, roughness, ro);
  simd_float2 rCenter = {0, 0};
  for (NSUInteger i = 0; i < roc; i++)
    rCenter += ro[i];
  rCenter /= (float)roc;
  v[vc++] = markerVert(rCenter);

  vc += emitFan(ro, roc, v + vc);
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
  simd_float2 corners[4] = {
      top + tangent * halfThick, top - tangent * halfThick,
      bottom - tangent * halfThick, bottom + tangent * halfThick};
  float jitterAmp = size * 0.035f;
  simd_float2 outline[24];
  NSUInteger oc =
      subdivideAndJitter(corners, 4, 6, jitterAmp, roughness, outline);
  return emitFan(outline, oc, v);
}

NSUInteger KKTessellateSketchMarker(uint8_t markerType, simd_float2 endpoint,
                                    simd_float2 tangent, simd_float2 normal,
                                    float markerSize, float strokeWidth,
                                    float roughness, uint32_t seed,
                                    CanvasVertex *vertices) {
  if (markerType == 0)
    return 0;
  markerSeedRNG(seed ^ 0xA770A770);
  switch (markerType) {
  case 1:
    return tessellateSketchArrow(endpoint, tangent, normal, markerSize,
                                 roughness, vertices);
  case 2:
    return tessellateSketchCircle(endpoint, tangent, markerSize * 0.5f,
                                  roughness, vertices);
  case 3:
    return tessellateSketchSquare(endpoint, tangent, normal, markerSize * 0.5f,
                                  roughness, vertices);
  case 4:
    return tessellateSketchArrowhead(endpoint, tangent, normal, markerSize,
                                     strokeWidth, roughness, vertices);
  case 5:
    return tessellateSketchLine(endpoint, tangent, normal, markerSize,
                                strokeWidth, roughness, vertices);
  default:
    return 0;
  }
}
