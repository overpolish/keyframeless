/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#include <simd/simd.h>
// One vertex layout serves the border (flat colour), the handle glyphs
// (capsule signed distance in glyph-local pixels; a point is a zero-length
// pill) and the anchor square (rounded-rect signed distance in the same frame).
// Positions are Metal-centred surface pixels.
typedef struct {
  vector_float2 position;
  vector_float2 local;    // glyph-frame offset in pixels, x along the pill
  float shade;            // screen-up offset in pixels for the inner gradient,
                          // or the square's downward shadow offset
  float kind;             // 0 = flat colour, 1 = glyph, 2 = border line capsule, 3 = anchor square
  vector_float4 shape;    // pill: halfLength, outerRadius, outlineWidth, unused
                          // square: halfExtent, cornerRadius, outlineWidth, shadowRadius
  vector_float4 fill;     // premultiplied
  vector_float4 stroke;   // straight alpha, matching the legacy glyph style
} MMOSCVertex;
enum { MMOSCVertexIndexVertices = 0, MMOSCVertexIndexViewportSize = 1 };

// Rotation gizmo: three great circles sampled as polylines in the fragment
// shader. Distances are canvas pixels in the quad's own frame, which the
// vertex `local` carries with Y up, matching OSCRotationGeometry's screen
// frame: ring point = radius * (cos t * ringU + sin t * ringV), and its z is
// the depth that dims the hemisphere facing away.
typedef struct {
  vector_float3 ringU[3];
  vector_float3 ringV[3];
  vector_float4 ringColor[3];
  vector_float4 outlineColor;
  float radius;
  float ringHalfWidth;
  float outlineWidth;
  float backDim;     // alpha multiplier for the far hemisphere
  float activeBoost; // mix toward white for the grabbed or hovered ring
  int activeRing;    // -1 for none
} MMOSCRingParams;
enum { MMOSCFragmentIndexRingParams = 0 };
