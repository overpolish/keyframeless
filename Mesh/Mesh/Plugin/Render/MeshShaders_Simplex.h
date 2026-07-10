/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include "MeshShaderCommon.h"

// --- Simplex Noise ("Simplex"): ported from paper-design/shaders (Apache-2.0),
// GLSL -> MSL. A multi-colour gradient mapped through a combination of two
// Simplex noises, stepped into bands. See THIRD-PARTY-NOTICES. The FxPlug port
// drops the source's fit/scale/rotation/offset sizing (full frame, centred),
// synthesising v_patternUV in a resolution-independent reference frame so all
// viewers show the same scene. snoise reuses the Dithering port's dth_snoise.

constant float SN_PATTERN_TILES = 8.0;

static float sn_getNoise(float2 uv, float t) {
    float noise = 0.5 * dth_snoise(uv - float2(0.0, 0.3 * t));
    noise += 0.5 * dth_snoise(2.0 * uv + float2(0.0, 0.32 * t));
    return noise;
}

static float sn_steppedSmooth(float m, float steps, float softness) {
    float stepT = floor(m * steps) / steps;
    float f = m * steps - floor(m * steps);
    float fw = steps * fwidth(m);
    float smoothed = smoothstep(0.5 - softness, min(1.0, 0.5 + softness + fw), f);
    return stepT + smoothed / steps;
}

fragment float4 simplexNoiseFragment(RasterizerData in [[stage_in]],
                                     constant SimplexNoiseUniforms &u [[buffer(MeshFragmentIndex_Grid)]],
                                     constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]],
                                     constant MeshCommonUniforms &cm [[buffer(MeshFragmentIndex_Common)]]) {
    float2 res = max(cm.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with the other types.
    float t = 0.2 * (cm.time * cm.speed + fmod(cm.seed, 10000.0));

    // Synthesize v_patternUV: aspect-correct, centred, origin-shifted, common
    // Scale + Rotation applied about the centre, then tiled. (y flipped so the
    // OSC drag direction matches.)
    float2 vPatternUV = mesh_objectUV(in.textureCoordinate, aspect, cm);
    vPatternUV *= SN_PATTERN_TILES;

    float2 shape_uv = vPatternUV * 0.1;
    float shape = 0.5 + 0.5 * sn_getNoise(shape_uv, t);

    float cCount = max((float)u.colorsCount, 1.0);
    // extraSides: wrap the ramp at both ends (paper hardcodes this true).
    float mixer = (shape - 0.5 / cCount) * cCount;
    float steps = max(1.0, u.stepsPerColor);

    float4 gradient = u.colors[0];
    gradient.rgb *= gradient.a;
    for (int i = 1; i < KK_MESH_GRAD_COLORS; i++) {
        if (i >= (int)cCount)
            break;
        float localM = clamp(mixer - float(i - 1), 0.0, 1.0);
        localM = sn_steppedSmooth(localM, steps, 0.5 * u.softness);
        float4 c = u.colors[i];
        c.rgb *= c.a;
        gradient = mix(gradient, c, localM);
    }

    if ((mixer < 0.0) || (mixer > (cCount - 1.0))) {
        float localM = mixer + 1.0;
        if (mixer > (cCount - 1.0))
            localM = mixer - (cCount - 1.0);
        localM = sn_steppedSmooth(localM, steps, 0.5 * u.softness);
        float4 cFst = u.colors[0];
        cFst.rgb *= cFst.a;
        float4 cLast = u.colors[(int)(cCount - 1.0)];
        cLast.rgb *= cLast.a;
        gradient = mix(cLast, cFst, localM);
    }

    float3 color = gradient.rgb;
    float opacity = gradient.a;

    // Shared core film grain + anti-band dither.
    color = mesh_applyGrain(color, in.clipSpacePosition.xy, cm);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}
