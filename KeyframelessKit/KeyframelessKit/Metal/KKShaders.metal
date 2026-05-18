/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKShaderTypes.h"
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

/// Standard vertex shader for OSC controls and quads.
vertex KKRasterizerData KKVertexShader(uint vertexID [[vertex_id]],
                                       constant KKVertex2D *vertexArray [[buffer(KKVertexInputIndex_Vertices)]],
                                       constant vector_uint2 *viewportSizePointer
                                       [[buffer(KKVertexInputIndex_ViewportSize)]]) {
    KKRasterizerData out;

    float2 pixelSpacePosition = vertexArray[vertexID].position.xy;
    float2 viewportSize = float2(*viewportSizePointer);

    // Convert to clip space (-1 to 1)
    out.clipSpacePosition.xy = pixelSpacePosition / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;

    // Pass through texture coordinate
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;

    return out;
}

/// Samples the input texture straight through — used by KKMiniCanvasView to
/// blit a resolved source IOSurface before any plugin shader is applied.
fragment float4 KKTexturePassthroughFragment(KKRasterizerData in [[stage_in]],
                                             texture2d<float> tex [[texture(KKTextureIndex_InputImage)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.textureCoordinate);
}

/// Flat color fill — used for thin overlay strokes (e.g. the mini-canvas
/// crop border) drawn in the Metal pass so handle glyphs land on top.
fragment float4 KKSolidColorFragment(KKRasterizerData in [[stage_in]], constant float4 *color [[buffer(0)]]) {
    return *color;
}
