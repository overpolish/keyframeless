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

static float3 oklab_to_linear_srgb(float3 lab) {
    float l_ = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
    float m_ = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
    float s_ = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
    float l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
    return float3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                  -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                  -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
}

static float3 linear_to_srgb(float3 c) {
    c = clamp(c, 0.0, 1.0);
    float3 hi = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    float3 lo = 12.92 * c;
    return select(hi, lo, c <= 0.0031308);
}

static float rand01(float2 p) { return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453); }

// Mesh gradient: bilinearly interpolate the rows x cols control colours in
// OKLab across the output, convert to sRGB, and add a touch of dither to break
// up banding. (Bilinear/Gouraud for now; bicubic smoothing + point warp land in
// later increments.) Premultiplied-alpha blend, so output rgb*a.
fragment float4 fragmentShader(RasterizerData in [[stage_in]],
                               constant MeshGridUniforms &grid [[buffer(MeshFragmentIndex_Grid)]],
                               constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]]) {
    float2 uv = clamp(in.textureCoordinate, 0.0, 1.0);

    // Freeform blend: per-point Gaussian falloff in OKLab. Each point's Spread
    // sets how far its colour reaches (big = broad wash, small = tight blob).
    // Normalized by the weight sum so the whole frame stays covered.
    int n = clamp(grid.count, 1, KK_MESH_MAX_VERTS);
    float4 acc = float4(0.0);
    float wsum = 0.0;
    for (int i = 0; i < n; i++) {
        float2 d = uv - grid.points[i];
        float s = max(grid.spreads[i], 0.0);
        float s2 = s * s;
        // Area-weighted Gaussian: the amplitude scales with Spread so a point
        // fades to nothing as Spread -> 0 (lets points animate in/out cleanly,
        // instead of leaving a hard dot at the centre where exp(0)==1). With
        // equal spreads the s2 factor cancels in the normalize below, so the
        // default look is unchanged; it only matters when spreads differ.
        float w = s2 * exp(-dot(d, d) / max(s2, 1e-6));
        acc += grid.colorsOklab[i] * w;
        wsum += w;
    }
    float4 lab = acc / max(wsum, 1e-5);

    // Blend perceptually in OKLab, then match the output encoding to the
    // target: gamma for 8-bit unorm buffers, linear for FCP's float working
    // buffers. Dither only helps the 8-bit path.
    float3 lin = oklab_to_linear_srgb(lab.xyz);
    float3 outRGB;
    if (encodeSRGB) {
        outRGB = linear_to_srgb(lin);
        outRGB = clamp(outRGB + (rand01(in.clipSpacePosition.xy) - 0.5) / 255.0, 0.0, 1.0);
    } else {
        outRGB = clamp(lin, 0.0, 1.0);
    }
    float a = lab.w;
    return float4(outRGB * a, a);
}
