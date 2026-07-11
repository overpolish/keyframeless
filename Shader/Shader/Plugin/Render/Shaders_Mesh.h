/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include "ShaderCommon.h"

// --- Shader Gradient: translated (GLSL -> MSL) and modified from the
// mesh-gradient shader in paper-design/shaders (Apache-2.0). See
// THIRD-PARTY-NOTICES.md at the repo root for the licence text + attribution.
// Animated colour spots warped by noise distortion + swirl, blended by
// inverse-distance, with an in-shader grain mixer + overlay. Colours are
// straight sRGB; all maths stay in gamma space (as the source does), then the
// final colour is linearised for FCP's float buffer via the EncodeSRGB path.

fragment float4 fragmentShader(RasterizerData in [[stage_in]],
                               constant ShaderGradientUniforms &u [[buffer(ShaderFragmentIndex_Grid)]],
                               constant int &encodeSRGB [[buffer(ShaderFragmentIndex_EncodeSRGB)]],
                               constant ShaderCommonUniforms &cm [[buffer(ShaderFragmentIndex_Common)]]) {
    // Origin shifts the whole field. Matches the OSC drag direction (uv here is
    // y-down, so no y-flip on the origin offset).
    float2 uv = in.textureCoordinate - (cm.origin - 0.5);
    // Common Scale (zoom) + Rotation transform the field about its centre. This
    // shader samples in y-down UV (no y-flip), so negate the rotation to match
    // the other (y-up) types' direction.
    {
        float2 c = uv - 0.5;
        c = mg_rotate(c, -cm.rotation);
        c /= max(cm.scale, float2(0.01));
        uv = c + 0.5;
    }

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
    float seedFrame = fmod(cm.seed, 10000.0);
    float t = 0.5 * (cm.time * cm.speed + seedFrame + firstFrameOffset);

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
    int n = clamp(u.colorsCount, 1, KK_SHADER_GRAD_COLORS);
    for (int i = 0; i < n; i++) {
        float2 pos = mg_getPosition(i, t);
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

    opacity = clamp(opacity, 0.0, 1.0);

    // Shared core film grain + anti-band dither.
    color = shader_applyGrain(color, in.clipSpacePosition.xy, cm);

    // `color` is gamma-sRGB. 8-bit dest wants gamma; FCP float dest wants linear.
    float3 outRGB = encodeSRGB ? color : srgb_to_linear(color);
    return float4(outRGB * opacity, opacity);
}
