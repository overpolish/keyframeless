/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Shared Metal helpers used by every Mirage generator Type: the reference-frame
// synthesis, the noise / hash primitives, and the core film-grain overlay.
// Extracted from Mirage.metal so each Type's shader can rely on one place.

#include "MirageTypes.h"
#include <KeyframelessKit/KKShaderTypes.h>
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} RasterizerData;

// The gradient blends its colours in gamma-sRGB (as the source shader does);
// convert to linear for FCP's float working buffer.
static float3 srgb_to_linear(float3 c) {
    c = clamp(c, 0.0, 1.0);
    float3 hi = pow((c + 0.055) / 1.055, float3(2.4));
    float3 lo = c / 12.92;
    return select(hi, lo, c <= 0.04045);
}

static float2 mg_rotate(float2 v, float a) {
    float s = sin(a), c = cos(a);
    return float2(c * v.x + s * v.y, -s * v.x + c * v.y);
}

// Standard object-space UV shared by the y-up Types: aspect-correct, centred at
// 0, origin-shifted, with the common Rotation + Scale applied about the centre.
// y is flipped so the OSC drag direction matches. Per-Type post-processing
// (tiling, + 0.5, etc.) is applied by the caller. Mirage (y-down), Dithering and
// Grainy build their own frames.
static float2 shader_objectUV(float2 tc, float aspect, constant MirageCommonUniforms &cm) {
    float2 uvn = float2(tc.x, 1.0 - tc.y);
    uvn -= float2(cm.origin.x - 0.5, 0.5 - cm.origin.y);
    float2 c = uvn - 0.5;
    c.x *= aspect;
    c = mg_rotate(c, cm.rotation);
    c /= max(cm.scale, float2(0.01));
    return c;
}

static float mg_hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.164);
    return fract(p.x * p.y);
}

static float mg_valueNoise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = mg_hash21(i);
    float b = mg_hash21(i + float2(1.0, 0.0));
    float c = mg_hash21(i + float2(0.0, 1.0));
    float d = mg_hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    float x1 = mix(a, b, u.x);
    float x2 = mix(c, d, u.x);
    return mix(x1, x2, u.y);
}

static float2 mg_getPosition(int i, float t) {
    float a = float(i) * 0.37;
    float b = 0.6 + fract(float(i) / 3.0) * 0.9;
    float c = 0.8 + fract(float(i + 1) / 4.0);
    float x = sin(t * b + a);
    float y = cos(t * c + a * 1.5);
    return 0.5 + 0.5 * float2(x, y);
}

// One signed grain sample (~[-1, 1]) at grain-space coordinate `guv`.
static float shader_grainSample(float2 guv) {
    float g = mg_valueNoise(mg_rotate(guv, 1.0) + float2(3.0));
    g = mix(g, mg_valueNoise(mg_rotate(guv, 2.0) + float2(-1.0)), 0.5);
    g = pow(g, 1.3);
    return g * 2.0 - 1.0;
}

// Shared core film-grain overlay + a sub-LSB anti-band dither, applied in gamma
// space just before output-encoding by every Type. `fragCoord` is the pixel
// coordinate (RasterizerData.clipSpacePosition.xy is [[position]] = window
// space). `grain` (× the per-Type `grainScale`) is subtle by default so it
// breaks 8-bit banding, and scales up to a stylistic film grain. Static
// (screen-fixed, no drift). Resolution independence is handled OUTSIDE the
// shader: both the FCP render and the mini render at (near) full resolution -
// the mini renders to a reference-res intermediate and downscales - so the
// grain never has to compensate for a low-res target here.
static float3 shader_applyGrain(float3 color, float2 fragCoord, constant MirageCommonUniforms &cm) {
    float amt = max(cm.grain * cm.grainScale, 0.0);
    float2 guv = fragCoord / max(cm.grainSize, 0.25);
    float gv = shader_grainSample(guv);
    float3 grainColor = float3(step(0.0, gv));
    float strength = pow(amt * abs(gv), 0.8);
    color = mix(color, grainColor, 0.35 * strength);
    float dither = (mg_hash21(fragCoord) - mg_hash21(fragCoord.yx + 7.0)) / 255.0;
    return clamp(color + dither, 0.0, 1.0);
}

static float dth_hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

static float dth_hash21(float2 p) {
    p = fract(p * float2(0.3183099, 0.3678794)) + 0.1;
    p += dot(p, p + 19.19);
    return fract(p.x * p.y);
}

static float3 dth_mod289(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }

static float3 dth_permute(float3 x) { return dth_mod289(((x * 34.0) + 1.0) * x); }

static float dth_snoise(float2 v) {
    const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
    float2 i = floor(v + dot(v, C.yy));
    float2 x0 = v - i + dot(i, C.xx);
    float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float4 x12 = x0.xyxy + C.xxzz;
    x12.xy -= i1;
    i = i - floor(i * (1.0 / 289.0)) * 289.0;
    float3 p = dth_permute(dth_permute(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
    float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
    m = m * m;
    m = m * m;
    float3 x = 2.0 * fract(p * C.www) - 1.0;
    float3 h = abs(x) - 0.5;
    float3 ox = floor(x + 0.5);
    float3 a0 = x - ox;
    m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
    float3 g;
    g.x = a0.x * x0.x + h.x * x0.y;
    g.yz = a0.yz * x12.xz + h.yz * x12.yw;
    return 130.0 * dot(m, g);
}
