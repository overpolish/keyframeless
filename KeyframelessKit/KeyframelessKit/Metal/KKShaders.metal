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

/// Rasterizer payload for the dashed stroke: the usual edge-distance + gradient
/// texture coordinate plus the per-vertex arc length the fragment masks against.
struct KKStrokeRasterData {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate; // x = gradient pos, y = signed edge distance
    float arcLength;          // pixels along the contour
};

/// Like KKTransformVertexShader, but also threads a parallel per-vertex arc
/// length (pixels along the stroke) through to the fragment so a dash pattern can
/// be masked by distance rather than cut into geometry (robust around corners -
/// the geometry is just the solid stroke).
vertex KKStrokeRasterData KKStrokeDashVertexShader(
    uint vertexID [[vertex_id]],
    constant KKVertex2D *vertexArray [[buffer(KKVertexInputIndex_Vertices)]],
    constant vector_uint2 *viewportSizePointer [[buffer(KKVertexInputIndex_ViewportSize)]],
    constant matrix_float4x4 *transform [[buffer(KKVertexInputIndex_Transform)]],
    constant float *arc [[buffer(KKVertexInputIndex_StrokeArc)]]) {
    KKStrokeRasterData out;
    float2 localPos = vertexArray[vertexID].position.xy;
    float2 viewportSize = float2(*viewportSizePointer);
    float4 world = (*transform) * float4(localPos, 0.0, 1.0);
    out.clipSpacePosition = float4(world.xy / (viewportSize / 2.0), 0.0, world.w);
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;
    out.arcLength = arc[vertexID];
    return out;
}

/// Dashed stroke fragment: edge-distance AA (textureCoordinate.y, as
/// KKLineFragment) combined with a dash mask by arc length, filled with either
/// the solid colour or the gradient LUT. The dash on/off and both AA edges use
/// fwidth so the pattern stays crisp at any zoom. Output is premultiplied to
/// match the stroke pipeline's blend.
fragment float4 KKStrokeDashFragment(
    KKStrokeRasterData in [[stage_in]],
    constant KKStrokeDashParams &dp [[buffer(0)]],
    constant float3 *lut [[buffer(1)]]) {
    float dist = abs(in.textureCoordinate.y);
    float alpha = 1.0 - smoothstep(1.0 - fwidth(dist) * 2.0, 1.0, dist);

    // Dash mask: where in the cycle is this fragment, and is it within the "on"
    // run? Feather both the dash start and end by ~1px of arc length.
    float cycle = max(dp.cycle, 1.0);
    float ph = fmod(in.arcLength - dp.phase, cycle);
    if (ph < 0.0)
        ph += cycle;
    float fw = max(fwidth(in.arcLength), 1e-4);
    float on = smoothstep(-fw, fw, ph) * (1.0 - smoothstep(dp.onLength - fw, dp.onLength + fw, ph));
    alpha *= on;
    if (alpha < 0.001)
        discard_fragment();

    float3 rgb;
    if (dp.useGradient != 0) {
        const int n = 64; // == KK_GRADIENT_LUT_SIZE
        float lutPos = saturate(in.textureCoordinate.x) * float(n - 1);
        int i0 = int(floor(lutPos));
        int i1 = min(i0 + 1, n - 1);
        rgb = pow(mix(lut[i0], lut[i1], lutPos - float(i0)), 2.2);
    } else {
        rgb = dp.solidColor.rgb; // already linear (CPU-side pow 2.2)
    }
    float a = alpha * dp.opacity;
    return float4(rgb * a, a);
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
