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
    KKVertexInputIndex_Transform = 2
} KKVertexInputIndex;

typedef enum KKTextureIndex { KKTextureIndex_InputImage = 0 } KKTextureIndex;

#define KK_MOTION_BLUR_MAX_SAMPLES 128

typedef struct KKVertex2D {
    vector_float2 position;
    vector_float2 textureCoordinate;
} KKVertex2D;

#ifdef __METAL_VERSION__
typedef struct {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} KKRasterizerData;
#endif