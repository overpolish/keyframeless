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
    // Common Scale (zoom) + Rotation transform the field about its centre. This
    // shader samples in y-down UV (no y-flip), so negate the rotation to match
    // the other (y-up) types' direction.
    {
        float2 c = uv - 0.5;
        c = mg_rotate(c, -u.rotation);
        c /= max(u.scale, float2(0.01));
        uv = c + 0.5;
    }

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
            cov += dth_evaluate(uvss * refRes, refRes, t, pxSize, u.shape, u.type, u.origin, u.scale, u.rotation);
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
                                      constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]]) {
    float2 res = max(u.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with the other types. paper's firstFrameOffset = 7.
    float t = 0.1 * (u.time * u.speed + fmod(u.seed, 10000.0) + 7.0);

    // y-up, origin-shifted normalized UV (0.5,0.5 = centre; y flipped so the OSC
    // drag direction matches). Source gl_FragCoord is bottom-left origin.
    float2 uv = float2(in.textureCoordinate.x, 1.0 - in.textureCoordinate.y);
    uv -= float2(u.origin.x - 0.5, 0.5 - u.origin.y);

    // v_objectUV: centred, aspect-correct object coords (~[-.5,.5]) for shapes
    // 4..7. v_patternUV: a tiled pattern coordinate for shapes 1..3.
    float2 vObjectUV = uv - 0.5;
    vObjectUV.x *= aspect;
    // Common Scale (zoom) + Rotation about the centre.
    vObjectUV = mg_rotate(vObjectUV, u.rotation);
    vObjectUV /= max(u.scale, float2(0.01));
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

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}

// --- Warp: ported from paper-design/shaders (Apache-2.0), GLSL -> MSL. Animated
// colour fields warped by noise + iterative swirl over a base pattern (checks /
// stripes / edge), blending up to 10 colours by a distribution/softness ramp.
// See THIRD-PARTY-NOTICES. The FxPlug port drops the source's fit/scale/rotation/
// offset sizing (full frame, centred), synthesising v_patternUV in a resolution-
// independent reference frame so all viewers show the same scene. valueNoise's
// texture randomiser is replaced by the Dithering port's procedural hash.

// Pattern tiling density. Tunable: higher = more repeats.
constant float WARP_PATTERN_TILES = 4.0;
constant float WARP_TWO_PI = 6.28318530718;

// paper samples a noise texture (textureRandomizerG); substitute a procedural
// hash on the integer cell so the port stays self-contained.
static float warp_randomG(float2 p) { return dth_hash21(p); }

static float warp_valueNoise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = warp_randomG(i);
    float b = warp_randomG(i + float2(1.0, 0.0));
    float c = warp_randomG(i + float2(0.0, 1.0));
    float d = warp_randomG(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fragment float4 warpFragment(RasterizerData in [[stage_in]],
                             constant WarpUniforms &u [[buffer(MeshFragmentIndex_Grid)]],
                             constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]]) {
    float2 res = max(u.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with the other types. paper's firstFrameOffset = 118.
    float t = 0.0625 * (u.time * u.speed + fmod(u.seed, 10000.0) + 118.0);

    // Synthesize v_patternUV: aspect-correct, centred, origin-shifted, tiled.
    // (y flipped so the OSC drag direction matches; 0.5,0.5 = centre.)
    float2 uvn = float2(in.textureCoordinate.x, 1.0 - in.textureCoordinate.y);
    uvn -= float2(u.origin.x - 0.5, 0.5 - u.origin.y);
    float2 vPatternUV = uvn - 0.5;
    vPatternUV.x *= aspect;
    // Common Scale (zoom) + Rotation about the centre.
    vPatternUV = mg_rotate(vPatternUV, u.rotation);
    vPatternUV /= max(u.scale, float2(0.01));
    vPatternUV *= WARP_PATTERN_TILES;

    float2 uv = vPatternUV;
    uv *= 0.5;

    float n1 = warp_valueNoise(uv * 1.0 + t);
    float n2 = warp_valueNoise(uv * 2.0 - t);
    float angle = n1 * WARP_TWO_PI;
    uv.x += 4.0 * u.distortion * n2 * cos(angle);
    uv.y += 4.0 * u.distortion * n2 * sin(angle);

    float swirl = u.swirl;
    for (int i = 1; i <= 20; i++) {
        if (i >= (int)u.swirlIterations)
            break;
        float iFloat = float(i);
        uv.x += swirl / iFloat * cos(t + iFloat * 1.5 * uv.y);
        uv.y += swirl / iFloat * cos(t + iFloat * 1.0 * uv.x);
    }

    float proportion = clamp(u.proportion, 0.0, 1.0);
    float cCount = max((float)u.colorsCount, 1.0);

    float shape = 0.0;
    if (u.shape == 0) {
        // Checks
        float2 s = uv * (0.5 + 3.5 * u.shapeScale);
        shape = 0.5 + 0.5 * sin(s.x) * cos(s.y);
        shape += 0.48 * sign(proportion - 0.5) * pow(abs(proportion - 0.5), 0.5);
    } else if (u.shape == 1) {
        // Stripes
        float2 s = uv * (2.0 * u.shapeScale);
        float f = fract(s.y);
        shape = smoothstep(0.0, 0.55, f) * (1.0 - smoothstep(0.45, 1.0, f));
        shape += 0.48 * sign(proportion - 0.5) * pow(abs(proportion - 0.5), 0.5);
    } else {
        // Edge
        float shapeScaling = 5.0 * (1.0 - u.shapeScale);
        float e0 = 0.45 - shapeScaling;
        float e1 = 0.55 + shapeScaling;
        shape = smoothstep(min(e0, e1), max(e0, e1), 1.0 - uv.y + 0.3 * (proportion - 0.5));
    }

    float mixer = shape * (cCount - 1.0);
    float4 gradient = u.colors[0];
    gradient.rgb *= gradient.a;
    float aa = fwidth(shape);
    for (int i = 1; i < KK_MESH_GRAD_COLORS; i++) {
        if (i >= (int)cCount)
            break;
        float m = clamp(mixer - float(i - 1), 0.0, 1.0);
        float localMixerStart = floor(m);
        float softness = 0.5 * u.softness + fwidth(m);
        float smoothed = smoothstep(max(0.0, 0.5 - softness - aa), min(1.0, 0.5 + softness + aa), m - localMixerStart);
        float stepped = localMixerStart + smoothed;
        m = mix(stepped, m, u.softness);
        float4 c = u.colors[i];
        c.rgb *= c.a;
        gradient = mix(gradient, c, m);
    }

    float3 color = gradient.rgb;
    float opacity = gradient.a;

    // colorBandingFix (paper): tiny ordered dither. gl_FragCoord = the fragment
    // pixel coordinate = clipSpacePosition.xy.
    color +=
        1.0 / 256.0 * (fract(sin(dot(0.014 * in.clipSpacePosition.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}

// --- Neuro Noise ("Neuro"): ported from paper-design/shaders (Apache-2.0),
// GLSL -> MSL. A glowing web-like structure of accumulated rotated sine layers
// (zozuar's algorithm) blended between a mid + front colour over a background.
// See THIRD-PARTY-NOTICES. The FxPlug port drops the source's fit/scale/
// rotation/offset sizing (full frame, centred), synthesising v_patternUV in a
// resolution-independent reference frame so all viewers show the same scene.
// rotate reuses mg_rotate.

constant float NEURO_PATTERN_TILES = 10.0;

static float neuro_shape(float2 uv, float t) {
    float2 sine_acc = float2(0.0);
    float2 res = float2(0.0);
    float scale = 8.0;
    for (int j = 0; j < 15; j++) {
        uv = mg_rotate(uv, 1.0);
        sine_acc = mg_rotate(sine_acc, 1.0);
        float2 layer = uv * scale + float(j) + sine_acc - t;
        sine_acc += sin(layer);
        res += (0.5 + 0.5 * cos(layer)) / scale;
        scale *= 1.2;
    }
    return res.x + res.y;
}

fragment float4 neuroNoiseFragment(RasterizerData in [[stage_in]],
                                   constant NeuroNoiseUniforms &u [[buffer(MeshFragmentIndex_Grid)]],
                                   constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]]) {
    float2 res = max(u.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with the other types.
    float t = 0.5 * (u.time * u.speed + fmod(u.seed, 10000.0));

    // Synthesize v_patternUV: aspect-correct, centred, origin-shifted, common
    // Scale + Rotation applied about the centre, then tiled. (y flipped so the
    // OSC drag direction matches.)
    float2 uvn = float2(in.textureCoordinate.x, 1.0 - in.textureCoordinate.y);
    uvn -= float2(u.origin.x - 0.5, 0.5 - u.origin.y);
    float2 vPatternUV = uvn - 0.5;
    vPatternUV.x *= aspect;
    vPatternUV = mg_rotate(vPatternUV, u.rotation);
    vPatternUV /= max(u.scale, float2(0.01));
    vPatternUV *= NEURO_PATTERN_TILES;

    float2 shape_uv = vPatternUV * 0.13;
    float noise = neuro_shape(shape_uv, t);
    noise = (1.0 + u.brightness) * noise * noise;
    noise = pow(noise, 0.7 + 6.0 * u.contrast);
    noise = min(1.4, noise);
    float blend = smoothstep(0.7, 1.4, noise);

    float4 frontC = u.colorFront;
    frontC.rgb *= frontC.a;
    float4 midC = u.colorMid;
    midC.rgb *= midC.a;
    float4 blendFront = mix(midC, frontC, blend);

    float safeNoise = max(noise, 0.0);
    float3 color = blendFront.rgb * safeNoise;
    float opacity = clamp(blendFront.a * safeNoise, 0.0, 1.0);
    float3 bgColor = u.colorBack.rgb * u.colorBack.a;
    color = color + bgColor * (1.0 - opacity);
    opacity = opacity + u.colorBack.a * (1.0 - opacity);

    // colorBandingFix (paper): tiny ordered dither. gl_FragCoord = the fragment
    // pixel coordinate = clipSpacePosition.xy.
    color +=
        1.0 / 256.0 * (fract(sin(dot(0.014 * in.clipSpacePosition.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}

// --- Metaballs ("Metaballs"): ported from paper-design/shaders (Apache-2.0),
// GLSL -> MSL. Up to 20 coloured gooey balls roam the centre on noise
// trajectories and merge into smooth organic shapes over a background. See
// THIRD-PARTY-NOTICES. The FxPlug port drops the source's fit/scale/rotation/
// offset sizing (full frame, centred) and replaces the source's noise-texture
// randomiser with the hash-based dth_hash21. The balls' metric stays isotropic
// (aspect-corrected) so they render round.

constant int MB_MAX_BALLS = 20;

static float mb_valueNoise(float x) {
    float i = floor(x);
    float f = fract(x);
    float u = f * f * (3.0 - 2.0 * f);
    return mix(dth_hash21(float2(i, 0.0)), dth_hash21(float2(i + 1.0, 0.0)), u);
}

static float mb_ballShape(float2 uv, float2 c, float p) {
    float s = 0.5 * length(uv - c);
    s = 1.0 - clamp(s, 0.0, 1.0);
    s = pow(s, p);
    return s;
}

fragment float4 metaballsFragment(RasterizerData in [[stage_in]],
                                  constant MetaballsUniforms &u [[buffer(MeshFragmentIndex_Grid)]],
                                  constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]]) {
    float2 res = max(u.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // firstFrameOffset (paper) shifts the noise so frame 0 isn't degenerate;
    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with the other types.
    float t = 0.2 * (u.time * u.speed + fmod(u.seed, 10000.0) + 2503.4);

    // Synthesize the object-box UV: aspect-correct (round balls), centred,
    // origin-shifted, common Scale + Rotation applied about the centre. Adding
    // 0.5 lands the box in [0,1] like the source's v_objectUV + .5. (y flipped
    // so the OSC drag direction matches.)
    float2 uvn = float2(in.textureCoordinate.x, 1.0 - in.textureCoordinate.y);
    uvn -= float2(u.origin.x - 0.5, 0.5 - u.origin.y);
    float2 centered = uvn - 0.5;
    centered.x *= aspect;
    centered = mg_rotate(centered, u.rotation);
    centered /= max(u.scale, float2(0.01));
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
        float noiseX = mb_valueNoise(angle * 10.0 + float(i) + t * speed);
        float noiseY = mb_valueNoise(angle * 20.0 + float(i) - t * speed);

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

    // colorBandingFix (paper): tiny ordered dither.
    color +=
        1.0 / 256.0 * (fract(sin(dot(0.014 * in.clipSpacePosition.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}

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
                                     constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]]) {
    float2 res = max(u.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with the other types.
    float t = 0.2 * (u.time * u.speed + fmod(u.seed, 10000.0));

    // Synthesize v_patternUV: aspect-correct, centred, origin-shifted, common
    // Scale + Rotation applied about the centre, then tiled. (y flipped so the
    // OSC drag direction matches.)
    float2 uvn = float2(in.textureCoordinate.x, 1.0 - in.textureCoordinate.y);
    uvn -= float2(u.origin.x - 0.5, 0.5 - u.origin.y);
    float2 vPatternUV = uvn - 0.5;
    vPatternUV.x *= aspect;
    vPatternUV = mg_rotate(vPatternUV, u.rotation);
    vPatternUV /= max(u.scale, float2(0.01));
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

    // colorBandingFix (paper): tiny ordered dither. gl_FragCoord = the fragment
    // pixel coordinate = clipSpacePosition.xy.
    color +=
        1.0 / 256.0 * (fract(sin(dot(0.014 * in.clipSpacePosition.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}

// --- God Rays ("God Rays"): ported from paper-design/shaders (Apache-2.0),
// GLSL -> MSL. Animated rays of light radiating from the centre, blended
// through up to 5 ray colours over a background, with a central glow and a
// bloom overlay. See THIRD-PARTY-NOTICES. The FxPlug port drops the source's
// fit/scale/rotation/offset sizing (full frame, centred) and replaces the
// source's noise-texture randomiser with the hash-based dth_hash21. The rays'
// metric stays isotropic (aspect-corrected) so they radiate round.

constant int GR_MAX_COLORS = 5;

static float gr_valueNoise(float2 st) {
    float2 i = floor(st);
    float2 f = fract(st);
    float a = dth_hash21(i);
    float b = dth_hash21(i + float2(1.0, 0.0));
    float c = dth_hash21(i + float2(0.0, 1.0));
    float d = dth_hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float gr_raysShape(float2 uv, float r, float freq, float intensity) {
    float a = atan2(uv.y, uv.x);
    float2 left = float2(a * freq, r);
    float2 right = float2(fract(a / 6.28318530718) * 6.28318530718 * freq, r);
    float n_left = pow(gr_valueNoise(left), intensity);
    float n_right = pow(gr_valueNoise(right), intensity);
    return mix(n_right, n_left, smoothstep(-0.15, 0.15, uv.x));
}

fragment float4 godRaysFragment(RasterizerData in [[stage_in]],
                                constant GodRaysUniforms &u [[buffer(MeshFragmentIndex_Grid)]],
                                constant int &encodeSRGB [[buffer(MeshFragmentIndex_EncodeSRGB)]]) {
    float2 res = max(u.resolution, float2(1.0));
    float aspect = res.x / res.y;

    // Seed offsets the animation time (a "start frame"), wrapped so the trig
    // stays precise. Shared with the other types.
    float t = 0.2 * (u.time * u.speed + fmod(u.seed, 10000.0));

    // Synthesize the object-box UV: aspect-correct (round rays), centred at 0,
    // origin-shifted, common Scale + Rotation applied about the centre. (y
    // flipped so the OSC drag direction matches.)
    float2 uvn = float2(in.textureCoordinate.x, 1.0 - in.textureCoordinate.y);
    uvn -= float2(u.origin.x - 0.5, 0.5 - u.origin.y);
    float2 shape_uv = uvn - 0.5;
    shape_uv.x *= aspect;
    shape_uv = mg_rotate(shape_uv, u.rotation);
    shape_uv /= max(u.scale, float2(0.01));

    float radius = length(shape_uv);
    float spots = 6.5 * abs(u.spotty);
    float intensity = 4.0 - 3.0 * clamp(u.intensity, 0.0, 1.0);

    float midSize = 10.0 * abs(u.midSize);
    float ms_lo = 0.02 * midSize;
    float ms_hi = max(midSize, 1e-6);
    float middleShape = pow(u.midIntensity, 0.3) * (1.0 - smoothstep(ms_lo, ms_hi, 3.0 * radius));
    middleShape = pow(middleShape, 5.0);

    float density = 6.0 * u.density + step(0.5, u.density) * pow(4.5 * (u.density - 0.5), 4.0);

    float3 accumColor = float3(0.0);
    float accumAlpha = 0.0;

    for (int i = 0; i < GR_MAX_COLORS; i++) {
        if (i >= u.colorsCount)
            break;

        float2 rotatedUV = mg_rotate(shape_uv, float(i) + 1.0);

        float r1 = radius * (1.0 + 0.4 * float(i)) - 3.0 * t;
        float r2 = 0.5 * radius * (1.0 + spots) - 2.0 * t;
        float f = mix(1.0, 3.0 + 0.5 * float(i), dth_hash11(float(i) * 15.0)) * density;

        float ray = gr_raysShape(rotatedUV, r1, 5.0 * f, intensity);
        ray *= gr_raysShape(rotatedUV, r2, 4.0 * f, intensity);
        ray += (1.0 + 4.0 * ray) * middleShape;
        ray = clamp(ray, 0.0, 1.0);

        float srcAlpha = u.colors[i].a * ray;
        float3 srcColor = u.colors[i].rgb * srcAlpha;

        float3 alphaBlendColor = accumColor + (1.0 - accumAlpha) * srcColor;
        float alphaBlendAlpha = accumAlpha + (1.0 - accumAlpha) * srcAlpha;

        float3 addBlendColor = accumColor + srcColor;
        float addBlendAlpha = accumAlpha + srcAlpha;

        accumColor = mix(alphaBlendColor, addBlendColor, u.bloom);
        accumAlpha = mix(alphaBlendAlpha, addBlendAlpha, u.bloom);
    }

    float overlayAlpha = u.colorBloom.a;
    float3 overlayColor = u.colorBloom.rgb * overlayAlpha;

    float3 colorWithOverlay = accumColor + accumAlpha * overlayColor;
    accumColor = mix(accumColor, colorWithOverlay, u.bloom);

    float3 bgColor = u.colorBack.rgb * u.colorBack.a;

    float3 color = accumColor + (1.0 - accumAlpha) * bgColor;
    float opacity = accumAlpha + (1.0 - accumAlpha) * u.colorBack.a;
    color = clamp(color, 0.0, 1.0);
    opacity = clamp(opacity, 0.0, 1.0);

    // colorBandingFix (paper): tiny ordered dither.
    color +=
        1.0 / 256.0 * (fract(sin(dot(0.014 * in.clipSpacePosition.xy, float2(12.9898, 78.233))) * 43758.5453123) - 0.5);

    // Premultiplied. 8-bit dest wants gamma; float dest wants linear.
    float3 outRGB = encodeSRGB ? clamp(color, 0.0, 1.0) : srgb_to_linear(color);
    return float4(outRGB, opacity);
}
