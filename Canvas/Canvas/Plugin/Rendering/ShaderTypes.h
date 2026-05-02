/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <simd/simd.h>

typedef struct {
    vector_float2 position;
    float edgeDistance; // -1 to +1, 0 = center of stroke
    float capDistance;  // 0 = interior, approaches 1 at path ends
} CanvasVertex;

// Per-path affine transform applied in centered-pixel space. `m` is composed
// onto each vertex; `mInv` is applied to the fragment position before
// gradient bbox sampling so gradients stay aligned with the path's local
// coordinates. Identity for paths/draw-calls without a per-path transform.
typedef struct {
    matrix_float3x3 m;
    matrix_float3x3 mInv;
} CanvasPathTransform;

typedef struct {
    float strokeWidth;
    float r, g, b;
} CanvasStrokeParams;

typedef struct {
    vector_float2 position;
} CanvasFillVertex;

#define KK_GRADIENT_LUT_SIZE 64

typedef struct {
    vector_float4 solidColor; // RGBA, used when useGradient == 0
    vector_float2 bboxMin;    // in centered-pixel space (matches vertex pos)
    vector_float2 bboxMax;
    int useGradient;
    int gradientType;    // 0 = radial, 1 = linear
    float gradientAngle; // radians
    float opacity;       // 0..1, multiplied into gradient sample
    vector_float3 lut[KK_GRADIENT_LUT_SIZE];
} CanvasGradientParams;
