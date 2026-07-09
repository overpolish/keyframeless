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

// The gradient blends its colours in gamma-sRGB (as the source shader does);
// convert to linear for FCP's float working buffer.
static float3 srgb_to_linear(float3 c) {
    c = clamp(c, 0.0, 1.0);
    float3 hi = pow((c + 0.055) / 1.055, float3(2.4));
    float3 lo = c / 12.92;
    return select(hi, lo, c <= 0.04045);
}

// --- Mesh Gradient: translated (GLSL -> MSL) and modified from the
// mesh-gradient shader in paper-design/shaders (Apache-2.0). See
// THIRD-PARTY-NOTICES.md at the repo root for the licence text + attribution.
// Animated colour spots warped by noise distortion + swirl, blended by
// inverse-distance, with an in-shader grain mixer + overlay. Colours are
// straight sRGB; all maths stay in gamma space (as the source does), then the
// final colour is linearised for FCP's float buffer via the EncodeSRGB path.

static float2 mg_rotate(float2 v, float a) {
    float s = sin(a), c = cos(a);
    return float2(c * v.x + s * v.y, -s * v.x + c * v.y);
}

static float mg_hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.164);
    return fract(p.x * p.y);
}

static float mg_valueNoise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = mg_hash21(i);
    float b = mg_hash21(i + float2(1.0, 0.0));
    float c = mg_hash21(i + float2(0.0, 1.0));
    float d = mg_hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    float x1 = mix(a, b, u.x);
    float x2 = mix(c, d, u.x);
    return mix(x1, x2, u.y);
}

static float mg_noise(float2 n, float2 seedOffset) { return mg_valueNoise(n + seedOffset); }

static float2 mg_getPosition(int i, float t) {
    float a = float(i) * 0.37;
    float b = 0.6 + fract(float(i) / 3.0) * 0.9;
    float c = 0.8 + fract(float(i + 1) / 4.0);
    float x = sin(t * b + a);
    float y = cos(t * c + a * 1.5);
    return 0.5 + 0.5 * float2(x, y);
}

fragment float4 fragmentShader(RasterizerData in [[stage_in]],
                               constant MeshGradientUniforms &u [[buffer(MeshFragmentIndex_Grid)]],
                               constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]]) {
    float2 uv = clamp(in.textureCoordinate, 0.0, 1.0);
    float2 grainUV = uv * 1000.0;

    float grain = mg_noise(grainUV, float2(0.0));
    float mixerGrain = 0.4 * u.grainMixer * (grain - 0.5);

    // Seed is the initial phase (a "start frame"): it offsets the animation
    // time, so each seed picks a different, coherent point in the endless flow.
    // The source shader's fixed 41.5 offset is just the default seed.
    //
    // Wrap the seed before it enters the trig. A large seed (e.g. 574468) makes
    // the sin/cos phase arguments huge, and float32 can no longer resolve the
    // small per-pixel phase variation in the distortion warp - it quantizes into
    // visible chunky steps. fmod keeps the phase precise while still giving each
    // seed a distinct frame (10000 distinct start points before it repeats).
    const float firstFrameOffset = 41.5;
    float seedFrame = fmod(u.seed, 10000.0);
    float t = 0.5 * (u.time * u.speed + seedFrame + firstFrameOffset);

    float radius = smoothstep(0.0, 1.0, length(uv - 0.5));
    float center = 1.0 - radius;
    for (float i = 1.0; i <= 2.0; i++) {
        uv.x += u.distortion * center / i * sin(t + i * 0.4 * smoothstep(0.0, 1.0, uv.y)) *
                cos(0.2 * t + i * 2.4 * smoothstep(0.0, 1.0, uv.y));
        uv.y += u.distortion * center / i * cos(t + i * 2.0 * smoothstep(0.0, 1.0, uv.x));
    }

    float2 uvRotated = uv - float2(0.5);
    float angle = 3.0 * u.swirl * radius;
    uvRotated = mg_rotate(uvRotated, -angle);
    uvRotated += float2(0.5);

    float3 color = float3(0.0);
    float opacity = 0.0;
    float totalWeight = 0.0;
    int n = clamp(u.colorsCount, 1, KK_MESH_GRAD_COLORS);
    for (int i = 0; i < n; i++) {
        float2 pos = mg_getPosition(i, t) + mixerGrain;
        float3 colorFraction = u.colors[i].rgb * u.colors[i].a;
        float opacityFraction = u.colors[i].a;
        float dist = length(uvRotated - pos);
        dist = pow(dist, 3.5);
        float weight = 1.0 / (dist + 1e-3);
        color += colorFraction * weight;
        opacity += opacityFraction * weight;
        totalWeight += weight;
    }
    color /= max(1e-4, totalWeight);
    opacity /= max(1e-4, totalWeight);

    float grainOverlay = mg_valueNoise(mg_rotate(grainUV, 1.0) + float2(3.0));
    grainOverlay = mix(grainOverlay, mg_valueNoise(mg_rotate(grainUV, 2.0) + float2(-1.0)), 0.5);
    grainOverlay = pow(grainOverlay, 1.3);
    float grainOverlayV = grainOverlay * 2.0 - 1.0;
    float3 grainOverlayColor = float3(step(0.0, grainOverlayV));
    float grainOverlayStrength = u.grainOverlay * abs(grainOverlayV);
    grainOverlayStrength = pow(grainOverlayStrength, 0.8);
    color = mix(color, grainOverlayColor, 0.35 * grainOverlayStrength);
    opacity += 0.5 * grainOverlayStrength;
    opacity = clamp(opacity, 0.0, 1.0);

    // Triangular ordered dither (~1 LSB) to break up 8-bit banding in the very
    // flat regions of the field (the stair-stepping that shows on some frames).
    // Applied in gamma space so it survives into both output paths.
    float dither = (mg_hash21(in.clipSpacePosition.xy) - mg_hash21(in.clipSpacePosition.yx + 7.0)) / 255.0;
    color = clamp(color + dither, 0.0, 1.0);

    // `color` is gamma-sRGB. 8-bit dest wants gamma; FCP float dest wants linear.
    float3 outRGB = encodeSRGB ? color : srgb_to_linear(color);
    return float4(outRGB * opacity, opacity);
}
