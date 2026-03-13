/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "ShaderTypes.h"
#include <KeyframelessKit/KKShaderTypes.h>
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

vertex KKRasterizerData vertexShader(uint vertexID [[vertex_id]],
                                     constant KKVertex2D *vertexArray [[buffer(KKVertexInputIndex_Vertices)]],
                                     constant vector_uint2 *viewportSizePointer
                                     [[buffer(KKVertexInputIndex_ViewportSize)]]) {
    KKRasterizerData out;

    float2 pixelSpacePosition = vertexArray[vertexID].position.xy;
    float2 viewportSize = float2(*viewportSizePointer);

    out.clipSpacePosition.xy = pixelSpacePosition / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;

    return out;
}

// Passthrough — returns the source frame unchanged.
fragment float4 fragmentShader(KKRasterizerData in [[stage_in]], texture2d<half> frame [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    return float4(frame.sample(s, in.textureCoordinate));
}
