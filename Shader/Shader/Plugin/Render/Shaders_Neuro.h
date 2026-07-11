/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include "ShaderCommon.h"

// --- Neuro Noise ("Neuro"): ported from paper-design/shaders (Apache-2.0),
// GLSL -> MSL. A glowing web-like structure of accumulated rotated sine layers
// (zozuar's algorithm) blended between a mid + front colour over a background.
// See THIRD-PARTY-NOTICES. The FxPlug port drops the source's fit/scale/
// rotation/offset sizing (full frame, centred), synthesising v_patternUV in a
// resolution-independent reference frame so all viewers show the same scene.
// rotate reuses mg_rotate.

constant float NEURO_PATTERN_TILES = 10.0;

static float neuro_shape(float2 uv, float t) {
    float2 sine_acc = float2(0.0);
    float2 res = float2(0.0);
    float scale = 8.0;
    for (int j = 0; j < 15; j++) {
        uv = mg_rotate(uv, 1.0);
        sine_acc = mg_rotate(sine_acc, 1.0);
        float2 layer = uv * scale + float(j) + sine_acc - t;
        sine_acc += sin(layer);
        res += (0.5 + 0.5 * cos(layer)) / scale;
        scale *= 1.2;
    }
    return res.x + res.y;
}

// Smooth palette sample at position `pos` (0..1): Color 1 at 0 (the base),
// Color N at 1. Returns a premultiplied rgba.
static float4 neuro_paletteColor(float pos, constant float4 *colors, int count) {
    int n = max(count, 1);
    float fp = clamp(pos, 0.0, 1.0) * float(n - 1);
    int lo = clamp(int(floor(fp)), 0, n - 1);
    int hi = min(lo + 1, n - 1);
    float f = fp - float(lo);
    float4 c = mix(colors[lo], colors[hi], f);
    return float4(c.rgb * c.a, c.a);
}

fragment float4 neuroNoiseFragment(RasterizerData in [[stage_in]],
                                   constant NeuroNoiseUniforms &u [[buffer(ShaderFragmentIndex_Grid)]],
                                   constant int &encodeSRGB [[buffer(ShaderFragmentIndex_EncodeSRGB)]],
                                   constant ShaderCommonUniforms &cm [[buffer(ShaderFragmentIndex_Common)]]) {
    float2 res = max(cm.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with the other types.
    float t = 0.5 * (cm.time * cm.speed + fmod(cm.seed, 10000.0));

    // Synthesize v_patternUV: aspect-correct, centred, origin-shifted, common
    // Scale + Rotation applied about the centre, then tiled. (y flipped so the
    // OSC drag direction matches.)
    float2 vPatternUV = shader_objectUV(in.textureCoordinate, aspect, cm);
    vPatternUV *= NEURO_PATTERN_TILES;

    float2 shape_uv = vPatternUV * 0.13;
    float noise = neuro_shape(shape_uv, t);
    noise = (1.0 + u.brightness) * noise * noise;
    noise = pow(noise, 0.7 + 6.0 * u.contrast);
    noise = min(1.4, noise);

    // The line intensity is the palette position: dark background (low noise) =
    // Color 1, glowing crossings (high noise) climb to Color N. Smooth blend.
    float q = clamp(noise / 1.4, 0.0, 1.0);
    float4 col = neuro_paletteColor(q, u.colors, u.colorsCount);
    float3 color = col.rgb;
    float opacity = col.a;

    // Shared core film grain + anti-band dither.
    color = shader_applyGrain(color, in.clipSpacePosition.xy, cm);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}
