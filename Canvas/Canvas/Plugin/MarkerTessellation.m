/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "MarkerTessellation.h"
#import <Foundation/Foundation.h>

static inline CanvasVertex markerVert(simd_float2 pos) {
  return (CanvasVertex){pos, 0.0f, 0.0f};
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
  default:
    return 0;
  }
}
