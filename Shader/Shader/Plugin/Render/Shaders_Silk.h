/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include "ShaderCommon.h"

// --- Silk ("Silk"): ported from radiant-shaders "Silk Cascade" (pbakaus/
// radiant, MIT) GLSL -> MSL. See THIRD-PARTY-NOTICES. Three domain-warped
// fabric-fold layers with Kajiya-Kay anisotropic specular (silk sheen), lit +
// 3-tone shaded and composited back-to-front. The port drops the source's mouse
// light + fixed per-layer palettes (each layer takes ONE dynamic palette hue,
// its dark/mid/bright/sheen tones derived from it) and pulls out Sheen / Folds /
// Drape as controls. Self-contained noise (sc_*) matches the source's hash.

static float sc_hash12(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float sc_vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = sc_hash12(i);
    float b = sc_hash12(i + float2(1.0, 0.0));
    float c = sc_hash12(i + float2(0.0, 1.0));
    float d = sc_hash12(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float sc_fbm3(float2 p) {
    float v = 0.0, a = 0.5;
    float2x2 rot = float2x2(float2(0.8, -0.6), float2(0.6, 0.8));
    for (int i = 0; i < 3; i++) {
        v += a * sc_vnoise(p);
        p = rot * p * 2.0;
        a *= 0.5;
    }
    return v;
}

static float sc_fbm2(float2 p) {
    float v = 0.5 * sc_vnoise(p);
    p = float2x2(float2(0.8, -0.6), float2(0.6, 0.8)) * p * 2.0;
    v += 0.25 * sc_vnoise(p);
    return v;
}

static float2 sc_domainWarp(float2 p, float t, float scale, float seed) {
    return float2(sc_fbm3(p * scale + float2(1.7 + seed, 9.2) + t * 0.15),
                  sc_fbm3(p * scale + float2(8.3, 2.8 + seed) - t * 0.12));
}

static float2 sc_domainWarpLite(float2 p, float t, float scale, float seed) {
    return float2(sc_fbm2(p * scale + float2(1.7 + seed, 9.2) + t * 0.15),
                  sc_fbm2(p * scale + float2(8.3, 2.8 + seed) - t * 0.12));
}

// Per-layer fold: returns (height, gradient.xy). `drape` scales the warp.
static float3 sc_fabricFold(float2 p, float t, float seed, float freq, float flow, float drape, bool lite) {
    float ts = t * flow;
    float2 warp =
        lite ? sc_domainWarpLite(p + seed * 3.7, ts, 1.2, seed) : sc_domainWarp(p + seed * 3.7, ts, 1.2, seed);
    float2 wp = p + warp * 0.55 * drape;
    float h = 0.0;
    float2 g = float2(0.0);

    float f1x = freq * 0.7, f1y = freq * 0.4;
    float ph1 = wp.x * f1x + wp.y * f1y + ts * 0.3 + seed * 2.1;
    h += sin(ph1) * 0.35;
    g += cos(ph1) * 0.35 * float2(f1x, f1y);

    float f2x = -freq * 0.3, f2y = freq * 0.9;
    float ph2 = wp.x * f2x + wp.y * f2y + ts * 0.25 + seed * 1.3;
    h += sin(ph2) * 0.25;
    g += cos(ph2) * 0.25 * float2(f2x, f2y);

    float f3 = freq * 0.6;
    float ph3 = (wp.x + wp.y) * f3 + ts * 0.2 + seed * 4.5;
    h += sin(ph3) * 0.18;
    g += cos(ph3) * 0.18 * float2(f3, f3);

    float f4x = freq * 1.8, f4y = freq * 1.2;
    float ph4 = wp.x * f4x + wp.y * f4y - ts * 0.35 + seed * 0.7;
    h += sin(ph4) * 0.08;
    g += cos(ph4) * 0.08 * float2(f4x, f4y);

    if (!lite)
        h += sc_vnoise(wp * freq * 0.9 + seed * 10.0 + ts * 0.04) * 0.12 - 0.06;
    return float3(h, g);
}

// Kajiya-Kay anisotropic specular.
static float sc_kajiyaSpec(float2 grad, float3 L, float3 V, float shine) {
    float gl2 = dot(grad, grad);
    if (gl2 < 0.0001)
        return 0.0;
    float2 tg = float2(-grad.y, grad.x) / sqrt(gl2);
    float3 T = normalize(float3(tg, 0.0));
    float3 H = normalize(L + V);
    float TdH = dot(T, H);
    return pow(sqrt(max(1.0 - TdH * TdH, 0.0)), shine);
}

// Shade one fabric layer. darkCol/midCol/brightCol/specCol are derived from the
// layer's palette hue.
static float4 sc_shadeLayer(float2 p, float t, float seed, float freq, float flow, float drape, float3 darkCol,
                            float3 midCol, float3 brightCol, float3 specCol, float opacity, float shine, float3 L1,
                            float3 L2, float3 V, float sheenMul) {
    float3 fold = sc_fabricFold(p, t, seed, freq, flow, drape, opacity < 0.35);
    float h = fold.x;
    float2 grad = fold.yz;
    float3 N = normalize(float3(-grad * 1.8, 1.0));

    float NdL1 = max(dot(N, L1), 0.0);
    float NdL2 = max(dot(N, L2), 0.0);
    float lit = NdL1 * 0.75 + NdL2 * 0.12;

    float depth = smoothstep(-0.8, 0.4, h);

    float shade = lit * depth;
    float midBlend = smoothstep(0.0, 0.35, shade);
    float brightBlend = smoothstep(0.25, 0.7, shade);
    float3 fabric = mix(darkCol, midCol, midBlend);
    fabric = mix(fabric, brightCol, brightBlend * 0.5);

    float sp = sc_kajiyaSpec(grad, L1, V, shine) * 0.9;
    sp += sc_kajiyaSpec(grad, L2, V, shine * 0.6) * 0.15;
    sp *= sheenMul;
    float specPow = sp * sp * sp;
    fabric += specCol * specPow * 0.9;

    float trans = smoothstep(0.3, 0.9, depth) * lit * 0.08;
    fabric += float3(0.45, 0.28, 0.15) * trans;

    float alpha = opacity * (0.65 + depth * 0.35);
    return float4(fabric, alpha);
}

fragment float4 silkFragment(RasterizerData in [[stage_in]],
                             constant SilkUniforms &u [[buffer(ShaderFragmentIndex_Grid)]],
                             constant int &encodeSRGB [[buffer(ShaderFragmentIndex_EncodeSRGB)]],
                             constant ShaderCommonUniforms &cm [[buffer(ShaderFragmentIndex_Common)]]) {
    float2 res = max(cm.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the flow phase. 0.4 is the source's default flowSpeed.
    float t = cm.time * 0.4 * cm.speed + fmod(cm.seed, 10000.0);

    // Synthesize the object-box UV (source: (uv-0.5)*vec2(aspect,1)), plus
    // Origin / Scale / Rotation. y up so the lighting direction matches.
    float2 uvn = float2(in.textureCoordinate.x, 1.0 - in.textureCoordinate.y);
    uvn -= float2(cm.origin.x - 0.5, 0.5 - cm.origin.y);
    float2 p = (uvn - 0.5) * float2(aspect, 1.0);
    p = mg_rotate(p, cm.rotation);
    p /= max(cm.scale, float2(0.01));

    // Two moving directional lights (source follows cursor; we keep the drift).
    float3 L1 = normalize(float3(0.4 + sin(t * 0.07) * 0.3, 0.9 + cos(t * 0.09) * 0.15, 0.8));
    float3 L2 = normalize(float3(-0.7 + cos(t * 0.06) * 0.2, -0.3 + sin(t * 0.08) * 0.15, 0.6));
    float3 V = float3(0.0, 0.0, 1.0);

    // Background: dark backdrop with a soft central glow.
    float bgD = length(p);
    float3 col = u.colorBack.rgb * u.colorBack.a;
    col += u.colorBack.rgb * u.colorBack.a * 0.5 * exp(-bgD * bgD * 2.0);

    float folds = u.folds;
    float drape = u.drape;
    float sheen = u.sheen;

    // Derive each layer's dark/mid/bright/sheen tones from one palette hue.
    int cc = max(u.colorsCount, 1);
    float4 h1 = u.colors[0];
    float4 h2 = u.colors[min(1, cc - 1)];
    float4 h3 = u.colors[min(2, cc - 1)];
    float3 c1 = h1.rgb * h1.a, c2 = h2.rgb * h2.a, c3 = h3.rgb * h3.a;

    // Layer 1 (deep, slow, transparent).
    float4 ly1 = sc_shadeLayer(p * 0.8 + float2(0.15, t * 0.015), t, 0.0, 2.0 * folds, 0.5, drape, c1 * 0.14, c1 * 0.55,
                               c1 * 0.95, mix(c1, float3(1.0), 0.72), 0.30, 26.0, L1, L2, V, sheen * 0.7);
    // Layer 2 (middle).
    float4 ly2 = sc_shadeLayer(p * 1.0 + float2(t * 0.012, -0.1), t, 1.0, 3.2 * folds, 0.75, drape, c2 * 0.14,
                               c2 * 0.55, c2 * 0.95, mix(c2, float3(1.0), 0.72), 0.38, 40.0, L1, L2, V, sheen * 0.9);
    // Layer 3 (front, fast, opaque).
    float4 ly3 = sc_shadeLayer(p * 1.2 + float2(-t * 0.008, t * 0.02), t, 2.0, 4.5 * folds, 1.0, drape, c3 * 0.14,
                               c3 * 0.55, c3 * 0.95, mix(c3, float3(1.0), 0.72), 0.50, 55.0, L1, L2, V, sheen);

    // Composite back-to-front with faint inter-layer bleed.
    col = mix(col, ly1.rgb, ly1.a);
    col += c1 * 0.10 * ly1.a * ly2.a;
    col = mix(col, ly2.rgb, ly2.a);
    col += c2 * 0.08 * ly2.a * ly3.a;
    col = mix(col, ly3.rgb, ly3.a);

    float cov = (ly1.a + ly2.a + ly3.a) * 0.333;
    col += c3 * 0.05 * cov;

    // Vignette.
    float vig = 1.0 - smoothstep(0.25, 1.15, length(p * float2(0.85, 1.0)));
    col *= 0.6 + 0.4 * vig;

    // Saturation boost.
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = mix(float3(lum), col, 1.35);

    // ACES tone map.
    col = col * (2.51 * col + 0.03) / (col * (2.43 * col + 0.59) + 0.14);
    col = max(col, float3(0.0));

    float opacity = 1.0;

    // Shared core film grain + anti-band dither.
    col = shader_applyGrain(col, in.clipSpacePosition.xy, cm);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(col, 0.0, 1.0) : srgb_to_linear(col);
    return float4(outRGB, opacity);
}
