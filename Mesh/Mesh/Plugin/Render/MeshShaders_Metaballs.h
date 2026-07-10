/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include "MeshShaderCommon.h"

// --- Metaballs ("Metaballs"): ported from paper-design/shaders (Apache-2.0),
// GLSL -> MSL. Up to 20 coloured gooey balls roam the centre on noise
// trajectories and merge into smooth organic shapes over a background. See
// THIRD-PARTY-NOTICES. The FxPlug port drops the source's fit/scale/rotation/
// offset sizing (full frame, centred) and replaces the source's noise-texture
// randomiser with the hash-based dth_hash21. The balls' metric stays isotropic
// (aspect-corrected) so they render round.

constant int MB_MAX_BALLS = 20;

// Smooth 1D drift noise (Catmull-Rom through hashed control points). Unlike
// smoothstep value noise, the velocity is continuous and non-zero AT the lattice
// points, so blobs glide through their control points instead of easing to a
// near-stop at each one - the latter reads as a stagger at low Speed.
static float mb_valueNoise(float x) {
    float i = floor(x);
    float f = fract(x);
    float a = dth_hash21(float2(i - 1.0, 0.0));
    float b = dth_hash21(float2(i, 0.0));
    float c = dth_hash21(float2(i + 1.0, 0.0));
    float d = dth_hash21(float2(i + 2.0, 0.0));
    return 0.5 * (2.0 * b + (-a + c) * f + (2.0 * a - 5.0 * b + 4.0 * c - d) * f * f +
                  (-a + 3.0 * b - 3.0 * c + d) * f * f * f);
}

static float mb_ballShape(float2 uv, float2 c, float p) {
    float s = 0.5 * length(uv - c);
    s = 1.0 - clamp(s, 0.0, 1.0);
    s = pow(s, p);
    return s;
}

fragment float4 metaballsFragment(RasterizerData in [[stage_in]],
                                  constant MetaballsUniforms &u [[buffer(MeshFragmentIndex_Grid)]],
                                  constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]],
                                  constant MeshCommonUniforms &cm [[buffer(MeshFragmentIndex_Common)]]) {
    float2 res = max(cm.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Metaballs animates via VALUE NOISE, not trig, so it can't wrap its phase
    // into 0..2pi the way the other types do. A large argument (the shared
    // "0.2 * (time + seed + 2503)" form) loses float32 precision in fract(),
    // quantising the motion into a low-Speed stagger that worsens with Seed.
    // Keep the animated phase small (grows from ~0) and fold Seed in as a
    // BOUNDED offset instead - enough for a distinct start / non-degenerate
    // frame 0 without inflating the argument.
    float tAnim = 0.2 * cm.time * cm.speed;
    float seedOff = fmod(cm.seed, 991.0) * 0.037 + 3.1;

    // Synthesize the object-box UV: aspect-correct (round balls), centred,
    // origin-shifted, common Scale + Rotation applied about the centre. Adding
    // 0.5 lands the box in [0,1] like the source's v_objectUV + .5. (y flipped
    // so the OSC drag direction matches.)
    float2 centered = mesh_objectUV(in.textureCoordinate, aspect, cm);
    float2 shape_uv = centered + 0.5;

    float count = max(1.0, u.ballCount);
    float cCount = max((float)u.colorsCount, 1.0);

    float3 totalColor = float3(0.0);
    float totalShape = 0.0;
    float totalOpacity = 0.0;

    for (int i = 0; i < MB_MAX_BALLS; i++) {
        if (i >= (int)ceil(count))
            break;

        float idxFract = float(i) / float(MB_MAX_BALLS);
        float angle = 6.28318530718 * idxFract;

        float speed = 1.0 - 0.2 * idxFract;
        float noiseX = mb_valueNoise(angle * 10.0 + float(i) + seedOff + tAnim * speed);
        float noiseY = mb_valueNoise(angle * 20.0 + float(i) + seedOff - tAnim * speed);

        float2 pos = float2(0.5) + 1e-4 + 0.9 * (float2(noiseX, noiseY) - 0.5);

        int safeIndex = i % (int)(cCount + 0.5);
        float4 ballColor = u.colors[safeIndex];
        ballColor.rgb *= ballColor.a;

        float sizeFrac = 1.0;
        if (float(i) > floor(count - 1.0))
            sizeFrac *= fract(count);

        float shape = mb_ballShape(shape_uv, pos, 45.0 - 30.0 * u.ballSize * sizeFrac);
        shape *= pow(u.ballSize, 0.2);
        shape = smoothstep(0.0, 1.0, shape);

        totalColor += ballColor.rgb * shape;
        totalShape += shape;
        totalOpacity += ballColor.a * shape;
    }

    totalColor /= max(totalShape, 1e-4);
    totalOpacity /= max(totalShape, 1e-4);

    float edge_width = fwidth(totalShape);
    float finalShape = smoothstep(0.4, 0.4 + edge_width, totalShape);

    float3 color = totalColor * finalShape;
    float opacity = totalOpacity * finalShape;

    float3 bgColor = u.colorBack.rgb * u.colorBack.a;
    color = color + bgColor * (1.0 - opacity);
    opacity = opacity + u.colorBack.a * (1.0 - opacity);

    // Shared core film grain + anti-band dither.
    color = mesh_applyGrain(color, in.clipSpacePosition.xy, cm);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}
