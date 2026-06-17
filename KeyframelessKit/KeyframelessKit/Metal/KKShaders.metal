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

/// Like KKVertexShader, but applies a 4x4 forward transform (model +
/// perspective) to each centered-pixel vertex and emits a clip-space position
/// so Metal does the perspective divide - giving true 3D-rotated/perspective
/// quads (e.g. a layer's X/Y tilt). The matrix maps to pixel-ish space; the
/// viewport / 2 normalization stays here so callers pass the same centered
/// pixel verts they would to KKVertexShader. `w` carries the homogeneous depth.
vertex KKRasterizerData KKTransformVertexShader(
    uint vertexID [[vertex_id]], constant KKVertex2D *vertexArray [[buffer(KKVertexInputIndex_Vertices)]],
    constant vector_uint2 *viewportSizePointer [[buffer(KKVertexInputIndex_ViewportSize)]],
    constant matrix_float4x4 *transform [[buffer(KKVertexInputIndex_Transform)]]) {
    KKRasterizerData out;

    float2 localPos = vertexArray[vertexID].position.xy;
    float2 viewportSize = float2(*viewportSizePointer);

    float4 world = (*transform) * float4(localPos, 0.0, 1.0);
    out.clipSpacePosition = float4(world.xy / (viewportSize / 2.0), 0.0, world.w);
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;

    return out;
}

/// Samples the input texture straight through - used by KKMiniViewerView to
/// blit a resolved source IOSurface before any plugin shader is applied.
fragment float4 KKTexturePassthroughFragment(KKRasterizerData in [[stage_in]],
                                             texture2d<float> tex [[texture(KKTextureIndex_InputImage)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.textureCoordinate);
}

/// Like the passthrough, but scales the (premultiplied) sample by a uniform
/// opacity 0..1 - multiplying all four channels keeps it premultiplied so the
/// usual "over" blend fades the layer correctly. Used by layer-compositing
/// plugins (e.g. Canvas) to apply a per-layer Opacity value.
fragment float4 KKTextureOpacityFragment(KKRasterizerData in [[stage_in]],
                                         texture2d<float> tex [[texture(KKTextureIndex_InputImage)]],
                                         constant float *opacity [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.textureCoordinate) * (*opacity);
}

/// Flat color fill - used for thin overlay strokes (e.g. the mini-viewer
/// crop border) drawn in the Metal pass so handle glyphs land on top.
fragment float4 KKSolidColorFragment(KKRasterizerData in [[stage_in]], constant float4 *color [[buffer(0)]]) {
    return *color;
}

/// Onion-skin tint+alpha: samples the input texture, lerps RGB toward
/// `tintRGBA.rgb` by `tintRGBA.a`, then multiplies the whole output by
/// `outAlpha` (premultiplied). Lets KKMiniViewerView stack prev/next KP
/// frames with a coloured wash and a global opacity on the active cell.
fragment float4 KKTextureTintFragment(KKRasterizerData in [[stage_in]],
                                      texture2d<float> tex [[texture(KKTextureIndex_InputImage)]],
                                      constant float4 *tintRGBA [[buffer(0)]], constant float *outAlpha [[buffer(1)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(s, in.textureCoordinate);
    float3 rgb = mix(c.rgb, tintRGBA->rgb, tintRGBA->a);
    float a = c.a * (*outAlpha);
    return float4(rgb * a, a);
}
