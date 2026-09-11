/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#include "ShaderTypes.h"
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

fragment float4 fragmentShader(RasterizerData in [[stage_in]],
                               constant MMTransform &transform [[buffer(0)]],
                               texture2d<half> colorTexture [[texture(KKTextureIndex_InputImage)]]) {
    if (transform.scale <= 0) return float4(0);
    float2 p = in.textureCoordinate - 0.5 - transform.offset;
    p.x *= transform.aspect;
    float c = cos(transform.rotation), s = sin(transform.rotation);
    p = float2(c*p.x + s*p.y, -s*p.x + c*p.y) / transform.scale;
    p.x /= transform.aspect;
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear,
                                     address::clamp_to_zero);
    return float4(colorTexture.sample(textureSampler, p + 0.5));
}
