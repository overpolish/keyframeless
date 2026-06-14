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

// Per-path transform. `m4` is the full forward transform - composed 2D
// (translate, anchor, scale, rotZ) plus optional 3D rotation (rotX, rotY)
// passed through a perspective projection - applied to each vertex with a
// perspective divide. `mInv` is the 2D-only inverse (no rotX/rotY) used by
// the fill color pass to map a screen fragment back into path-local pixels
// for gradient bbox sampling; for stroke/image we instead pass the
// pre-transform local position as a varying, which gives an exact result
// even with 3D rotation. Identity for draw calls without a per-path transform.
typedef struct {
    matrix_float4x4 m4;
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
