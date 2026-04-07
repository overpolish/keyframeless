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
                               constant float *radius [[buffer(FragmentIndex_Radius)]],
                               constant int *colorMode [[buffer(FragmentIndex_ColorMode)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    constexpr int kSamples = 32;

    float glowRadius = *radius;
    bool dynamic = (*colorMode == 1);

    if (glowRadius < 0.01) {
        half4 c = colorTexture.sample(textureSampler, in.textureCoordinate);
        return dynamic ? float4(c) : float4(0, 0, 0, float(c.a));
    }

    float texelX = 1.0 / float(colorTexture.get_width());
    float step = glowRadius / float(kSamples);
    float sigma = glowRadius * 0.5;
    float invTwoSigmaSq = -0.5 / (sigma * sigma);

    half4 center = colorTexture.sample(textureSampler, in.textureCoordinate);
    float4 colorSum = dynamic ? float4(center) : float4(0, 0, 0, float(center.a));
    float weightSum = 1.0;

    for (int i = 1; i <= kSamples; i++) {
        float d = float(i) * step;
        float weight = exp(d * d * invTwoSigmaSq);
        float offsetX = d * texelX;
        half4 s0 = colorTexture.sample(textureSampler, in.textureCoordinate + float2(offsetX, 0));
        half4 s1 = colorTexture.sample(textureSampler, in.textureCoordinate + float2(-offsetX, 0));
        if (dynamic) {
            colorSum += (float4(s0) + float4(s1)) * weight;
        } else {
            colorSum.a += (float(s0.a) + float(s1.a)) * weight;
        }
        weightSum += weight * 2.0;
    }

    return colorSum / weightSum;
}

fragment float4 blurVerticalComposite(RasterizerData in [[stage_in]],
                                      texture2d<half> colorTexture [[texture(KKTextureIndex_InputImage)]],
                                      texture2d<half> blurredTexture [[texture(1)]],
                                      constant float *radius [[buffer(FragmentIndex_Radius)]],
                                      constant float *intensity [[buffer(FragmentIndex_Intensity)]],
                                      constant float *falloff [[buffer(FragmentIndex_Falloff)]],
                                      constant float2 *offsetPtr [[buffer(FragmentIndex_Offset)]],
                                      constant float3 *glowColorPtr [[buffer(FragmentIndex_GlowColor)]],
                                      constant int *colorMode [[buffer(FragmentIndex_ColorMode)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    constexpr int kSamples = 32;

    half4 original = colorTexture.sample(textureSampler, in.textureCoordinate);
    float glowRadius = *radius;
    float glowIntensity = *intensity;
    float glowFalloff = *falloff;
    float2 glowOffset = *offsetPtr;
    bool dynamic = (*colorMode == 1);

    if (glowRadius < 0.01)
        return float4(original);

    float2 offsetUV = in.textureCoordinate + glowOffset;

    float texelY = 1.0 / float(blurredTexture.get_height());
    float step = glowRadius / float(kSamples);
    float sigma = glowRadius * 0.5;
    float invTwoSigmaSq = -0.5 / (sigma * sigma);

    half4 center = blurredTexture.sample(textureSampler, offsetUV);
    float4 colorSum = float4(center);
    float weightSum = 1.0;

    for (int i = 1; i <= kSamples; i++) {
        float d = float(i) * step;
        float weight = exp(d * d * invTwoSigmaSq);
        float offsetY = d * texelY;
        half4 s0 = blurredTexture.sample(textureSampler, offsetUV + float2(0, offsetY));
        half4 s1 = blurredTexture.sample(textureSampler, offsetUV + float2(0, -offsetY));
        colorSum += (float4(s0) + float4(s1)) * weight;
        weightSum += weight * 2.0;
    }

    float4 blurred = colorSum / weightSum;
    float glowAlpha = saturate(pow(blurred.a, glowFalloff) * glowIntensity);

    float3 glowColor;
    if (dynamic) {
        glowColor = blurred.a > 0.001 ? blurred.rgb / blurred.a : float3(0);
    } else {
        glowColor = *glowColorPtr;
    }

    float3 result = glowColor * glowAlpha * (1.0 - float(original.a)) + float3(original.rgb);
    float resultAlpha = glowAlpha * (1.0 - float(original.a)) + float(original.a);

    return float4(result, resultAlpha);
}
