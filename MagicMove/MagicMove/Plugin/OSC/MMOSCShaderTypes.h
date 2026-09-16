/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#include <simd/simd.h>
// One vertex layout serves the border (flat colour) and the handle glyphs
// (capsule signed distance in glyph-local pixels; a point is a zero-length
// pill). Positions are Metal-centred surface pixels.
typedef struct {
  vector_float2 position;
  vector_float2 local;    // glyph-frame offset in pixels, x along the pill
  float shade;            // screen-up offset in pixels for the inner gradient
  float kind;             // 0 = flat colour, 1 = glyph, 2 = border line capsule
  vector_float4 shape;    // halfLength, outerRadius, outlineWidth, unused
  vector_float4 fill;     // premultiplied
  vector_float4 stroke;   // straight alpha, matching the legacy glyph style
} MMOSCVertex;
enum { MMOSCVertexIndexVertices = 0, MMOSCVertexIndexViewportSize = 1 };
