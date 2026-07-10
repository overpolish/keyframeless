/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include "MeshShaderCommon.h"

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

fragment float4 neuroNoiseFragment(RasterizerData in [[stage_in]],
                                   constant NeuroNoiseUniforms &u [[buffer(MeshFragmentIndex_Grid)]],
                                   constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]],
                                   constant MeshCommonUniforms &cm [[buffer(MeshFragmentIndex_Common)]]) {
    float2 res = max(cm.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with the other types.
    float t = 0.5 * (cm.time * cm.speed + fmod(cm.seed, 10000.0));

    // Synthesize v_patternUV: aspect-correct, centred, origin-shifted, common
    // Scale + Rotation applied about the centre, then tiled. (y flipped so the
    // OSC drag direction matches.)
    float2 vPatternUV = mesh_objectUV(in.textureCoordinate, aspect, cm);
    vPatternUV *= NEURO_PATTERN_TILES;

    float2 shape_uv = vPatternUV * 0.13;
    float noise = neuro_shape(shape_uv, t);
    noise = (1.0 + u.brightness) * noise * noise;
    noise = pow(noise, 0.7 + 6.0 * u.contrast);
    noise = min(1.4, noise);
    float blend = smoothstep(0.7, 1.4, noise);

    float4 frontC = u.colorFront;
    frontC.rgb *= frontC.a;
    float4 midC = u.colorMid;
    midC.rgb *= midC.a;
    float4 blendFront = mix(midC, frontC, blend);

    float safeNoise = max(noise, 0.0);
    float3 color = blendFront.rgb * safeNoise;
    float opacity = clamp(blendFront.a * safeNoise, 0.0, 1.0);
    float3 bgColor = u.colorBack.rgb * u.colorBack.a;
    color = color + bgColor * (1.0 - opacity);
    opacity = opacity + u.colorBack.a * (1.0 - opacity);

    // Shared core film grain + anti-band dither.
    color = mesh_applyGrain(color, in.clipSpacePosition.xy, cm);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}
