/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include "MeshShaderCommon.h"

// --- Fluid ("Fluid"): ported from radiant-shaders "Fluid Amber" (pbakaus/
// radiant, MIT) GLSL -> MSL. See THIRD-PARTY-NOTICES. Iterative IQ domain warp
// (fbm feeding fbm feeding fbm); the field magnitudes composite the palette
// swatches in layers for a molten, marbled flow. The port drops the source's
// mouse swirl + fixed amber palette (uses the dynamic Colour N palette instead)
// and its full-frame sizing (synthesises the reference frame). snoise reuses
// the Dithering port's dth_snoise.

static float fl_hash13(float3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

// 3D value noise (trilinear hash), returned in ~[-1, 1].
static float fl_vnoise3(float3 x) {
    float3 i = floor(x);
    float3 f = fract(x);
    float3 u = f * f * (3.0 - 2.0 * f);
    float n000 = fl_hash13(i + float3(0.0, 0.0, 0.0));
    float n100 = fl_hash13(i + float3(1.0, 0.0, 0.0));
    float n010 = fl_hash13(i + float3(0.0, 1.0, 0.0));
    float n110 = fl_hash13(i + float3(1.0, 1.0, 0.0));
    float n001 = fl_hash13(i + float3(0.0, 0.0, 1.0));
    float n101 = fl_hash13(i + float3(1.0, 0.0, 1.0));
    float n011 = fl_hash13(i + float3(0.0, 1.0, 1.0));
    float n111 = fl_hash13(i + float3(1.0, 1.0, 1.0));
    float nx00 = mix(n000, n100, u.x);
    float nx10 = mix(n010, n110, u.x);
    float nx01 = mix(n001, n101, u.x);
    float nx11 = mix(n011, n111, u.x);
    float nxy0 = mix(nx00, nx10, u.y);
    float nxy1 = mix(nx01, nx11, u.y);
    return mix(nxy0, nxy1, u.z) * 2.0 - 1.0;
}

// fbm over 3D noise. z carries TIME, so features evolve in place (fade in/out)
// instead of the whole field sliding. xy is rotated per octave to hide the grid
// axes of value noise; z is only offset (not frequency-scaled) so every octave
// evolves at a coherent temporal rate.
static float fa_fbm(float3 p, float ampDecay) {
    float val = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 5; i++) {
        val += amp * fl_vnoise3(p);
        float2 rp = mg_rotate(p.xy, 0.7) * 2.03 + float2(1.7, 9.2);
        p = float3(rp, p.z + 2.3);
        amp *= ampDecay;
    }
    return val;
}

fragment float4 fluidFragment(RasterizerData in [[stage_in]],
                              constant FluidUniforms &u [[buffer(MeshFragmentIndex_Grid)]],
                              constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]],
                               constant MeshCommonUniforms &cm [[buffer(MeshFragmentIndex_Common)]]) {
    float2 res = max(cm.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation TIME (a "start frame"), wrapped so the hash
    // stays precise. Speed multiplies. Time enters as the 3rd noise dimension
    // (z below), so the field evolves in place instead of sliding.
    float t = 0.3 * (cm.time * cm.speed + fmod(cm.seed, 10000.0));

    // Synthesize the object-box UV: aspect-correct, centred at 0, origin-
    // shifted, common Scale + Rotation. (y flipped so OSC drag matches.)
    float2 p = mesh_objectUV(in.textureCoordinate, aspect, cm);

    float decay = clamp(u.detail, 0.0, 1.0);
    float marble = u.marble; // domain-warp strength (0 = smooth, 1 = source)
    // Domain warp with time as the z dimension: each layer boils in place, and
    // slightly different z-rates keep the layers decorrelated.
    float2 q = float2(fa_fbm(float3(p, t), decay), fa_fbm(float3(p + float2(5.2, 1.3), t), decay));
    float2 r = float2(fa_fbm(float3(p + 4.0 * marble * q + float2(1.7, 9.2), t * 1.1), decay),
                      fa_fbm(float3(p + 4.0 * marble * q + float2(8.3, 2.8), t * 1.1), decay));
    float f = fa_fbm(float3(p + 3.5 * marble * r, t * 0.9), decay);

    // Composite the palette in layers (mirrors the source's amber layering, but
    // any palette). Fewer colours clamp to the last swatch.
    int cc = max(u.colorsCount, 1);
    float4 s0 = u.colors[0];
    float4 s1 = u.colors[min(1, cc - 1)];
    float4 s2 = u.colors[min(2, cc - 1)];
    float4 s3 = u.colors[min(3, cc - 1)];
    float3 c0 = s0.rgb * s0.a;
    float3 c1 = s1.rgb * s1.a;
    float3 c2 = s2.rgb * s2.a;
    float3 c3 = s3.rgb * s3.a;

    float vib = u.vibrance; // colour-layer separation (1 = source)
    float3 col = mix(c0, c1, clamp(f * f * 2.0 * vib, 0.0, 1.0));
    col = mix(col, c2, clamp(length(q) * 0.5 * vib, 0.0, 1.0));
    col = mix(col, c3, clamp(abs(r.x) * 0.6 * vib, 0.0, 1.0));

    float highlight = smoothstep(0.5, 1.2, f * f * 3.0 + length(r) * 0.5);
    col += c3 * 0.35 * highlight; // palette-tinted glow (source adds a warm additive)

    col = pow(max(col, 0.0), float3(1.1));

    float opacity = 1.0;

    // Shared core film grain + anti-band dither.
    col = mesh_applyGrain(col, in.clipSpacePosition.xy, cm);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(col, 0.0, 1.0) : srgb_to_linear(col);
    return float4(outRGB, opacity);
}
