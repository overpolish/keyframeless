/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include "ShaderCommon.h"

// --- Warp: ported from paper-design/shaders (Apache-2.0), GLSL -> MSL. Animated
// colour fields warped by noise + iterative swirl over a base pattern (checks /
// stripes / edge), blending up to 10 colours by a distribution/softness ramp.
// See THIRD-PARTY-NOTICES. The FxPlug port drops the source's fit/scale/rotation/
// offset sizing (full frame, centred), synthesising v_patternUV in a resolution-
// independent reference frame so all viewers show the same scene. valueNoise's
// texture randomiser is replaced by the Dithering port's procedural hash.

// Pattern tiling density. Tunable: higher = more repeats.
constant float WARP_PATTERN_TILES = 4.0;
constant float WARP_TWO_PI = 6.28318530718;

// paper samples a noise texture (textureRandomizerG); substitute a procedural
// hash on the integer cell so the port stays self-contained.
static float warp_randomG(float2 p) { return dth_hash21(p); }

static float warp_valueNoise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = warp_randomG(i);
    float b = warp_randomG(i + float2(1.0, 0.0));
    float c = warp_randomG(i + float2(0.0, 1.0));
    float d = warp_randomG(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fragment float4 warpFragment(RasterizerData in [[stage_in]],
                             constant WarpUniforms &u [[buffer(ShaderFragmentIndex_Grid)]],
                             constant int &encodeSRGB [[buffer(ShaderFragmentIndex_EncodeSRGB)]],
                             constant ShaderCommonUniforms &cm [[buffer(ShaderFragmentIndex_Common)]]) {
    float2 res = max(cm.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with the other types. paper's firstFrameOffset = 118.
    float t = 0.0625 * (cm.time * cm.speed + fmod(cm.seed, 10000.0) + 118.0);

    // Synthesize v_patternUV: aspect-correct, centred, origin-shifted, tiled.
    // (y flipped so the OSC drag direction matches; 0.5,0.5 = centre.)
    float2 uvn = float2(in.textureCoordinate.x, 1.0 - in.textureCoordinate.y);
    uvn -= float2(cm.origin.x - 0.5, 0.5 - cm.origin.y);
    float2 vPatternUV = uvn - 0.5;
    vPatternUV.x *= aspect;
    // Common Scale (zoom) + Rotation about the centre.
    vPatternUV = mg_rotate(vPatternUV, cm.rotation);
    vPatternUV /= max(cm.scale, float2(0.01));
    vPatternUV *= WARP_PATTERN_TILES;

    float2 uv = vPatternUV;
    uv *= 0.5;

    float n1 = warp_valueNoise(uv * 1.0 + t);
    float n2 = warp_valueNoise(uv * 2.0 - t);
    float angle = n1 * WARP_TWO_PI;
    uv.x += 4.0 * u.distortion * n2 * cos(angle);
    uv.y += 4.0 * u.distortion * n2 * sin(angle);

    float swirl = u.swirl;
    for (int i = 1; i <= 20; i++) {
        if (i >= (int)u.swirlIterations)
            break;
        float iFloat = float(i);
        uv.x += swirl / iFloat * cos(t + iFloat * 1.5 * uv.y);
        uv.y += swirl / iFloat * cos(t + iFloat * 1.0 * uv.x);
    }

    float proportion = clamp(u.proportion, 0.0, 1.0);
    float cCount = max((float)u.colorsCount, 1.0);

    float shape = 0.0;
    if (u.shape == 0) {
        // Checks
        float2 s = uv * (0.5 + 3.5 * u.shapeScale);
        shape = 0.5 + 0.5 * sin(s.x) * cos(s.y);
        shape += 0.48 * sign(proportion - 0.5) * pow(abs(proportion - 0.5), 0.5);
    } else if (u.shape == 1) {
        // Stripes
        float2 s = uv * (2.0 * u.shapeScale);
        float f = fract(s.y);
        shape = smoothstep(0.0, 0.55, f) * (1.0 - smoothstep(0.45, 1.0, f));
        shape += 0.48 * sign(proportion - 0.5) * pow(abs(proportion - 0.5), 0.5);
    } else {
        // Edge
        float shapeScaling = 5.0 * (1.0 - u.shapeScale);
        float e0 = 0.45 - shapeScaling;
        float e1 = 0.55 + shapeScaling;
        shape = smoothstep(min(e0, e1), max(e0, e1), 1.0 - uv.y + 0.3 * (proportion - 0.5));
    }

    float mixer = shape * (cCount - 1.0);
    float4 gradient = u.colors[0];
    gradient.rgb *= gradient.a;
    float aa = fwidth(shape);
    for (int i = 1; i < KK_SHADER_GRAD_COLORS; i++) {
        if (i >= (int)cCount)
            break;
        float m = clamp(mixer - float(i - 1), 0.0, 1.0);
        float localMixerStart = floor(m);
        float softness = 0.5 * u.softness + fwidth(m);
        float smoothed = smoothstep(max(0.0, 0.5 - softness - aa), min(1.0, 0.5 + softness + aa), m - localMixerStart);
        float stepped = localMixerStart + smoothed;
        m = mix(stepped, m, u.softness);
        float4 c = u.colors[i];
        c.rgb *= c.a;
        gradient = mix(gradient, c, m);
    }

    float3 color = gradient.rgb;
    float opacity = gradient.a;

    // Shared core film grain + anti-band dither.
    color = shader_applyGrain(color, in.clipSpacePosition.xy, cm);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}
