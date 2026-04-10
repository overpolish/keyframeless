/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <simd/simd.h>

typedef enum FragmentIndex {
    FragmentIndex_Radius = 0,
    FragmentIndex_Intensity = 1,
    FragmentIndex_Falloff = 2,
    FragmentIndex_Offset = 3,
    FragmentIndex_GlowColor = 4,
    FragmentIndex_ColorMode = 5,
    FragmentIndex_GradientLUT = 6,
    FragmentIndex_GradientType = 7,
    FragmentIndex_GradientAngle = 8,
    FragmentIndex_Noise = 9,
    FragmentIndex_NoiseOffset = 10
} FragmentIndex;

#define KK_GRADIENT_LUT_SIZE 64
