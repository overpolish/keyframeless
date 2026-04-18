/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "ShaderTypes.h"
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

typedef struct {
    float4 clipSpacePosition [[position]];
    float edgeDistance;
    float capDistance;
} StrokeRasterizerData;

vertex StrokeRasterizerData strokeVertexShader(uint vertexID [[vertex_id]],
                                               constant CanvasVertex *vertexArray [[buffer(0)]],
                                               constant vector_uint2 *viewportSizePointer [[buffer(1)]]) {
    StrokeRasterizerData out;

    float2 pixelSpacePosition = vertexArray[vertexID].position;
    float2 viewportSize = float2(*viewportSizePointer);

    out.clipSpacePosition.xy = pixelSpacePosition / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    out.edgeDistance = vertexArray[vertexID].edgeDistance;
    out.capDistance = vertexArray[vertexID].capDistance;

    return out;
}

fragment float4 strokeFragmentShader(StrokeRasterizerData in [[stage_in]], constant float4 *strokeColor [[buffer(0)]]) {
    float edgeDist = abs(in.edgeDistance);
    float edgeFw = fwidth(in.edgeDistance) * 1.5;
    float edgeAlpha = 1.0 - smoothstep(1.0 - edgeFw, 1.0, edgeDist);

    float capFw = fwidth(in.capDistance) * 1.5;
    float capAlpha = 1.0 - smoothstep(1.0 - capFw, 1.0, in.capDistance);

    return *strokeColor * edgeAlpha * capAlpha;
}

typedef struct {
    float4 clipSpacePosition [[position]];
} FillRasterizerData;

vertex FillRasterizerData fillVertexShader(uint vertexID [[vertex_id]],
                                           constant CanvasFillVertex *vertexArray [[buffer(0)]],
                                           constant vector_uint2 *viewportSizePointer [[buffer(1)]]) {
    FillRasterizerData out;
    float2 viewportSize = float2(*viewportSizePointer);
    out.clipSpacePosition.xy = vertexArray[vertexID].position / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    return out;
}

fragment float4 fillFragmentShader(FillRasterizerData in [[stage_in]], constant float4 *fillColor [[buffer(0)]]) {
    return *fillColor;
}

// Composite shader: draws a fullscreen quad sampling an intermediate texture,
// multiplied by an opacity value.  Used so that per-object opacity is applied
// once to the flattened fill+stroke instead of per-primitive.

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 texCoord;
} CompositeRasterizerData;

vertex CompositeRasterizerData compositeVertexShader(uint vertexID [[vertex_id]]) {
    // Fullscreen triangle strip: 4 vertices → 2 triangles via triangle_strip
    float2 positions[4] = {{-1, -1}, {1, -1}, {-1, 1}, {1, 1}};
    float2 texCoords[4] = {{0, 1}, {1, 1}, {0, 0}, {1, 0}};

    CompositeRasterizerData out;
    out.clipSpacePosition = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 compositeFragmentShader(CompositeRasterizerData in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                        constant float *opacity [[buffer(0)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);
    float4 color = tex.sample(s, in.texCoord);
    return color * *opacity;
}

// Image shader: draws a positioned quad sampling an image texture with opacity.

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 texCoord;
} ImageRasterizerData;

vertex ImageRasterizerData imageVertexShader(uint vertexID [[vertex_id]],
                                             constant CanvasFillVertex *vertexArray [[buffer(0)]],
                                             constant vector_uint2 *viewportSizePointer [[buffer(1)]]) {
    // Triangle strip: 4 vertices (BL, BR, TL, TR)
    // Image data is top-down, so BL maps to bottom of texture (v=1),
    // TL maps to top of texture (v=0).
    float2 texCoords[4] = {{0, 0}, {1, 0}, {0, 1}, {1, 1}};

    ImageRasterizerData out;
    float2 viewportSize = float2(*viewportSizePointer);
    out.clipSpacePosition.xy = vertexArray[vertexID].position / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 imageFragmentShader(ImageRasterizerData in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                    constant float *opacity [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float4 color = tex.sample(s, in.texCoord);
    return float4(color.rgb * color.a, color.a) * *opacity;
}
