/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#include "ShaderTypes.h"
#include <KeyframelessKit/KKShaderTypes.h>
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} RasterizerData;

vertex RasterizerData vertexShader(uint vertexID [[vertex_id]],
                                   constant KKVertex2D *vertexArray [[buffer(KKVertexInputIndex_Vertices)]],
                                   constant vector_uint2 *viewportSizePointer
                                   [[buffer(KKVertexInputIndex_ViewportSize)]]) {
    RasterizerData out;

    float2 pixelSpacePosition = vertexArray[vertexID].position.xy;
    float2 viewportSize = float2(*viewportSizePointer);

    out.clipSpacePosition.xy = pixelSpacePosition / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;

    return out;
}

// The gradient blends its colours in gamma-sRGB (as the source shader does);
// convert to linear for FCP's float working buffer.
static float3 srgb_to_linear(float3 c) {
    c = clamp(c, 0.0, 1.0);
    float3 hi = pow((c + 0.055) / 1.055, float3(2.4));
    float3 lo = c / 12.92;
    return select(hi, lo, c <= 0.04045);
}

// --- Mesh Gradient: translated (GLSL -> MSL) and modified from the
// mesh-gradient shader in paper-design/shaders (Apache-2.0). See
// THIRD-PARTY-NOTICES.md at the repo root for the licence text + attribution.
// Animated colour spots warped by noise distortion + swirl, blended by
// inverse-distance, with an in-shader grain mixer + overlay. Colours are
// straight sRGB; all maths stay in gamma space (as the source does), then the
// final colour is linearised for FCP's float buffer via the EncodeSRGB path.

static float2 mg_rotate(float2 v, float a) {
    float s = sin(a), c = cos(a);
    return float2(c * v.x + s * v.y, -s * v.x + c * v.y);
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

static float mg_noise(float2 n, float2 seedOffset) { return mg_valueNoise(n + seedOffset); }

static float2 mg_getPosition(int i, float t) {
    float a = float(i) * 0.37;
    float b = 0.6 + fract(float(i) / 3.0) * 0.9;
    float c = 0.8 + fract(float(i + 1) / 4.0);
    float x = sin(t * b + a);
    float y = cos(t * c + a * 1.5);
    return 0.5 + 0.5 * float2(x, y);
}

fragment float4 fragmentShader(RasterizerData in [[stage_in]],
                               constant MeshGradientUniforms &u [[buffer(MeshFragmentIndex_Grid)]],
                               constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]]) {
    float2 grainUV = in.textureCoordinate * 1000.0; // screen-fixed grain
    // Origin shifts the whole field. Matches the OSC drag direction (uv here is
    // y-down, so no y-flip on the origin offset).
    float2 uv = in.textureCoordinate - (u.origin - 0.5);

    float grain = mg_noise(grainUV, float2(0.0));
    float mixerGrain = 0.4 * u.grainMixer * (grain - 0.5);

    // Seed is the initial phase (a "start frame"): it offsets the animation
    // time, so each seed picks a different, coherent point in the endless flow.
    // The source shader's fixed 41.5 offset is just the default seed.
    //
    // Wrap the seed before it enters the trig. A large seed (e.g. 574468) makes
    // the sin/cos phase arguments huge, and float32 can no longer resolve the
    // small per-pixel phase variation in the distortion warp - it quantizes into
    // visible chunky steps. fmod keeps the phase precise while still giving each
    // seed a distinct frame (10000 distinct start points before it repeats).
    const float firstFrameOffset = 41.5;
    float seedFrame = fmod(u.seed, 10000.0);
    float t = 0.5 * (u.time * u.speed + seedFrame + firstFrameOffset);

    float radius = smoothstep(0.0, 1.0, length(uv - 0.5));
    float center = 1.0 - radius;
    for (float i = 1.0; i <= 2.0; i++) {
        uv.x += u.distortion * center / i * sin(t + i * 0.4 * smoothstep(0.0, 1.0, uv.y)) *
                cos(0.2 * t + i * 2.4 * smoothstep(0.0, 1.0, uv.y));
        uv.y += u.distortion * center / i * cos(t + i * 2.0 * smoothstep(0.0, 1.0, uv.x));
    }

    float2 uvRotated = uv - float2(0.5);
    float angle = 3.0 * u.swirl * radius;
    uvRotated = mg_rotate(uvRotated, -angle);
    uvRotated += float2(0.5);

    float3 color = float3(0.0);
    float opacity = 0.0;
    float totalWeight = 0.0;
    int n = clamp(u.colorsCount, 1, KK_MESH_GRAD_COLORS);
    for (int i = 0; i < n; i++) {
        float2 pos = mg_getPosition(i, t) + mixerGrain;
        float3 colorFraction = u.colors[i].rgb * u.colors[i].a;
        float opacityFraction = u.colors[i].a;
        float dist = length(uvRotated - pos);
        dist = pow(dist, 3.5);
        float weight = 1.0 / (dist + 1e-3);
        color += colorFraction * weight;
        opacity += opacityFraction * weight;
        totalWeight += weight;
    }
    color /= max(1e-4, totalWeight);
    opacity /= max(1e-4, totalWeight);

    float grainOverlay = mg_valueNoise(mg_rotate(grainUV, 1.0) + float2(3.0));
    grainOverlay = mix(grainOverlay, mg_valueNoise(mg_rotate(grainUV, 2.0) + float2(-1.0)), 0.5);
    grainOverlay = pow(grainOverlay, 1.3);
    float grainOverlayV = grainOverlay * 2.0 - 1.0;
    float3 grainOverlayColor = float3(step(0.0, grainOverlayV));
    float grainOverlayStrength = u.grainOverlay * abs(grainOverlayV);
    grainOverlayStrength = pow(grainOverlayStrength, 0.8);
    color = mix(color, grainOverlayColor, 0.35 * grainOverlayStrength);
    opacity += 0.5 * grainOverlayStrength;
    opacity = clamp(opacity, 0.0, 1.0);

    // Triangular ordered dither (~1 LSB) to break up 8-bit banding in the very
    // flat regions of the field (the stair-stepping that shows on some frames).
    // Applied in gamma space so it survives into both output paths.
    float dither = (mg_hash21(in.clipSpacePosition.xy) - mg_hash21(in.clipSpacePosition.yx + 7.0)) / 255.0;
    color = clamp(color + dither, 0.0, 1.0);

    // `color` is gamma-sRGB. 8-bit dest wants gamma; FCP float dest wants linear.
    float3 outRGB = encodeSRGB ? color : srgb_to_linear(color);
    return float4(outRGB * opacity, opacity);
}

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
                          float2 origin) {
    float2 pxSizeUV = (fragCoord - 0.5 * refRes) / pxSize;
    float2 canvasPixelizedUV = (floor(pxSizeUV) + 0.5) * pxSize;
    float2 normalizedUV = canvasPixelizedUV / refRes;
    float2 ditheringNoiseUV = canvasPixelizedUV;

    // Origin shifts the shape (normalizedUV is y-up, so flip the origin y to
    // match the OSC drag direction). 0.5,0.5 = centre.
    normalizedUV -= float2(origin.x - 0.5, 0.5 - origin.y);

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
                                  constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]]) {
    float2 res = max(u.resolution, float2(1.0));
    float aspect = res.x / res.y;
    const float refH = 1080.0;
    float2 refRes = float2(aspect * refH, refH); // project reference (aspect only)

    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with Mesh.
    float t = 0.5 * (u.time * u.speed + fmod(u.seed, 10000.0));
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
            cov += dth_evaluate(uvss * refRes, refRes, t, pxSize, u.shape, u.type, u.origin);
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

    // Already premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}
