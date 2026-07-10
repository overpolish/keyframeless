/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include "MeshShaderCommon.h"

// --- Grain Gradient ("Grainy"): ported from paper-design/shaders (Apache-2.0),
// GLSL -> MSL. A procedural shape field (wave/dots/truchet/corners/ripple/blob/
// sphere) indexes a multi-colour ramp, distorted by noise (intensity) with a
// grainy overlay (noise), composited over a background. See THIRD-PARTY-NOTICES.
// The FxPlug port drops the source's fit/scale/rotation/offset sizing (full
// frame, centred), synthesising v_objectUV / v_patternUV in a resolution-
// independent reference frame so all viewers show the same scene. Shapes and
// grain live in normalized (content) space, so the mini/thumbnail are the main
// viewer scaled down. snoise / hash reuse the Dithering port's helpers.

// Pattern tiling density (shapes 1..3). Tunable: higher = more repeats.
constant float GG_PATTERN_TILES = 16.0;
constant float GG_REF_H = 1080.0;

// paper samples a precomputed noise texture (textureRandomizerR); the port
// substitutes a procedural hash so it stays self-contained.
static float gg_randomR(float2 p) { return dth_hash21(p); }

static float gg_valueNoiseR(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = gg_randomR(i);
    float b = gg_randomR(i + float2(1.0, 0.0));
    float c = gg_randomR(i + float2(0.0, 1.0));
    float d = gg_randomR(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    float x1 = mix(a, b, u.x);
    float x2 = mix(c, d, u.x);
    return mix(x1, x2, u.y);
}

static float4 gg_fbmR(float2 n0, float2 n1, float2 n2, float2 n3) {
    float amplitude = 0.2;
    float4 total = float4(0.0);
    for (int i = 0; i < 3; i++) {
        n0 = mg_rotate(n0, 0.3);
        n1 = mg_rotate(n1, 0.3);
        n2 = mg_rotate(n2, 0.3);
        n3 = mg_rotate(n3, 0.3);
        total.x += gg_valueNoiseR(n0) * amplitude;
        total.y += gg_valueNoiseR(n1) * amplitude;
        total.z += gg_valueNoiseR(n2) * amplitude;
        total.z += gg_valueNoiseR(n3) * amplitude;
        n0 *= 1.99;
        n1 *= 1.99;
        n2 *= 1.99;
        n3 *= 1.99;
        amplitude *= 0.6;
    }
    return total;
}

static float2 gg_truchet(float2 uv, float idx) {
    idx = fract((idx - 0.5) * 2.0);
    if (idx > 0.75)
        uv = float2(1.0) - uv;
    else if (idx > 0.5)
        uv = float2(1.0 - uv.x, uv.y);
    else if (idx > 0.25)
        uv = 1.0 - float2(1.0 - uv.x, uv.y);
    return uv;
}

fragment float4 grainGradientFragment(RasterizerData in [[stage_in]],
                                      constant GrainGradientUniforms &u [[buffer(MeshFragmentIndex_Grid)]],
                                      constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]],
                               constant MeshCommonUniforms &cm [[buffer(MeshFragmentIndex_Common)]]) {
    float2 res = max(cm.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with the other types. paper's firstFrameOffset = 7.
    float t = 0.1 * (cm.time * cm.speed + fmod(cm.seed, 10000.0) + 7.0);

    // y-up, origin-shifted normalized UV (0.5,0.5 = centre; y flipped so the OSC
    // drag direction matches). Source gl_FragCoord is bottom-left origin.
    float2 uv = float2(in.textureCoordinate.x, 1.0 - in.textureCoordinate.y);
    uv -= float2(cm.origin.x - 0.5, 0.5 - cm.origin.y);

    // v_objectUV: centred, aspect-correct object coords (~[-.5,.5]) for shapes
    // 4..7. v_patternUV: a tiled pattern coordinate for shapes 1..3.
    float2 vObjectUV = uv - 0.5;
    vObjectUV.x *= aspect;
    // Common Scale (zoom) + Rotation about the centre.
    vObjectUV = mg_rotate(vObjectUV, cm.rotation);
    vObjectUV /= max(cm.scale, float2(0.01));
    float2 vPatternUV = vObjectUV * GG_PATTERN_TILES;

    int shapeType = u.shape;
    float2 shape_uv;
    float2 grain_uv;
    if (shapeType > 3) {
        shape_uv = vObjectUV;
        // paper: grain_uv = v_objectUV * v_objectBoxSize * .7 (box ~ reference).
        grain_uv = vObjectUV * float2(aspect * GG_REF_H, GG_REF_H) * 0.7;
    } else {
        shape_uv = 0.5 * vPatternUV;
        grain_uv = 160.0 * vPatternUV; // paper: 100 * v_patternUV then * 1.6
    }

    float cCount = max((float)u.colorsCount, 1.0);
    float shape = 0.0;

    if (shapeType == 1) {
        // Sine wave
        float wave = cos(0.5 * shape_uv.x - 4.0 * t) * sin(1.5 * shape_uv.x + 2.0 * t) * (0.75 + 0.25 * cos(6.0 * t));
        shape = 1.0 - smoothstep(-1.0, 1.0, shape_uv.y + wave);
    } else if (shapeType == 2) {
        // Grid (dots)
        float stripeIdx = floor(2.0 * shape_uv.x / DTH_TWO_PI);
        float rnd = dth_hash11(stripeIdx * 100.0);
        rnd = sign(rnd - 0.5) * pow(4.0 * abs(rnd), 0.3);
        shape = sin(shape_uv.x) * cos(shape_uv.y - 5.0 * rnd * t);
        shape = pow(abs(shape), 4.0);
    } else if (shapeType == 3) {
        // Truchet pattern
        float n2 = gg_valueNoiseR(shape_uv * 0.4 - 3.75 * t);
        shape_uv.x += 10.0;
        shape_uv *= 0.6;
        float2 tile = gg_truchet(fract(shape_uv), gg_randomR(floor(shape_uv)));
        float distance1 = length(tile);
        float distance2 = length(tile - float2(1.0));
        n2 -= 0.5;
        n2 *= 0.1;
        shape = smoothstep(0.2, 0.55, distance1 + n2) * (1.0 - smoothstep(0.45, 0.8, distance1 - n2));
        shape += smoothstep(0.2, 0.55, distance2 + n2) * (1.0 - smoothstep(0.45, 0.8, distance2 - n2));
        shape = pow(shape, 1.5);
    } else if (shapeType == 4) {
        // Corners
        shape_uv *= 0.6;
        float2 outer = float2(0.5);
        float2 bl =
            smoothstep(float2(0.0), outer, shape_uv + float2(0.1 + 0.1 * sin(3.0 * t), 0.2 - 0.1 * sin(5.25 * t)));
        float2 tr = smoothstep(float2(0.0), outer, 1.0 - shape_uv);
        shape = 1.0 - bl.x * bl.y * tr.x * tr.y;
        shape_uv = -shape_uv;
        bl = smoothstep(float2(0.0), outer, shape_uv + float2(0.1 + 0.1 * sin(3.0 * t), 0.2 - 0.1 * cos(5.25 * t)));
        tr = smoothstep(float2(0.0), outer, 1.0 - shape_uv);
        shape -= bl.x * bl.y * tr.x * tr.y;
        shape = 1.0 - smoothstep(0.0, 1.0, shape);
    } else if (shapeType == 5) {
        // Ripple
        shape_uv *= 2.0;
        float dist = length(0.4 * shape_uv);
        float waves = sin(pow(dist, 1.2) * 5.0 - 3.0 * t) * 0.5 + 0.5;
        shape = waves;
    } else if (shapeType == 6) {
        // Blob
        float tt = t * 2.0;
        float2 f1 = 0.25 * float2(1.3 * sin(tt), 0.2 + 1.3 * cos(0.6 * tt + 4.0));
        float2 f2 = 0.2 * float2(1.2 * sin(-tt), 1.3 * sin(1.6 * tt));
        float2 f3 = 0.25 * float2(1.7 * cos(-0.6 * tt), cos(-1.6 * tt));
        float2 f4 = 0.3 * float2(1.4 * cos(0.8 * tt), 1.2 * sin(-0.6 * tt - 3.0));
        shape = 0.5 * pow(1.0 - clamp(length(shape_uv + f1), 0.0, 1.0), 5.0);
        shape += 0.5 * pow(1.0 - clamp(length(shape_uv + f2), 0.0, 1.0), 5.0);
        shape += 0.5 * pow(1.0 - clamp(length(shape_uv + f3), 0.0, 1.0), 5.0);
        shape += 0.5 * pow(1.0 - clamp(length(shape_uv + f4), 0.0, 1.0), 5.0);
        shape = smoothstep(0.0, 0.9, shape);
        float edge = smoothstep(0.25, 0.3, shape);
        shape = mix(0.0, shape, edge);
    }

    float baseNoise = dth_snoise(grain_uv * 0.5);
    float4 fbmVals =
        gg_fbmR(0.002 * grain_uv + 10.0, 0.003 * grain_uv, 0.001 * grain_uv, mg_rotate(0.4 * grain_uv, 2.0));
    float grainDist = baseNoise * dth_snoise(grain_uv * 0.2) - fbmVals.x - fbmVals.y;
    float rawNoise = 0.75 * baseNoise - fbmVals.w - fbmVals.z;
    float noise = clamp(rawNoise, 0.0, 1.0);

    shape += u.intensity * 2.0 / cCount * (grainDist + 0.5);
    shape += u.noise * 10.0 / cCount * noise;

    float aa = fwidth(shape);
    shape = clamp(shape - 0.5 / cCount, 0.0, 1.0);
    float totalShape = smoothstep(0.0, u.softness + 2.0 * aa, clamp(shape * cCount, 0.0, 1.0));
    float mixer = shape * (cCount - 1.0);

    int cntStop = (int)cCount - 1;
    float4 gradient = u.colors[0];
    gradient.rgb *= gradient.a;
    for (int i = 1; i < KK_GRAIN_GRAD_COLORS; i++) {
        if (i > cntStop)
            break;
        float localT = clamp(mixer - float(i - 1), 0.0, 1.0);
        localT = smoothstep(0.5 - 0.5 * u.softness - aa, 0.5 + 0.5 * u.softness + aa, localT);
        float4 c = u.colors[i];
        c.rgb *= c.a;
        gradient = mix(gradient, c, localT);
    }

    float3 color = gradient.rgb * totalShape;
    float opacity = gradient.a * totalShape;
    float3 bgColor = u.colorBack.rgb * u.colorBack.a;
    color = color + bgColor * (1.0 - opacity);
    opacity = opacity + u.colorBack.a * (1.0 - opacity);

    // Shared core film grain + anti-band dither.
    color = mesh_applyGrain(color, in.clipSpacePosition.xy, cm);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}
