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
} MagicMoveParams;

typedef enum { FragmentIndex_Params = 0 } FragmentIndex;
