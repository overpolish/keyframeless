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

#ifdef __METAL_VERSION__
typedef struct {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} KKRasterizerData;
#endif