/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#include "ShaderTypes.h"
#include <KeyframelessKit/KKShaderTypes.h>
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

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
// from the source image. Output is what MPS will blur for the outer glow.
// Threshold does NOT affect this pass - outer glow is independent of bloom.
fragment float4 glowPrep(RasterizerData in [[stage_in]], texture2d<half> source [[texture(KKTextureIndex_InputImage)]],
                         constant int *colorMode [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    half4 c = source.sample(s, in.textureCoordinate);
    if (*colorMode == 2)
        return float4(c);
    return float4(0, 0, 0, float(c.a));
}

// Bloom prep: extract bright pixels from the source as premultiplied RGBA.
// Uses max(r,g,b) so saturated colors (neon green, pure red) bloom too.
fragment float4 glowBloomPrep(RasterizerData in [[stage_in]],
                              texture2d<half> source [[texture(KKTextureIndex_InputImage)]],
                              constant float *thresholdPtr [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    half4 c = source.sample(s, in.textureCoordinate);
    if (c.a < 0.001h)
        return float4(0);
    float thresh = *thresholdPtr;
    float3 rgb = float3(c.rgb) / float(c.a);
    float brightness = max(rgb.r, max(rgb.g, rgb.b));
    float cutoff = 1.0 - thresh;
    float bloom = smoothstep(cutoff, cutoff + 0.2, brightness);
    return float4(rgb * bloom * float(c.a), bloom * float(c.a));
}

// Composite: layer the blurred glow behind the original source,
// then additively blend the blurred bloom on top.
fragment float4 glowComposite(RasterizerData in [[stage_in]],
                              texture2d<half> source [[texture(KKTextureIndex_InputImage)]],
                              texture2d<half> blurred [[texture(1)]], texture2d<half> bloomTex [[texture(2)]],
                              constant float *radiusX [[buffer(FragmentIndex_RadiusX)]],
                              constant float *radiusY [[buffer(FragmentIndex_RadiusY)]],
                              constant float *intensity [[buffer(FragmentIndex_Intensity)]],
                              constant float *falloff [[buffer(FragmentIndex_Falloff)]],
                              constant float2 *offsetPtr [[buffer(FragmentIndex_Offset)]],
                              constant float3 *glowColorPtr [[buffer(FragmentIndex_GlowColor)]],
                              constant int *colorMode [[buffer(FragmentIndex_ColorMode)]],
                              constant float3 *gradientLUT [[buffer(FragmentIndex_GradientLUT)]],
                              constant int *gradientType [[buffer(FragmentIndex_GradientType)]],
                              constant float *gradientAngle [[buffer(FragmentIndex_GradientAngle)]],
                              constant float *noiseAmount [[buffer(FragmentIndex_Noise)]],
                              constant float *noiseOffset [[buffer(FragmentIndex_NoiseOffset)]],
                              constant float *noiseSeed [[buffer(FragmentIndex_NoiseSeed)]],
                              constant float2 *blurUVScale [[buffer(FragmentIndex_BlurUVScale)]],
                              constant float *thresholdPtr [[buffer(FragmentIndex_Threshold)]],
                              constant float2 *tileOffsetPx [[buffer(FragmentIndex_TileOffsetPx)]],
                              constant float2 *destImgSizePx [[buffer(FragmentIndex_DestImgSizePx)]],
                              constant float2 *srcOriginInDestPx [[buffer(FragmentIndex_SrcOriginInDestPx)]],
                              constant float2 *srcImgSizePx [[buffer(FragmentIndex_SrcImgSizePx)]]) {

    // Source/blur sample positions are derived from the fragment's Y-down
    // pixel position in the final composited image (clipSpacePosition +
    // tileOffsetPx) - robust to sub-tiling and to FCP's project-library
    // reverse-Y composite. destUV indexes the dest-image-sized prep+blur;
    // srcUV indexes the source texture's actual sub-region of dest image.
    float2 pxInDest = in.clipSpacePosition.xy + (*tileOffsetPx);
    float2 destUV = pxInDest / (*destImgSizePx);
    float2 srcUV = (pxInDest - (*srcOriginInDestPx)) / (*srcImgSizePx);

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_zero);
    constexpr sampler srcS(mag_filter::linear, min_filter::linear, address::clamp_to_zero);

    half4 original = source.sample(srcS, srcUV);
    float rx = *radiusX;
    float ry = *radiusY;
    float maxR = max(rx, ry);
    float glowIntensity = *intensity;
    float glowFalloff = *falloff;
    int mode = *colorMode;

    if (maxR < 0.01)
        return float4(original);

    // Remap UVs to the active sub-region of the pooled blur texture.
    float2 bScale = *blurUVScale;
    float2 baseUV = destUV * bScale;
    float2 offsetUV = baseUV + *offsetPtr * bScale;
    // Scale UV to create elliptical glow from isotropic blur.
    float2 bCenter = bScale * 0.5;
    float2 uvScale = float2(maxR / max(rx, 0.01), maxR / max(ry, 0.01));
    float2 scaledUV = bCenter + (offsetUV - bCenter) * uvScale;
    float4 blur = float4(blurred.sample(s, scaledUV));
    // The elliptical UV scaling pushes scaledUV outside the valid blur region
    // (the active sub-rect [0, bScale]) for fragments far along the squashed
    // axis when rx/ry is small. There's no glow out there, so zero it - else the
    // sampler pulls the texture's edge / unused-pool content into a soft band
    // along the top/bottom (or left/right) of the frame.
    if (any(scaledUV < float2(0.0)) || any(scaledUV > bScale))
        blur = float4(0.0);

    float t = 1.0 - blur.a;

    // Opacity
    float fade = 1.0 - smoothstep(0.0, 1.0 / glowFalloff, t);
    float nAmt = *noiseAmount;
    if (nAmt > 0.0) {
        float2 px = destUV * float2(blurred.get_width(), blurred.get_height());
        float radialDist = 1.0 - blur.a;
        float pixelRand = hash12(floor(px));
        // Single radial flow - all layers move outward at the same speed
        float rp = radialDist * 6.0 - *noiseSeed + pixelRand * 0.5;
        float band = floor(rp);
        float blend = smoothstep(0.0, 1.0, fract(rp));
        // Fine + coarse spatial scales share the same radial band
        float2 fine = floor(px);
        float2 coarse = floor(px * 0.5);
        float nFine =
            mix(hash12(fine + band * float2(127.1, 311.7)), hash12(fine + (band + 1.0) * float2(127.1, 311.7)), blend);
        float nCoarse = mix(hash12(coarse + band * float2(269.5, 183.3)),
                            hash12(coarse + (band + 1.0) * float2(269.5, 183.3)), blend);
        float n = nFine * 0.7 + nCoarse * 0.3;
        float nOff = *noiseOffset;
        float nScale = nOff > 0.0 ? 1.0 - smoothstep(0.0, 1.0 - nOff + 0.01, blur.a) : 1.0;
        fade *= saturate(1.0 - nAmt * nScale * (1.0 - n));
    }
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
            float stepPx = max(maxR * 0.3, 2.0);
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

    // Bloom: additive blend of separately-blurred bright-pass.
    // Light scatters from bright sources - pure addition, preserves source color.
    float thresh = *thresholdPtr;
    if (thresh > 0.0) {
        float2 bloomUV = destUV * bScale;
        float4 bloom = float4(bloomTex.sample(s, bloomUV));
        result += float3(bloom.rgb) * glowIntensity * float(original.a);
    }

    return float4(result, resultAlpha);
}
