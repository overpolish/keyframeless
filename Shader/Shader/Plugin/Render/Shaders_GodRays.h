/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include "ShaderCommon.h"

// --- God Rays ("God Rays"): ported from paper-design/shaders (Apache-2.0),
// GLSL -> MSL. Animated rays of light radiating from the centre, blended
// through up to 5 ray colours over a background, with a central glow and a
// bloom overlay. See THIRD-PARTY-NOTICES. The FxPlug port drops the source's
// fit/scale/rotation/offset sizing (full frame, centred) and replaces the
// source's noise-texture randomiser with the hash-based dth_hash21. The rays'
// metric stays isotropic (aspect-corrected) so they radiate round.

constant int GR_MAX_COLORS = 5;

static float gr_valueNoise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = dth_hash21(i);
    float b = dth_hash21(i + float2(1.0, 0.0));
    float c = dth_hash21(i + float2(0.0, 1.0));
    float d = dth_hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float gr_raysShape(float2 uv, float r, float freq, float intensity) {
    float a = atan2(uv.y, uv.x);
    float2 left = float2(a * freq, r);
    float2 right = float2(fract(a / 6.28318530718) * 6.28318530718 * freq, r);
    float n_left = pow(gr_valueNoise(left), intensity);
    float n_right = pow(gr_valueNoise(right), intensity);
    return mix(n_right, n_left, smoothstep(-0.15, 0.15, uv.x));
}

fragment float4 godRaysFragment(RasterizerData in [[stage_in]],
                                constant GodRaysUniforms &u [[buffer(ShaderFragmentIndex_Grid)]],
                                constant int &encodeSRGB [[buffer(ShaderFragmentIndex_EncodeSRGB)]],
                               constant ShaderCommonUniforms &cm [[buffer(ShaderFragmentIndex_Common)]]) {
    float2 res = max(cm.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with the other types.
    float t = 0.2 * (cm.time * cm.speed + fmod(cm.seed, 10000.0));

    // Synthesize the object-box UV: aspect-correct (round rays), centred at 0,
    // origin-shifted, common Scale + Rotation applied about the centre. (y
    // flipped so the OSC drag direction matches.)
    float2 shape_uv = shader_objectUV(in.textureCoordinate, aspect, cm);

    float radius = length(shape_uv);
    float spots = 6.5 * abs(u.spotty);
    float intensity = 4.0 - 3.0 * clamp(u.intensity, 0.0, 1.0);

    float midSize = 10.0 * abs(u.midSize);
    float ms_lo = 0.02 * midSize;
    float ms_hi = max(midSize, 1e-6);
    float middleShape = pow(u.midIntensity, 0.3) * (1.0 - smoothstep(ms_lo, ms_hi, 3.0 * radius));
    middleShape = pow(middleShape, 5.0);

    float density = 6.0 * u.density + step(0.5, u.density) * pow(4.5 * (u.density - 0.5), 4.0);

    float3 accumColor = float3(0.0);
    float accumAlpha = 0.0;

    for (int i = 0; i < GR_MAX_COLORS; i++) {
        if (i >= u.colorsCount)
            break;

        float2 rotatedUV = mg_rotate(shape_uv, float(i) + 1.0);

        float r1 = radius * (1.0 + 0.4 * float(i)) - 3.0 * t;
        float r2 = 0.5 * radius * (1.0 + spots) - 2.0 * t;
        float f = mix(1.0, 3.0 + 0.5 * float(i), dth_hash11(float(i) * 15.0)) * density;

        float ray = gr_raysShape(rotatedUV, r1, 5.0 * f, intensity);
        ray *= gr_raysShape(rotatedUV, r2, 4.0 * f, intensity);
        ray += (1.0 + 4.0 * ray) * middleShape;
        ray = clamp(ray, 0.0, 1.0);

        float srcAlpha = u.colors[i].a * ray;
        float3 srcColor = u.colors[i].rgb * srcAlpha;

        float3 alphaBlendColor = accumColor + (1.0 - accumAlpha) * srcColor;
        float alphaBlendAlpha = accumAlpha + (1.0 - accumAlpha) * srcAlpha;

        float3 addBlendColor = accumColor + srcColor;
        float addBlendAlpha = accumAlpha + srcAlpha;

        accumColor = mix(alphaBlendColor, addBlendColor, u.bloom);
        accumAlpha = mix(alphaBlendAlpha, addBlendAlpha, u.bloom);
    }

    float overlayAlpha = u.colorBloom.a;
    float3 overlayColor = u.colorBloom.rgb * overlayAlpha;

    float3 colorWithOverlay = accumColor + accumAlpha * overlayColor;
    accumColor = mix(accumColor, colorWithOverlay, u.bloom);

    float3 bgColor = u.colorBack.rgb * u.colorBack.a;

    float3 color = accumColor + (1.0 - accumAlpha) * bgColor;
    float opacity = accumAlpha + (1.0 - accumAlpha) * u.colorBack.a;
    color = clamp(color, 0.0, 1.0);
    opacity = clamp(opacity, 0.0, 1.0);

    // Shared core film grain + anti-band dither.
    color = shader_applyGrain(color, in.clipSpacePosition.xy, cm);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}
