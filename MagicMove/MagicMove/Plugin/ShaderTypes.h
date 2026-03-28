/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <simd/simd.h>

typedef struct {
    vector_float2 translate;
    float rotation;
    float scale;
} MagicMoveParams;

typedef enum { FragmentIndex_Params = 0 } FragmentIndex;
