/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <simd/simd.h>

typedef enum KKVertexInputIndex {
    KKVertexInputIndex_Vertices = 0,
    KKVertexInputIndex_ViewportSize = 1,
    // A float4x4 forward transform (model + perspective) consumed by
    // KKTransformVertexShader. Maps centered-pixel vertices to a clip-space
    // position for Metal's perspective divide (the shader still applies the
    // viewport / 2 normalization). Unused by the plain KKVertexShader.
    KKVertexInputIndex_Transform = 2,
    // A parallel float-per-vertex buffer of arc length (pixels along the
    // contour), consumed by KKStrokeDashVertexShader so the fragment can mask a
    // dash pattern by distance along the stroke. Unused by the other shaders.
    KKVertexInputIndex_StrokeArc = 3
} KKVertexInputIndex;

typedef enum KKTextureIndex { KKTextureIndex_InputImage = 0 } KKTextureIndex;

#define KK_MOTION_BLUR_MAX_SAMPLES 128

typedef struct KKVertex2D {
    vector_float2 position;
    vector_float2 textureCoordinate;
} KKVertex2D;

/// Fragment uniforms for KKStrokeDashFragment: a dash pattern masked by arc
/// length plus the stroke's solid / gradient colour. `cycle` is the dash + gap
/// period and `onLength` the dash (on) length, both in the same pixel units as
/// the per-vertex arc length; `phase` slides the pattern (marching ants).
/// `useGradient` picks the solid colour (premultiply-ready linear RGB in
/// `solidColor`) or the gradient LUT; `opacity` scales the result.
typedef struct KKStrokeDashParams {
    vector_float4 solidColor; // linear RGB (a unused); used when useGradient == 0
    float cycle;
    float onLength;
    float phase;
    float opacity;
    int useGradient; // 0 = solid, 1 = sample the gradient LUT
} KKStrokeDashParams;

/// Fragment uniforms for KKGradientFillFragment: a per-pixel bbox gradient for a
/// filled shape. The fragment reads each pixel's OBJECT-SPACE position from the
/// interpolated `textureCoordinate` (baked into the fill quad's corners), so
/// `center` / `dir` are in that same centered-pixel space. `type` 1 = linear
/// (along `dir`, normalised by `halfExtent`), else radial (circular, normalised
/// by `maxDim`). Mirrors CanvasApplyGradientFill so a fill matches the stroke
/// gradient. `opacity` scales the premultiplied result.
typedef struct KKGradientFillParams {
    vector_float2 center;
    vector_float2 dir;
    float halfExtent;
    float maxDim;
    int type;
    float opacity;
} KKGradientFillParams;

/// Fragment uniforms for KKTextureGradientTintFragment: tint an image toward a
/// gradient sampled in the image's UV space (centre 0.5). `type` 1 = linear
/// (along `dir`, normalised by `halfExtent`), else radial (from the centre).
/// `amount` is the tint strength (0 = original image, 1 = fully the gradient);
/// `opacity` the layer opacity.
typedef struct KKGradientTintParams {
    vector_float2 dir;
    float halfExtent;
    int type;
    float amount;
    float opacity;
} KKGradientTintParams;

/// Fragment uniforms for the masked-hachure fills (KKHachureMaskSolidFragment /
/// KKHachureMaskGradientFragment): clip an IMAGE layer's hachure pattern to the
/// picture's own alpha silhouette instead of its bounding rect. The hachure
/// verts carry their object-space (centered-pixel) position in textureCoordinate;
/// `scale` un-scales that to 0..1 object-norm, then `rectMin`/`rectMax` (the
/// image's placement rect, object-norm) map it into the image's UV so the alpha
/// is sampled at the matching texel.
typedef struct KKHachureMaskParams {
    vector_float2 scale;   // object -> pixel (imageWidth, imageHeight)
    vector_float2 rectMin; // image placement rect (object-normalised)
    vector_float2 rectMax;
} KKHachureMaskParams;

#ifdef __METAL_VERSION__
typedef struct {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} KKRasterizerData;
#endif