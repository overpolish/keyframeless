/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#include "../OSC/MMOSCShaderTypes.h"
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
} MMOSCRasterizerData;

vertex MMOSCRasterizerData MMOSCVertexShader(uint vertexID [[vertex_id]],
                                             constant MMOSCVertex *vertices [[buffer(MMOSCVertexIndexVertices)]],
                                             constant vector_uint2 *viewportSize [[buffer(MMOSCVertexIndexViewportSize)]]) {
  MMOSCRasterizerData out;
  constant MMOSCVertex &v = vertices[vertexID];
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

// Legacy point glyph: fill, an outline centred on the edge, and a faint
// top-light gradient inset by the outline width. The pill is the same glyph
// stretched along its edge.
fragment float4 MMOSCFragmentShader(MMOSCRasterizerData in [[stage_in]]) {
  if (in.kind < 0.5) return in.fill;
  float halfLength = in.shape.x, radius = in.shape.y, outline = in.shape.z;
  float2 p = in.local;
  float2 nearest = float2(clamp(p.x, -halfLength, halfLength), 0.0);
  float dist = length(p - nearest);
  float shapeAlpha = edgeAlpha(radius - dist);
  if (shapeAlpha < 0.001) discard_fragment();
  if (in.kind < 1.5) {  // border line: solid fill, AA edge only
    return float4(in.fill.rgb * shapeAlpha, in.fill.a * shapeAlpha);
  }
  float outlineFactor = lineAlpha(abs(radius - dist), outline);
  float4 premultStroke = float4(in.stroke.rgb * in.stroke.a, in.stroke.a);
  float4 color = mix(in.fill, premultStroke, outlineFactor);
  color.a = shapeAlpha * mix(in.fill.a, in.stroke.a, outlineFactor);
  float inset = smoothstep(0.0, outline, radius - outline - dist);
  float gradient = (in.shade / radius) * 0.5 + 0.5;
  color.rgb = mix(color.rgb, float3(gradient), inset * 0.12);
  return color;
}
