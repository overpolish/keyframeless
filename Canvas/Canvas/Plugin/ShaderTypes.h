/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <simd/simd.h>

typedef struct {
    vector_float2 position;
    float edgeDistance; // -1 to +1, 0 = center of stroke
    float capDistance;  // 0 = interior, approaches 1 at path ends
} CanvasVertex;

typedef struct {
    float strokeWidth;
    float r, g, b;
} CanvasStrokeParams;
