/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include "MeshShaderCommon.h"

// --- Strata ("Strata"): ported from radiant-shaders "Painted Strata" (pbakaus/
// radiant, MIT) GLSL -> MSL. See THIRD-PARTY-NOTICES. Stacked geological strata
// with wavy folded boundaries, a tectonic domain warp, per-layer palette colour
// and washi-paper grain. The port drops the source's mouse parallax + fixed
// earth-tone palette (each layer hashes to a dynamic Colour N swatch) and its
// unused sparkle / fault code, and pulls out Layers / Tectonics / Texture as
// controls. Self-contained noise (ps_*).

static float ps_hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

static float ps_hash21(float2 p) {
    float3 p3 = fract(float3(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float ps_vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = ps_hash21(i);
    float b = ps_hash21(i + float2(1.0, 0.0));
    float c = ps_hash21(i + float2(0.0, 1.0));
    float d = ps_hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float ps_fbm(float2 p) {
    float v = 0.0, a = 0.5;
    float2 shift = float2(100.0);
    float2x2 rot = float2x2(float2(cos(0.5), sin(0.5)), float2(-sin(0.5), cos(0.5)));
    for (int i = 0; i < 5; i++) {
        v += a * ps_vnoise(p);
        p = rot * p * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

static float2 ps_tectonicWarp(float2 uv, float t, float tect) {
    float slow = t * 0.15;
    float warpX = ps_fbm(uv * 1.5 + float2(slow * 0.7, slow * 0.3)) - 0.5;
    float warpY = ps_fbm(uv * 1.5 + float2(slow * 0.5 + 50.0, slow * 0.8 + 30.0)) - 0.5;
    float compress = sin(uv.x * 2.0 + slow * 0.4) * 0.08;
    float shear = sin(uv.y * 3.0 + slow * 0.6) * 0.06;
    return float2(uv.x + (warpX * 0.25 + shear) * tect, uv.y + (warpY * 0.18 + compress) * tect);
}

static float ps_layerBoundary(float x, float baseY, float idx, float t, float tect) {
    float h1 = ps_hash11(idx * 7.13);
    float h2 = ps_hash11(idx * 13.37);
    float h3 = ps_hash11(idx * 23.71);
    float freq1 = 1.5 + h1 * 2.5;
    float freq2 = 3.0 + h2 * 3.0;
    float amp1 = (0.04 + h1 * 0.06) * tect;
    float amp2 = (0.015 + h2 * 0.025) * tect;
    float phase1 = t * (0.1 + h3 * 0.15);
    float phase2 = t * (0.08 + h1 * 0.12);
    float fold = amp1 * sin(x * freq1 + phase1 + h2 * 6.28);
    fold += amp2 * sin(x * freq2 + phase2 + h3 * 6.28);
    fold += 0.02 * tect * ps_vnoise(float2(x * 4.0 + h1 * 100.0, t * 0.2 + idx));
    return baseY + fold;
}

static float ps_grainTexture(float2 uv, float layerIdx) {
    float h = ps_hash11(layerIdx * 41.93);
    float fiberAngle = h * 3.14 * 0.3;
    float ca = cos(fiberAngle), sa = sin(fiberAngle);
    float2 rotUV = float2(uv.x * ca - uv.y * sa, uv.x * sa + uv.y * ca);
    float fiber1 = ps_vnoise(float2(rotUV.x * 120.0, rotUV.y * 18.0) + layerIdx * 30.0);
    float fiber2 = ps_vnoise(float2(rotUV.x * 80.0, rotUV.y * 12.0) + layerIdx * 50.0 + 100.0);
    float intensity = fiber1 * 0.08 + fiber2 * 0.05;
    float crossf = ps_vnoise(float2(rotUV.x * 15.0, rotUV.y * 70.0) + layerIdx * 40.0);
    intensity += crossf * 0.03;
    intensity += ps_vnoise(uv * 50.0 + layerIdx * 25.0) * 0.025;
    return intensity - 0.04;
}

constant int PS_MAX_LAYERS = 24;

fragment float4 strataFragment(RasterizerData in [[stage_in]],
                               constant StrataUniforms &u [[buffer(MeshFragmentIndex_Grid)]],
                               constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]],
                               constant MeshCommonUniforms &cm [[buffer(MeshFragmentIndex_Common)]]) {
    float2 res = max(cm.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation time. 0.5 is the source's default foldSpeed.
    float t = cm.time * 0.5 * cm.speed + fmod(cm.seed, 10000.0);

    // Synthesize the coordinate: y-up (layers stack up the frame), Rotation +
    // Scale about the centre, then Origin shift. Layer logic runs in ~[0,1].
    float2 uvn = float2(in.textureCoordinate.x, 1.0 - in.textureCoordinate.y);
    float2 cc = uvn - 0.5;
    cc = mg_rotate(cc, cm.rotation);
    cc /= max(cm.scale, float2(0.01));
    float2 uv = cc + 0.5;
    uv -= float2(cm.origin.x - 0.5, cm.origin.y - 0.5);

    float2 uvAspect = float2(uv.x * aspect, uv.y);
    float tect = u.tectonics;
    float layerCount = max(floor(u.layers), 1.0);

    float2 warped = ps_tectonicWarp(uvAspect, t, tect);

    // Find which layer this pixel is in.
    float layerSpacing = 1.0 / (layerCount + 1.0);
    float currentLayer = -1.0;
    float layerPos = 0.0;
    float prevBound = -0.2;
    for (int i = 0; i < PS_MAX_LAYERS; i++) {
        if (float(i) >= layerCount)
            break;
        float fi = float(i);
        float baseY = (fi + 1.0) * layerSpacing;
        float bound = ps_layerBoundary(warped.x, baseY, fi, t, tect);
        if (warped.y >= prevBound && warped.y < bound) {
            currentLayer = fi;
            float thickness = bound - prevBound;
            layerPos = (warped.y - prevBound) / max(thickness, 0.001);
            break;
        }
        prevBound = bound;
    }
    if (currentLayer < 0.0) {
        currentLayer = layerCount;
        layerPos = 0.5;
    }

    // Stratum colour: hash the layer index to a palette swatch (+ tiny per-layer
    // brightness variation).
    int cc2 = max(u.colorsCount, 1);
    float hpick = ps_hash11(currentLayer * 17.31 + 3.7);
    int ci = (int)fmod(floor(hpick * (float)cc2), (float)cc2);
    float4 sw = u.colors[ci];
    float3 col = sw.rgb * sw.a;
    float h2 = ps_hash11(currentLayer * 31.17);
    col += (h2 - 0.5) * 0.06;

    // Paper grain.
    col += ps_grainTexture(warped, currentLayer) * u.texture;

    // Boundary shading: darker at edges, lighter in the middle.
    float edgeShade = smoothstep(0.0, 0.15, layerPos) * smoothstep(1.0, 0.85, layerPos);
    col *= 0.85 + 0.15 * edgeShade;
    float edgeShadow = smoothstep(0.0, 0.08, layerPos);
    col *= 0.82 + 0.18 * edgeShadow;
    float topHighlight = smoothstep(1.0, 0.92, layerPos);
    col += float3(0.04, 0.035, 0.025) * (1.0 - topHighlight);

    // Vignette.
    float vig = 1.0 - 0.3 * length((uv - 0.5) * 1.5);
    col *= vig;

    // Overall paper texture overlay.
    float paperTex = ps_vnoise(in.clipSpacePosition.xy * 0.15) * 0.03 * u.texture;
    paperTex += (ps_hash21(in.clipSpacePosition.xy + fract(t * 0.1) * 1000.0) - 0.5) * 0.015 * u.texture;
    col += paperTex;

    // Slight desaturation for a dyed-paper feel.
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    col = mix(float3(lum), col, 0.82);

    float opacity = 1.0;

    // Shared core film grain + anti-band dither.
    col = mesh_applyGrain(col, in.clipSpacePosition.xy, cm);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(col, 0.0, 1.0) : srgb_to_linear(col);
    return float4(outRGB, opacity);
}
