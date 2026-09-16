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

// One pixel of the rotation gizmo: sample each visible great circle as a
// polyline, then pick what the user can actually grab. The front hemisphere
// wins wherever it passes within the ring, so the bright half is always the
// half the hit test accepts; otherwise the closest far-side ring draws dimmed.
fragment float4 MMOSCRingFragment(MMOSCRasterizerData in [[stage_in]],
                                  constant MMOSCRingParams &params [[buffer(MMOSCFragmentIndexRingParams)]]) {
  const int samples = 64;
  float2 point = in.local;
  float frontDistance = 1e9, backDistance = 1e9, backZ = 0;
  int frontRing = -1, backRing = -1;
  for (int k = 0; k < 3; ++k) {
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
