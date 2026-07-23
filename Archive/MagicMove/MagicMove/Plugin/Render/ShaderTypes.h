/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <simd/simd.h>

typedef struct {
    vector_float2 translate;
    vector_float2 anchorOffset;
    float rotation;
    float rotationX;
    float rotationY;
    float scaleX;
    float scaleY;
    float opacity;
    // Gaussian blur as a fraction (0..1) of the source clip's minimum
    // dimension. Applied as an MPS pass on the source frame before the
    // transform, not consumed by the fragment shader.
    float blur;
} MagicMoveParams;

typedef enum {
    FragmentIndex_Params = 0,
    FragmentIndex_TileOffsetPx = 1
} FragmentIndex;
