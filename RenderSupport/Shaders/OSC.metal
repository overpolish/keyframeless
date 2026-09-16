/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
// On-screen control shaders: box outline, handle glyphs, anchor square and the
// rotation gizmo. Each plugin compiles this source into its own default Metal
// library through a small include file, like RenderSupport.metal.
#include "../Sources/RenderSupport/include/RSOSCShaderTypes.h"
#include <metal_stdlib>
using namespace metal;

typedef struct {
  float4 position [[position]];
  float2 local;
  float shade;
  float kind;
  float4 shape;
  float4 fill;
  float4 stroke;
} RSOSCRasterizerData;

vertex RSOSCRasterizerData RSOSCVertexShader(uint vertexID [[vertex_id]],
                                             constant RSOSCVertex *vertices [[buffer(RSOSCVertexIndexVertices)]],
                                             constant vector_uint2 *viewportSize [[buffer(RSOSCVertexIndexViewportSize)]]) {
  RSOSCRasterizerData out;
  constant RSOSCVertex &v = vertices[vertexID];
  float2 viewport = float2(*viewportSize);
  out.position = float4(v.position / (viewport / 2.0), 0.0, 1.0);
  out.local = v.local;
  out.shade = v.shade;
  out.kind = v.kind;
  out.shape = v.shape;
  out.fill = v.fill;
  out.stroke = v.stroke;
  return out;
}

static inline float edgeAlpha(float signedDist) {
  float delta = fwidth(signedDist);
  return smoothstep(-delta * 0.5, delta * 0.5, signedDist);
}
static inline float lineAlpha(float distToLine, float halfWidth) {
  float aa = fwidth(distToLine);
  return smoothstep(halfWidth + aa, halfWidth - aa, distToLine);
}
static inline float roundedRectDistance(float2 p, float halfExtent, float cornerRadius) {
  float2 d = abs(p) - halfExtent + cornerRadius;
  return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - cornerRadius;
}

// The anchor square: a rounded square whose outline is inset from the edge,
// over a drop shadow below it, so the pivot handle reads against both the image
// and the controls underneath. `local` runs screen-up, so the shadow's shape is
// the square translated the other way. Its colour is the style's, not geometry.
static inline float4 squareColor(RSOSCRasterizerData in) {
  float halfExtent = in.shape.x, cornerRadius = in.shape.y;
  float outline = in.shape.z, shadowRadius = in.shape.w;
  const float4 shadowColor = float4(0.0, 0.0, 0.0, 0.5);
  float shadowDistance = roundedRectDistance(in.local + float2(0.0, in.shade), halfExtent, cornerRadius);
  float shadowAlpha = shadowColor.a * (1.0 - smoothstep(-shadowRadius, 0.0, shadowDistance));
  float distance = roundedRectDistance(in.local, halfExtent, cornerRadius);
  float shapeAlpha = edgeAlpha(-distance);
  if (shapeAlpha < 0.001 && shadowAlpha < 0.001) discard_fragment();
  float4 color = float4(shadowColor.rgb * shadowAlpha, shadowAlpha);
  if (shapeAlpha < 0.001) return color;
  float outlineFactor = 1.0 - edgeAlpha(-(distance + outline));
  float4 premultStroke = float4(in.stroke.rgb * in.stroke.a, in.stroke.a);
  float4 shape = mix(in.fill, premultStroke, outlineFactor);
  shape.a = shapeAlpha * mix(in.fill.a, in.stroke.a, outlineFactor);
  return color * (1.0 - shape.a) + shape;
}

// Legacy point glyph: fill, an outline centred on the edge, and a faint
// top-light gradient inset by the outline width. The pill is the same glyph
// stretched along its edge.
fragment float4 RSOSCFragmentShader(RSOSCRasterizerData in [[stage_in]]) {
  if (in.kind == RSOSCVertexKindSquare) return squareColor(in);
  float halfLength = in.shape.x, radius = in.shape.y, outline = in.shape.z;
  float2 p = in.local;
  float2 nearest = float2(clamp(p.x, -halfLength, halfLength), 0.0);
  float dist = length(p - nearest);
  float shapeAlpha = edgeAlpha(radius - dist);
  if (shapeAlpha < 0.001) discard_fragment();
  // A border line is a solid capsule: fill only, anti-aliased at its edge.
  if (in.kind == RSOSCVertexKindLine) {
    return float4(in.fill.rgb * shapeAlpha, in.fill.a * shapeAlpha);
  }
  // A handle glyph adds an outline ring and a faint top-light gradient.
  float outlineFactor = lineAlpha(abs(radius - dist), outline);
  float4 premultStroke = float4(in.stroke.rgb * in.stroke.a, in.stroke.a);
  float4 color = mix(in.fill, premultStroke, outlineFactor);
  color.a = shapeAlpha * mix(in.fill.a, in.stroke.a, outlineFactor);
  float inset = smoothstep(0.0, outline, radius - outline - dist);
  float gradient = (in.shade / radius) * 0.5 + 0.5;
  color.rgb = mix(color.rgb, float3(gradient), inset * 0.12);
  return color;
}

// One pixel of the rotation gizmo: sample each visible great circle as a
// polyline, then pick what the user can actually grab. The front hemisphere
// wins wherever it passes within the ring, so the bright half is always the
// half the hit test accepts; otherwise the closest far-side ring draws dimmed.
fragment float4 RSOSCRingFragment(RSOSCRasterizerData in [[stage_in]],
                                  constant RSOSCRingParams &params [[buffer(RSOSCFragmentIndexRingParams)]]) {
  const int samples = 64;
  float2 point = in.local;
  float frontDistance = 1e9, backDistance = 1e9, backZ = 0;
  int frontRing = -1, backRing = -1;
  for (int k = 0; k < RSOSCRingCount; ++k) {
    float3 previous = params.radius * params.ringU[k];
    for (int i = 1; i <= samples; ++i) {
      float t = 2.0 * M_PI_F * float(i) / float(samples);
      float3 current = params.radius * (cos(t) * params.ringU[k] + sin(t) * params.ringV[k]);
      float2 edge = current.xy - previous.xy;
      float along = clamp(dot(point - previous.xy, edge) / max(dot(edge, edge), 1e-9), 0.0, 1.0);
      float distance = length(point - (previous.xy + along * edge));
      float z = mix(previous.z, current.z, along);
      if (z >= 0.0) {
        if (distance < frontDistance) { frontDistance = distance; frontRing = k; }
      } else if (distance < backDistance) {
        backDistance = distance; backRing = k; backZ = z;
      }
      previous = current;
    }
  }
  float outerHalfWidth = params.ringHalfWidth + params.outlineWidth;
  int ring = -1;
  float distance = 0, depth = 0;
  if (frontRing >= 0 && frontDistance <= outerHalfWidth + 0.5) {
    ring = frontRing;
    distance = frontDistance;
  } else if (backRing >= 0 && backDistance <= outerHalfWidth + 0.5) {
    ring = backRing;
    distance = backDistance;
    depth = backZ;
  } else {
    discard_fragment();
  }
  float shapeAlpha = edgeAlpha(outerHalfWidth - distance);
  float outlineFactor = 1.0 - edgeAlpha(params.ringHalfWidth - distance);
  float4 fill = params.ringColor[ring];
  if (ring == params.activeRing) fill.rgb = mix(fill.rgb, float3(1.0), params.activeBoost);
  float4 stroke = params.outlineColor;
  float4 premultStroke = float4(stroke.rgb * stroke.a, stroke.a);
  float4 color = mix(fill, premultStroke, outlineFactor);
  color.a = shapeAlpha * mix(fill.a, stroke.a, outlineFactor);
  if (depth < 0.0) color *= params.backDim;
  return color;
}
