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
    bool dynamic = (*colorMode == 2);

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

fragment float4 blurVertical(RasterizerData in [[stage_in]],
                             texture2d<half> hBlurTexture [[texture(KKTextureIndex_InputImage)]],
                             constant float *radius [[buffer(FragmentIndex_Radius)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    constexpr int kSamples = 32;

    float glowRadius = *radius;
    if (glowRadius < 0.01)
        return float4(hBlurTexture.sample(textureSampler, in.textureCoordinate));

    float texelY = 1.0 / float(hBlurTexture.get_height());
    float step = glowRadius / float(kSamples);
    float sigma = glowRadius * 0.5;
    float invTwoSigmaSq = -0.5 / (sigma * sigma);

    half4 center = hBlurTexture.sample(textureSampler, in.textureCoordinate);
    float4 colorSum = float4(center);
    float weightSum = 1.0;

    for (int i = 1; i <= kSamples; i++) {
        float d = float(i) * step;
        float weight = exp(d * d * invTwoSigmaSq);
        float offsetY = d * texelY;
        half4 s0 = hBlurTexture.sample(textureSampler, in.textureCoordinate + float2(0, offsetY));
        half4 s1 = hBlurTexture.sample(textureSampler, in.textureCoordinate + float2(0, -offsetY));
        colorSum += (float4(s0) + float4(s1)) * weight;
        weightSum += weight * 2.0;
    }

    return colorSum / weightSum;
}

fragment float4 composite(RasterizerData in [[stage_in]],
                          texture2d<half> colorTexture [[texture(KKTextureIndex_InputImage)]],
                          texture2d<half> fullBlurTexture [[texture(1)]],
                          constant float *radius [[buffer(FragmentIndex_Radius)]],
                          constant float *intensity [[buffer(FragmentIndex_Intensity)]],
                          constant float *falloff [[buffer(FragmentIndex_Falloff)]],
                          constant float2 *offsetPtr [[buffer(FragmentIndex_Offset)]],
                          constant float3 *glowColorPtr [[buffer(FragmentIndex_GlowColor)]],
                          constant int *colorMode [[buffer(FragmentIndex_ColorMode)]],
                          constant float3 *gradientLUT [[buffer(FragmentIndex_GradientLUT)]],
                          constant int *gradientType [[buffer(FragmentIndex_GradientType)]],
                          constant float *gradientAngle [[buffer(FragmentIndex_GradientAngle)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

    half4 original = colorTexture.sample(textureSampler, in.textureCoordinate);
    float glowRadius = *radius;
    float glowIntensity = *intensity;
    float glowFalloff = *falloff;
    float2 glowOffset = *offsetPtr;
    int mode = *colorMode;

    if (glowRadius < 0.01)
        return float4(original);

    float2 offsetUV = in.textureCoordinate + glowOffset;

    float4 blurred = float4(fullBlurTexture.sample(textureSampler, offsetUV));

    // Distance from source: 0 at object edge, 1 at glow boundary
    float t = 1.0 - blurred.a;

    // Opacity: smooth fade from full at source to zero at edge.
    float fade = 1.0 - smoothstep(0.0, 1.0 / glowFalloff, t);
    float glowAlpha = saturate(fade * glowIntensity);

    // Color
    float3 glowColor;
    if (mode == 2) {
        glowColor = blurred.a > 0.001 ? blurred.rgb / blurred.a : float3(0);
    } else if (mode == 1) {
        float gradT;
        if (*gradientType == 1) {
            float angle = -*gradientAngle;
            float2 dir = float2(cos(angle), -sin(angle));
            float2 texel = float2(1.0 / float(fullBlurTexture.get_width()), 1.0 / float(fullBlurTexture.get_height()));

            float sumFwd = 0, sumBwd = 0;
            float pd = 0;
            float stepPx = max(glowRadius * 0.3, 2.0);
            for (int pi = 0; pi < 64; pi++) {
                pd += stepPx;
                stepPx *= 1.08;
                float2 off = dir * pd * texel;
                sumFwd += float(fullBlurTexture.sample(textureSampler, offsetUV + off).a);
                sumBwd += float(fullBlurTexture.sample(textureSampler, offsetUV - off).a);
            }
            float total = sumFwd + sumBwd;
            gradT = (total > 0.01) ? saturate(sumBwd / total) : 0.5;
        } else {
            gradT = saturate(t * 2.0 - 1.0);
        }
        float lutPos = gradT * float(KK_GRADIENT_LUT_SIZE - 1);
        int idx0 = int(floor(lutPos));
        int idx1 = min(idx0 + 1, KK_GRADIENT_LUT_SIZE - 1);
        float3 srgb = mix(gradientLUT[idx0], gradientLUT[idx1], lutPos - float(idx0));
        glowColor = pow(srgb, 2.2);
    } else {
        glowColor = pow(*glowColorPtr, 2.2);
    }

    // Composite glow behind original
    float behindAlpha = glowAlpha * (1.0 - float(original.a));
    float3 result = glowColor * behindAlpha + float3(original.rgb);
    float resultAlpha = behindAlpha + float(original.a);

    return float4(result, resultAlpha);
}
