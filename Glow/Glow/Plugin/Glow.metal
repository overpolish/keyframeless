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

// Prep: extract alpha-only (solid/gradient) or premultiplied RGBA (dynamic)
// from the source image. Output is what MPS will blur.
fragment float4 glowPrep(RasterizerData in [[stage_in]], texture2d<half> source [[texture(KKTextureIndex_InputImage)]],
                         constant int *colorMode [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    half4 c = source.sample(s, in.textureCoordinate);
    if (*colorMode == 2)
        return float4(c);
    return float4(0, 0, 0, float(c.a));
}

// Composite: layer the blurred glow behind the original source.
fragment float4 glowComposite(RasterizerData in [[stage_in]],
                              texture2d<half> source [[texture(KKTextureIndex_InputImage)]],
                              texture2d<half> blurred [[texture(1)]],
                              constant float *radius [[buffer(FragmentIndex_Radius)]],
                              constant float *intensity [[buffer(FragmentIndex_Intensity)]],
                              constant float *falloff [[buffer(FragmentIndex_Falloff)]],
                              constant float2 *offsetPtr [[buffer(FragmentIndex_Offset)]],
                              constant float3 *glowColorPtr [[buffer(FragmentIndex_GlowColor)]],
                              constant int *colorMode [[buffer(FragmentIndex_ColorMode)]],
                              constant float3 *gradientLUT [[buffer(FragmentIndex_GradientLUT)]],
                              constant int *gradientType [[buffer(FragmentIndex_GradientType)]],
                              constant float *gradientAngle [[buffer(FragmentIndex_GradientAngle)]]) {

    constexpr sampler s(mag_filter::linear, min_filter::linear);

    half4 original = source.sample(s, in.textureCoordinate);
    float glowRadius = *radius;
    float glowIntensity = *intensity;
    float glowFalloff = *falloff;
    int mode = *colorMode;

    if (glowRadius < 0.01)
        return float4(original);

    float2 offsetUV = in.textureCoordinate + *offsetPtr;
    float4 blur = float4(blurred.sample(s, offsetUV));

    // Normalize alpha by peak so glow profile is consistent at any radius.
    // With per-object rendering the object is always within the tile,
    // so the peak is at or near (0.5, 0.5) in the blurred texture.
    float peakAlpha = float(blurred.sample(s, float2(0.5, 0.5)).a);
    peakAlpha = max(peakAlpha, 0.001);
    float normAlpha = min(blur.a / peakAlpha, 1.0);
    float t = 1.0 - normAlpha;

    // Opacity
    float fade = 1.0 - smoothstep(0.0, 1.0 / glowFalloff, t);
    float glowAlpha = saturate(fade * glowIntensity);

    // Color
    float3 glowColor;
    if (mode == 2) {
        // Dynamic: unpremultiply the blurred source color
        glowColor = blur.a > 0.001 ? blur.rgb / blur.a : float3(0);
    } else if (mode == 1) {
        // Gradient
        float gradT;
        if (*gradientType == 1) {
            // Linear: scan blurred alpha along the angle direction
            float angle = -*gradientAngle;
            float2 dir = float2(cos(angle), -sin(angle));
            float2 texel = float2(1.0 / float(blurred.get_width()), 1.0 / float(blurred.get_height()));
            float sumFwd = 0, sumBwd = 0, pd = 0;
            float stepPx = max(glowRadius * 0.3, 2.0);
            for (int pi = 0; pi < 64; pi++) {
                pd += stepPx;
                stepPx *= 1.08;
                float2 off = dir * pd * texel;
                sumFwd += float(blurred.sample(s, offsetUV + off).a);
                sumBwd += float(blurred.sample(s, offsetUV - off).a);
            }
            float total = sumFwd + sumBwd;
            gradT = (total > 0.01) ? saturate(sumBwd / total) : 0.5;
        } else {
            // Radial: distance from object edge
            gradT = saturate(t);
        }
        float lutPos = gradT * float(KK_GRADIENT_LUT_SIZE - 1);
        int idx0 = int(floor(lutPos));
        int idx1 = min(idx0 + 1, KK_GRADIENT_LUT_SIZE - 1);
        float3 srgb = mix(gradientLUT[idx0], gradientLUT[idx1], lutPos - float(idx0));
        glowColor = pow(srgb, 2.2);
    } else {
        // Solid
        glowColor = pow(*glowColorPtr, 2.2);
    }

    // Composite glow behind original
    float behindAlpha = glowAlpha * (1.0 - float(original.a));
    float3 result = glowColor * behindAlpha + float3(original.rgb);
    float resultAlpha = behindAlpha + float(original.a);
    return float4(result, resultAlpha);
}
