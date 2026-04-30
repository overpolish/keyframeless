/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "KKShaderTypes.h"
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

/// Averages N pre-rendered sample textures into a single output. Sample
/// textures are bound as a texture array starting at index 0; sampleCount
/// is supplied as a fragment buffer at index 0.
fragment float4 KKMotionBlurAccumulateFragment(KKRasterizerData in [[stage_in]],
                                               array<texture2d<half>, KK_MOTION_BLUR_MAX_SAMPLES> frames [[texture(0)]],
                                               constant int &sampleCount [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    int n = min(sampleCount, KK_MOTION_BLUR_MAX_SAMPLES);
    if (n <= 0) {
        return float4(0.0);
    }

    float4 result = float4(0.0);
    for (int i = 0; i < n; i++) {
        result += float4(frames[i].sample(s, in.textureCoordinate));
    }
    return result / float(n);
}
