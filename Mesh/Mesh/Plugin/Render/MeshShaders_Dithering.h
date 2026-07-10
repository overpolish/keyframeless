/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#include "MeshShaderCommon.h"

// --- Dithering: ported from paper-design/shaders (Apache-2.0), GLSL -> MSL.
// A procedural shape (simplex/warp/dots/wave/ripple/swirl/sphere) rendered
// through a random or ordered-Bayer dither into two colours. See
// THIRD-PARTY-NOTICES.md. Pure generator, no input. The FxPlug port drops the
// source's fit/scale/rotation/offset sizing (full-frame, centred).

constant float DTH_TWO_PI = 6.28318530718;

constant int dth_bayer2x2[4] = {0, 2, 3, 1};
constant int dth_bayer4x4[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};
constant int dth_bayer8x8[64] = {0,  32, 8,  40, 2,  34, 10, 42, 48, 16, 56, 24, 50, 18, 58, 26, 12, 44, 4,  36, 14, 46,
                                 6,  38, 60, 28, 52, 20, 62, 30, 54, 22, 3,  35, 11, 43, 1,  33, 9,  41, 51, 19, 59, 27,
                                 49, 17, 57, 25, 15, 47, 7,  39, 13, 45, 5,  37, 63, 31, 55, 23, 61, 29, 53, 21};

static float dth_getSimplexNoise(float2 uv, float t) {
    float noise = 0.5 * dth_snoise(uv - float2(0.0, 0.3 * t));
    noise += 0.5 * dth_snoise(2.0 * uv + float2(0.0, 0.32 * t));
    return noise;
}

static float dth_getBayerValue(float2 uv, int size) {
    int2 pos = int2(fract(uv / float(size)) * float(size));
    int index = pos.y * size + pos.x;
    if (size == 2)
        return float(dth_bayer2x2[index]) / 4.0;
    else if (size == 4)
        return float(dth_bayer4x4[index]) / 16.0;
    else if (size == 8)
        return float(dth_bayer8x8[index]) / 64.0;
    return 0.0;
}

// One dithered sample (0 or 1 = background or ink) at a reference-space
// coordinate. Everything is computed in the fixed reference frame so the dither
// is proportional and identical across render sizes; the fragment supersamples
// this to downscale cleanly for the small viewers.
static float dth_evaluate(float2 fragCoord, float2 refRes, float t, float pxSize, int shapeType, int ditherType,
                          float2 origin, float2 scale, float rotation) {
    float2 pxSizeUV = (fragCoord - 0.5 * refRes) / pxSize;
    float2 canvasPixelizedUV = (floor(pxSizeUV) + 0.5) * pxSize;
    float2 normalizedUV = canvasPixelizedUV / refRes;
    float2 ditheringNoiseUV = canvasPixelizedUV;

    // Origin shifts the shape (normalizedUV is y-up, so flip the origin y to
    // match the OSC drag direction). 0.5,0.5 = centre.
    normalizedUV -= float2(origin.x - 0.5, 0.5 - origin.y);

    // Common Scale (zoom) + Rotation about the centre. normalizedUV is centred
    // near 0, so transform it directly.
    normalizedUV = mg_rotate(normalizedUV, rotation);
    normalizedUV /= max(scale, float2(0.01));

    // Pattern shapes (1..3) in centred ref-pixel space; object shapes (4..6)
    // aspect-scaled.
    float2 shapeUV;
    if (shapeType > 3) {
        float minRef = min(refRes.x, refRes.y);
        shapeUV = normalizedUV * (refRes / minRef);
    } else {
        shapeUV = normalizedUV * refRes + 0.5;
    }

    float shape = 0.0;
    if (shapeType == 1) {
        shapeUV *= 0.001;
        shape = 0.5 + 0.5 * dth_getSimplexNoise(shapeUV, t);
        shape = smoothstep(0.3, 0.9, shape);
    } else if (shapeType == 2) {
        shapeUV *= 0.003;
        for (float i = 1.0; i < 6.0; i++) {
            shapeUV.x += 0.6 / i * cos(i * 2.5 * shapeUV.y + t);
            shapeUV.y += 0.6 / i * cos(i * 1.5 * shapeUV.x + t);
        }
        shape = 0.15 / max(0.001, abs(sin(t - shapeUV.y - shapeUV.x)));
        shape = smoothstep(0.02, 1.0, shape);
    } else if (shapeType == 3) {
        shapeUV *= 0.05;
        float stripeIdx = floor(2.0 * shapeUV.x / DTH_TWO_PI);
        float rnd = dth_hash11(stripeIdx * 10.0);
        rnd = sign(rnd - 0.5) * pow(0.1 + abs(rnd), 0.4);
        shape = sin(shapeUV.x) * cos(shapeUV.y - 5.0 * rnd * t);
        shape = pow(abs(shape), 6.0);
    } else if (shapeType == 4) {
        shapeUV *= 4.0;
        float wave = cos(0.5 * shapeUV.x - 2.0 * t) * sin(1.5 * shapeUV.x + t) * (0.75 + 0.25 * cos(3.0 * t));
        shape = 1.0 - smoothstep(-1.0, 1.0, shapeUV.y + wave);
    } else if (shapeType == 5) {
        float dist = length(shapeUV);
        shape = sin(pow(dist, 1.7) * 7.0 - 3.0 * t) * 0.5 + 0.5;
    } else {
        // Swirl (radial), centred at the Origin.
        float l = length(shapeUV);
        float angle = 6.0 * atan2(shapeUV.y, shapeUV.x) + 4.0 * t;
        float twist = 1.2;
        float offset = 1.0 / pow(max(l, 1e-6), twist) + angle / DTH_TWO_PI;
        float mid = smoothstep(0.0, 1.0, pow(l, twist));
        shape = mix(0.0, fract(offset), mid);
    }

    float dithering = 0.0;
    if (ditherType == 1)
        dithering = step(dth_hash21(ditheringNoiseUV), shape);
    else if (ditherType == 2)
        dithering = dth_getBayerValue(pxSizeUV, 2);
    else if (ditherType == 3)
        dithering = dth_getBayerValue(pxSizeUV, 4);
    else
        dithering = dth_getBayerValue(pxSizeUV, 8);

    dithering -= 0.5;
    return step(0.5, shape + dithering);
}

fragment float4 ditheringFragment(RasterizerData in [[stage_in]],
                                  constant DitheringUniforms &u [[buffer(MeshFragmentIndex_Grid)]],
                                  constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]],
                               constant MeshCommonUniforms &cm [[buffer(MeshFragmentIndex_Common)]]) {
    float2 res = max(cm.resolution, float2(1.0));
    float aspect = res.x / res.y;
    const float refH = 1080.0;
    float2 refRes = float2(aspect * refH, refH); // project reference (aspect only)

    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with Mesh.
    float t = 0.5 * (cm.time * cm.speed + fmod(cm.seed, 10000.0));
    float pxSize = max(u.pxSize, 1.0);

    // The dither is proportional (computed at the fixed reference resolution), so
    // it is identical across viewers. When the render is SMALLER than the
    // reference (mini-viewer, thumbnail) supersample and average, so the
    // proportional dither downscales cleanly instead of aliasing - i.e. the main
    // viewer, just scaled. At project size ss = 1 (crisp 1:1, no cost).
    // Source gl_FragCoord is bottom-left origin (y up); our UV is y-down.
    float2 uvyup = float2(in.textureCoordinate.x, 1.0 - in.textureCoordinate.y);
    int ss = clamp((int)ceil(refRes.y / res.y), 1, 4);
    float cov = 0.0;
    for (int j = 0; j < ss; j++) {
        for (int i = 0; i < ss; i++) {
            float2 sub = (float2(float(i), float(j)) + 0.5) / float(ss) - 0.5;
            float2 uvss = uvyup + sub / res; // offset within this output pixel
            cov += dth_evaluate(uvss * refRes, refRes, t, pxSize, u.shape, u.type, cm.origin, cm.scale, cm.rotation);
        }
    }
    cov /= float(ss * ss); // fractional ink coverage 0..1

    float3 fgColor = u.colorFront.rgb * u.colorFront.a;
    float fgOpacity = u.colorFront.a;
    float3 bgColor = u.colorBack.rgb * u.colorBack.a;
    float bgOpacity = u.colorBack.a;

    float3 color = fgColor * cov;
    float opacity = fgOpacity * cov;
    color += bgColor * (1.0 - opacity);
    opacity += bgOpacity * (1.0 - opacity);

    // Shared core film grain + anti-band dither.
    color = mesh_applyGrain(color, in.clipSpacePosition.xy, cm);

    // Already premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}
