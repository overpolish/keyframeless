/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The plugin is Custom-only (runtime-compiled GLSL); this file only holds the
// vertex + downscale-blit functions. The shared per-Type Metal helpers
// (ShaderCommon.h) and the 12 built-in Type fragments live on disk as reference
// but are no longer compiled, so RasterizerData is declared inline here.
#include <KeyframelessKit/KKShaderTypes.h>
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} RasterizerData;

vertex RasterizerData vertexShader(uint vertexID [[vertex_id]],
                                   constant KKVertex2D *vertexArray [[buffer(KKVertexInputIndex_Vertices)]],
                                   constant vector_uint2 *viewportSizePointer
                                   [[buffer(KKVertexInputIndex_ViewportSize)]]) {
    RasterizerData out;

    float2 pixelSpacePosition = vertexArray[vertexID].position.xy;
    float2 viewportSize = float2(*viewportSizePointer);

    out.clipSpacePosition.xy = pixelSpacePosition / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;

    return out;
}

// Passthrough used to downscale a reference-resolution intermediate into the
// small mini-viewer texture, so the mini shows a proper minified copy of a
// full-res render (grain, dither, everything) instead of fighting resolution in
// each shader. Matches the mini's 4-vertex triangle-strip quad order.
struct ShaderBlitData {
    float4 position [[position]];
    float2 uv;
};

vertex ShaderBlitData meshBlitVertex(uint vertexID [[vertex_id]]) {
    float2 corners[4] = {float2(-1.0, -1.0), float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)};
    float2 p = corners[vertexID];
    ShaderBlitData out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return out;
}

fragment float4 meshBlitFragment(ShaderBlitData in [[stage_in]], texture2d<float> src [[texture(0)]],
                                 sampler samp [[sampler(0)]]) {
    return src.sample(samp, in.uv);
}

// The 12 built-in per-Type fragment shaders were retired with the Type system;
// the plugin is Custom-only (runtime-compiled GLSL). They were ported to GLSL as
// community shader templates and their MSL sources removed.
