/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
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
                               texture2d<half> colorTexture [[texture(KKTextureIndex_InputImage)]],
                               constant float2 *imageSize [[buffer(FragmentIndex_ImageSize)]],
                               constant float2 *tileOffset [[buffer(FragmentIndex_TileOffset)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

    float glowRadius = 20.0;
    float glowIntensity = 1.5;

    float2 texelSize = 1.0 / float2(colorTexture.get_width(), colorTexture.get_height());

    float alphaSum = 0.0;
    float weightSum = 0.0;
    int samples = int(ceil(glowRadius));

    for (int y = -samples; y <= samples; y++) {
        for (int x = -samples; x <= samples; x++) {
            float dist = length(float2(x, y));
            if (dist > glowRadius)
                continue;

            float weight = exp(-0.5 * (dist * dist) / (glowRadius * glowRadius * 0.16));
            float2 offset = float2(x, y) * texelSize;
            half4 s = colorTexture.sample(textureSampler, in.textureCoordinate + offset);
            alphaSum += float(s.a) * weight;
            weightSum += weight;
        }
    }

    float glowAlpha = saturate((alphaSum / weightSum) * glowIntensity);

    half4 original = colorTexture.sample(textureSampler, in.textureCoordinate);
    float3 glowColor = float3(1.0, 1.0, 1.0);

    float3 result = glowColor * glowAlpha * (1.0 - float(original.a)) + float3(original.rgb);
    float resultAlpha = glowAlpha * (1.0 - float(original.a)) + float(original.a);

    return float4(result, resultAlpha);
}
