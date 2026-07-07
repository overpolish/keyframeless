/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#include "KKShaderTypes.h"
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

/// Dominant (max-magnitude) velocity within each KxK tile. The render target is
/// the tile grid (ceil(W/K) x ceil(H/K)); each fragment owns one tile and scans
/// its KxK block of the full-res velocity buffer. Velocity is clamped to K px so
/// a huge displacement can't reach beyond what the 3x3 NeighborMax dilation
/// covers. Velocity is RG = pixel displacement over the shutter (+x right, +y
/// down in the texture's own space).
fragment half2 KKMBVelocityTileMaxFragment(KKRasterizerData in [[stage_in]],
                                           texture2d<half, access::read> vel [[texture(0)]],
                                           constant KKMBReconstructParams &p [[buffer(0)]]) {
    int K = max(p.tileSize, 1);
    uint2 tile = uint2(in.clipSpacePosition.xy);
    uint2 origin = tile * uint(K);
    uint W = vel.get_width();
    uint H = vel.get_height();

    half2 best = half2(0.0h);
    half bestMag = 0.0h;
    for (int dy = 0; dy < K; dy++) {
        for (int dx = 0; dx < K; dx++) {
            uint2 c = origin + uint2(uint(dx), uint(dy));
            if (c.x >= W || c.y >= H)
                continue;
            half2 v = vel.read(c).xy;
            half m = length(v);
            if (m > bestMag) {
                bestMag = m;
                best = v;
            }
        }
    }
    if (bestMag > half(K))
        best *= half(K) / bestMag; // clamp to one tile's reach
    return best;
}

/// Max-magnitude velocity over the 3x3 neighborhood of tiles, so a fast tile's
/// blur can reach into adjacent (e.g. transparent-margin) tiles - the dilation
/// that lets a moving layer smear OUTSIDE its silhouette.
fragment half2 KKMBVelocityNeighborMaxFragment(KKRasterizerData in [[stage_in]],
                                               texture2d<half, access::read> tileMax [[texture(0)]]) {
    int2 tile = int2(in.clipSpacePosition.xy);
    int W = int(tileMax.get_width());
    int H = int(tileMax.get_height());

    half2 best = half2(0.0h);
    half bestMag = 0.0h;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 c = tile + int2(dx, dy);
            if (c.x < 0 || c.y < 0 || c.x >= W || c.y >= H)
                continue;
            half2 v = tileMax.read(uint2(c)).xy;
            half m = length(v);
            if (m > bestMag) {
                bestMag = m;
                best = v;
            }
        }
    }
    return best;
}

/// Cone weight: how much a smear of length `vLen` reaches across `dist` px.
static inline float kkMBCone(float dist, float vLen) {
    return saturate(1.0 - dist / max(vLen, 1e-3));
}

/// Cheap per-pixel hash in [0,1) to jitter sample positions (breaks the banding
/// a fixed tap stride leaves behind).
static inline float kkMBHash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

/// McGuire/Guertin-style reconstruction gather, depth-free / premultiplied-alpha
/// variant for a SINGLE layer. For each pixel it samples S taps along the dilated
/// NeighborMax velocity (the dominant direction in reach), weighting each tap by
/// the cone overlap of the tap's own velocity and the centre velocity. Because
/// colour is premultiplied, transparent margin samples lower coverage, so a
/// moving layer smears softly into its own transparent margin. Cost is fixed in
/// S - independent of how long the blur is (that lives in the velocity length /
/// tile reach).
fragment float4 KKMBReconstructFragment(KKRasterizerData in [[stage_in]],
                                        texture2d<float> color [[texture(0)]],
                                        texture2d<half> vel [[texture(1)]],
                                        texture2d<half> neighborMax [[texture(2)]],
                                        constant KKMBReconstructParams &p [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float W = float(color.get_width());
    float H = float(color.get_height());
    float2 uvX = in.textureCoordinate;
    float2 X = uvX * float2(W, H);

    int K = max(p.tileSize, 1);
    float2 gridDims = float2(float(neighborMax.get_width()), float(neighborMax.get_height()));
    float2 tileUV = (floor(X / float(K)) + 0.5) / gridDims;
    float2 vmax = float2(neighborMax.sample(s, tileUV).xy);

    float4 c0 = color.sample(s, uvX);
    if (length(vmax) < 0.5)
        return c0; // nothing within reach moves

    float2 vc = float2(vel.sample(s, uvX).xy);
    float vcLen = length(vc);

    int S = clamp(p.sampleCount, 3, 31);
    float j = kkMBHash(X) - 0.5;

    float wc = 1.0 / max(vcLen, 0.5);
    float4 sum = c0 * wc;
    float total = wc;

    for (int i = 0; i < S; i++) {
        float t = mix(-1.0, 1.0, (float(i) + 0.5 + j) / float(S));
        float2 Y = X + vmax * (t * 0.5);
        float2 uvY = Y / float2(W, H);
        float dist = length(Y - X);
        float2 vY = float2(vel.sample(s, uvY).xy);
        float w = kkMBCone(dist, length(vY)) + kkMBCone(dist, vcLen);
        sum += color.sample(s, uvY) * w;
        total += w;
    }
    return sum / max(total, 1e-4);
}
