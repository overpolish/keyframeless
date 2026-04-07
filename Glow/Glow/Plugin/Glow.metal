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

fragment float4 blurHorizontal(RasterizerData in [[stage_in]],
                               texture2d<half> colorTexture [[texture(KKTextureIndex_InputImage)]],
                               constant float *radius [[buffer(FragmentIndex_Radius)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    constexpr int kSamples = 32;

    float glowRadius = *radius;
    if (glowRadius < 0.01)
        return float4(0, 0, 0, colorTexture.sample(textureSampler, in.textureCoordinate).a);

    float texelX = 1.0 / float(colorTexture.get_width());
    float step = glowRadius / float(kSamples);
    float sigma = glowRadius * 0.4;
    float invTwoSigmaSq = -0.5 / (sigma * sigma);

    half4 center = colorTexture.sample(textureSampler, in.textureCoordinate);
    float alphaSum = float(center.a);
    float weightSum = 1.0;

    for (int i = 1; i <= kSamples; i++) {
        float d = float(i) * step;
        float weight = exp(d * d * invTwoSigmaSq);
        float offsetX = d * texelX;
        half4 s0 = colorTexture.sample(textureSampler, in.textureCoordinate + float2(offsetX, 0));
        half4 s1 = colorTexture.sample(textureSampler, in.textureCoordinate + float2(-offsetX, 0));
        alphaSum += (float(s0.a) + float(s1.a)) * weight;
        weightSum += weight * 2.0;
    }

    return float4(0, 0, 0, alphaSum / weightSum);
}

fragment float4 blurVerticalComposite(RasterizerData in [[stage_in]],
                                      texture2d<half> colorTexture [[texture(KKTextureIndex_InputImage)]],
                                      texture2d<half> blurredTexture [[texture(1)]],
                                      constant float *radius [[buffer(FragmentIndex_Radius)]],
                                      constant float *intensity [[buffer(FragmentIndex_Intensity)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    constexpr int kSamples = 32;

    half4 original = colorTexture.sample(textureSampler, in.textureCoordinate);
    float glowRadius = *radius;
    float glowIntensity = *intensity;

    if (glowRadius < 0.01)
        return float4(original);

    float texelY = 1.0 / float(blurredTexture.get_height());
    float step = glowRadius / float(kSamples);
    float sigma = glowRadius * 0.4;
    float invTwoSigmaSq = -0.5 / (sigma * sigma);

    half4 center = blurredTexture.sample(textureSampler, in.textureCoordinate);
    float alphaSum = float(center.a);
    float weightSum = 1.0;

    for (int i = 1; i <= kSamples; i++) {
        float d = float(i) * step;
        float weight = exp(d * d * invTwoSigmaSq);
        float offsetY = d * texelY;
        half4 s0 = blurredTexture.sample(textureSampler, in.textureCoordinate + float2(0, offsetY));
        half4 s1 = blurredTexture.sample(textureSampler, in.textureCoordinate + float2(0, -offsetY));
        alphaSum += (float(s0.a) + float(s1.a)) * weight;
        weightSum += weight * 2.0;
    }

    float glowAlpha = saturate((alphaSum / weightSum) * glowIntensity);

    float3 glowColor = float3(1.0, 1.0, 1.0);
    float3 result = glowColor * glowAlpha * (1.0 - float(original.a)) + float3(original.rgb);
    float resultAlpha = glowAlpha * (1.0 - float(original.a)) + float(original.a);

    return float4(result, resultAlpha);
}
