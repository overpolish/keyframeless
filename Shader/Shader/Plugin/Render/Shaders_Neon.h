/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include "ShaderCommon.h"

// --- Neon ("Neon"): ported from radiant-shaders "Neon Drip" (pbakaus/radiant,
// MIT) GLSL -> MSL, then reduced to just the glowing tendril WISPS (the source's
// metaball blobs were dropped by request). The tendril field is layered through
// a 4-stop HDR ramp (glow/surface/inner/core) from the palette and ACES tone-
// mapped over a dark backdrop. The port drops the source's fixed amber palette
// (uses the dynamic Colour N palette) and pulls out Wisps / Strands / Radiance
// as controls. Noise reuses mg_valueNoise / mg_hash21.

static float nd_tendrilField(float2 p, float t, float speed, float strands) {
    // strands scales the spatial frequency (finer, more numerous wisps).
    float2 s = p * strands;
    float n1 = mg_valueNoise(float2(s.x * 6.0, s.y * 2.0 - t * speed * 0.6) + 10.0);
    float n2 = mg_valueNoise(float2(s.x * 12.0 + 3.7, s.y * 4.0 - t * speed * 0.8) + 20.0);
    float n3 = mg_valueNoise(float2(s.x * 3.0 + 7.1, s.y * 1.5 - t * speed * 0.4));
    float tendrils = n1 * 0.5 + n2 * 0.3 + n3 * 0.2;
    tendrils = smoothstep(0.35, 0.65, tendrils);
    tendrils *= smoothstep(0.6, -0.3, p.y);             // fade toward top
    tendrils *= 0.6 + 0.4 * smoothstep(0.0, -0.5, p.y); // stronger at bottom
    return tendrils;
}

static float nd_vignette(float2 uv) {
    float d = length(uv * float2(0.9, 1.0));
    return smoothstep(1.3, 0.4, d);
}

fragment float4 neonFragment(RasterizerData in [[stage_in]],
                             constant NeonUniforms &u [[buffer(ShaderFragmentIndex_Grid)]],
                             constant int &encodeSRGB [[buffer(ShaderFragmentIndex_EncodeSRGB)]],
                               constant ShaderCommonUniforms &cm [[buffer(ShaderFragmentIndex_Common)]]) {
    float2 res = max(cm.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation time (a "start frame"). Speed multiplies the
    // internal rates; 0.5 is the source's default dripSpeed.
    float t = cm.time + fmod(cm.seed, 10000.0);
    float speed = 0.5 * cm.speed;

    // Synthesize the object-box UV: aspect-correct, centred, origin-shifted,
    // Scale + Rotation. y up so the blobs rise (source samples y-up).
    float2 uv = shader_objectUV(in.textureCoordinate, aspect, cm);

    // Background: dark backdrop with a subtle radial falloff.
    float bgDist = length(uv * float2(0.8, 1.0));
    float3 col = u.colorBack.rgb * u.colorBack.a * (1.0 - bgDist * 0.3);
    col = max(col, float3(0.0));

    // Wisp field: just the tendrils (blobs removed). Wisps scales coverage.
    float tendrils = nd_tendrilField(uv, t, speed, u.strands);
    float w = clamp(tendrils * u.wisps * 1.4, 0.0, 2.0);

    // 4-stop ramp across the wisp intensity (thresholds retuned for the tendril
    // 0..~1.4 range, since the high-energy blobs that used to push it are gone).
    float outerGlow = smoothstep(0.04, 0.30, w);
    float surface = smoothstep(0.20, 0.52, w);
    float inner = smoothstep(0.45, 0.85, w);
    float core = smoothstep(0.85, 1.30, w);

    // HDR palette ramp: the source's amber layering, but any palette. The gains
    // (1.2 / 2.5 / 3.5 / 5.0) rebuild its brightness ramp for the ACES bloom.
    int cc = max(u.colorsCount, 1);
    float4 sc0 = u.colors[0];
    float4 sc1 = u.colors[min(1, cc - 1)];
    float4 sc2 = u.colors[min(2, cc - 1)];
    float4 sc3 = u.colors[min(3, cc - 1)];
    float rad = u.radiance;
    float3 glowColor = sc0.rgb * sc0.a * 1.2 * rad;
    float3 surfaceColor = sc1.rgb * sc1.a * 2.5 * rad;
    float3 innerColor = sc2.rgb * sc2.a * 3.5 * rad;
    float3 coreColor = sc3.rgb * sc3.a * 5.0 * rad;

    float3 wispCol = glowColor * outerGlow;
    wispCol = mix(wispCol, surfaceColor, surface * 0.95);
    wispCol = mix(wispCol, innerColor, inner * 0.95);
    wispCol = mix(wispCol, coreColor, core);
    float edgeBand = surface * (1.0 - inner); // rim lighting along the strands
    wispCol += surfaceColor * 0.4 * edgeBand;
    col += wispCol;

    // Ambient upward-flowing noise (subtle background movement).
    float ambientFlow = mg_valueNoise(float2(uv.x * 3.0, uv.y * 1.5 - t * speed * 0.2) + 50.0);
    ambientFlow = smoothstep(0.4, 0.6, ambientFlow) * 0.06;
    col += glowColor * 0.15 * ambientFlow;

    // Film grain (animated).
    float grain = (mg_hash21(in.clipSpacePosition.xy + fract(t * 43.758) * 1000.0) - 0.5) * 0.025;
    col += grain;

    // Vignette.
    col *= nd_vignette(uv);

    // ACES filmic tone map (keeps the bright neon punch).
    col = max(col, float3(0.0));
    col = col * (2.51 * col + 0.03) / (col * (2.43 * col + 0.59) + 0.14);
    col = pow(max(col, 0.0), float3(0.90));

    float opacity = 1.0;

    // Shared core film grain + anti-band dither.
    col = shader_applyGrain(col, in.clipSpacePosition.xy, cm);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(col, 0.0, 1.0) : srgb_to_linear(col);
    return float4(outRGB, opacity);
}
