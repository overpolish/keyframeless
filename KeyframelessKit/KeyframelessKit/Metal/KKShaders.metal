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

/// Rasterizer payload for the velocity pass: only the clip position (for
/// rasterization) and the per-vertex screen-space displacement over the shutter.
struct KKVelocityRasterData {
    float4 clipSpacePosition [[position]];
    float2 velocity; // screen px displacement (curr - prev), +x right / +y down
};

/// Emits a per-pixel VELOCITY buffer for the "Fast" reconstruction motion blur,
/// paired with KKTransformVertexShader. Draw the SAME geometry (image quad,
/// tessellated stroke, …) through this shader, binding the CURRENT-frame composed
/// matrix at KKVertexInputIndex_Transform and the SHUTTER-START matrix at
/// KKVertexInputIndex_TransformPrev. Each vertex is projected through both
/// matrices (perspective divide included), converted to top-left texture pixels
/// (+y down, matching the reconstruction sampling space), and the difference is
/// interpolated across the primitive. Uncovered pixels keep the cleared 0 -
/// correct (still = no motion). The current clip position drives rasterization so
/// the velocity lands exactly where the colour pass drew.
vertex KKVelocityRasterData KKVelocityVertexShader(
    uint vertexID [[vertex_id]], constant KKVertex2D *vertexArray [[buffer(KKVertexInputIndex_Vertices)]],
    constant vector_uint2 *viewportSizePointer [[buffer(KKVertexInputIndex_ViewportSize)]],
    constant matrix_float4x4 *transform [[buffer(KKVertexInputIndex_Transform)]],
    constant matrix_float4x4 *transformPrev [[buffer(KKVertexInputIndex_TransformPrev)]]) {
    KKVelocityRasterData out;
    float2 localPos = vertexArray[vertexID].position.xy;
    float2 viewportSize = float2(*viewportSizePointer);

    float4 wNow = (*transform) * float4(localPos, 0.0, 1.0);
    float4 wPrev = (*transformPrev) * float4(localPos, 0.0, 1.0);

    out.clipSpacePosition = float4(wNow.xy / (viewportSize / 2.0), 0.0, wNow.w);

    // Screen pixels after perspective divide, top-left origin / +y down (the
    // KKTransformVertexShader's world.xy/world.w is centered-pixel, +y up):
    // px = (world.x, -world.y)/world.w + viewport/2.
    float2 pxNow = float2(wNow.x, -wNow.y) / wNow.w + viewportSize * 0.5;
    float2 pxPrev = float2(wPrev.x, -wPrev.y) / wPrev.w + viewportSize * 0.5;
    out.velocity = pxNow - pxPrev;
    return out;
}

/// Writes the interpolated screen-space velocity into the RG16Float velocity
/// buffer the reconstruction filter samples.
fragment half2 KKVelocityFragment(KKVelocityRasterData in [[stage_in]]) {
    return half2(in.velocity);
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
    uint vertexID [[vertex_id]], constant KKVertex2D *vertexArray [[buffer(KKVertexInputIndex_Vertices)]],
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
fragment float4 KKStrokeDashFragment(KKStrokeRasterData in [[stage_in]], constant KKStrokeDashParams &dp [[buffer(0)]],
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

/// Like the passthrough, but NEAREST magnification - so a zoomed-in mini-viewer
/// shows crisp texel squares (pixel inspection) instead of bilinear blur. Min
/// filter stays linear so a zoomed-OUT view still downscales cleanly; only the
/// magnification (zoom-in) reads hard-edged.
fragment float4 KKTextureNearestFragment(KKRasterizerData in [[stage_in]],
                                         texture2d<float> tex [[texture(KKTextureIndex_InputImage)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::linear, address::clamp_to_edge);
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

/// Per-pixel bbox gradient fill for a filled shape. `textureCoordinate` carries
/// the pixel's OBJECT-SPACE position (baked into the fill quad's corners), so
/// the gradient geometry is decided in that space (handles a 3D-rotated fill via
/// the vertex shader's perspective-correct interpolation). Mirrors
/// CanvasApplyGradientFill: linear runs along `dir` normalised by `halfExtent`,
/// radial is circular normalised by `maxDim`. LUT is sRGB -> linearised on output
/// (same pow(2.2) as the stroke gradient + solid colour).
fragment float4 KKGradientFillFragment(KKRasterizerData in [[stage_in]], constant float3 *lut [[buffer(0)]],
                                       constant KKGradientFillParams *p [[buffer(1)]]) {
    float2 d = in.textureCoordinate - p->center;
    float gt = (p->type == 1) ? dot(d, p->dir) / (2.0 * p->halfExtent) + 0.5 : 2.0 * length(d) / max(p->maxDim, 1.0);
    gt = saturate(gt);
    const int n = 64; // == KK_GRADIENT_LUT_SIZE (KKColor.h)
    float lutPos = gt * float(n - 1);
    int i0 = int(floor(lutPos));
    int i1 = min(i0 + 1, n - 1);
    float3 rgb = pow(mix(lut[i0], lut[i1], lutPos - float(i0)), 2.2);
    float a = p->opacity;
    return float4(rgb * a, a);
}

/// Image alpha at the object-space point, mapped through the image's placement
/// rect. Shared by the masked-hachure fills so an IMAGE-layer hachure is clipped
/// to the picture's silhouette, not its bounding box. `objPos` is the hachure
/// vert's centered-pixel position (carried in textureCoordinate); un-scale to
/// object-norm, then remap into the rect's UV (V flipped to the texture's
/// top-left origin, matching the image quad).
static inline float KKHachureImageMaskAlpha(float2 objPos, constant KKHachureMaskParams *mp, texture2d<float> img) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 objNorm = objPos / mp->scale + 0.5;
    float2 uv = (objNorm - mp->rectMin) / max(mp->rectMax - mp->rectMin, float2(1e-4));
    uv.y = 1.0 - uv.y;
    return img.sample(s, uv).a;
}

/// Solid-colour hachure fill clipped to an image's alpha (image-layer hachure).
fragment float4 KKHachureMaskSolidFragment(KKRasterizerData in [[stage_in]], constant float4 *color [[buffer(0)]],
                                           constant KKHachureMaskParams *mp [[buffer(1)]],
                                           texture2d<float> img [[texture(KKTextureIndex_InputImage)]]) {
    return (*color) * KKHachureImageMaskAlpha(in.textureCoordinate, mp, img);
}

/// Gradient hachure fill clipped to an image's alpha. Same per-pixel bbox
/// gradient as KKGradientFillFragment, then multiplied by the image silhouette.
fragment float4 KKHachureMaskGradientFragment(KKRasterizerData in [[stage_in]], constant float3 *lut [[buffer(0)]],
                                              constant KKGradientFillParams *p [[buffer(1)]],
                                              constant KKHachureMaskParams *mp [[buffer(2)]],
                                              texture2d<float> img [[texture(KKTextureIndex_InputImage)]]) {
    float2 d = in.textureCoordinate - p->center;
    float gt = (p->type == 1) ? dot(d, p->dir) / (2.0 * p->halfExtent) + 0.5 : 2.0 * length(d) / max(p->maxDim, 1.0);
    gt = saturate(gt);
    const int n = 64; // == KK_GRADIENT_LUT_SIZE (KKColor.h)
    float lutPos = gt * float(n - 1);
    int i0 = int(floor(lutPos));
    int i1 = min(i0 + 1, n - 1);
    float3 rgb = pow(mix(lut[i0], lut[i1], lutPos - float(i0)), 2.2);
    float a = p->opacity * KKHachureImageMaskAlpha(in.textureCoordinate, mp, img);
    return float4(rgb * a, a);
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

/// Like KKTextureTintFragment but tints toward a GRADIENT sampled in the image's
/// UV space (so the gradient follows the image, centre 0.5). LUT is sRGB ->
/// linearised. Used for a gradient-mode image fill tint.
fragment float4 KKTextureGradientTintFragment(KKRasterizerData in [[stage_in]],
                                              texture2d<float> tex [[texture(KKTextureIndex_InputImage)]],
                                              constant float3 *lut [[buffer(0)]],
                                              constant KKGradientTintParams *p [[buffer(1)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 c = tex.sample(s, in.textureCoordinate);
    float2 d = in.textureCoordinate - 0.5;
    float gt = (p->type == 1) ? dot(d, p->dir) / (2.0 * p->halfExtent) + 0.5 : 2.0 * length(d);
    gt = saturate(gt);
    const int n = 64; // == KK_GRADIENT_LUT_SIZE
    float lutPos = gt * float(n - 1);
    int i0 = int(floor(lutPos));
    int i1 = min(i0 + 1, n - 1);
    float3 grad = pow(mix(lut[i0], lut[i1], lutPos - float(i0)), 2.2);
    float3 rgb = mix(c.rgb, grad, p->amount);
    float a = c.a * p->opacity;
    return float4(rgb * a, a);
}
