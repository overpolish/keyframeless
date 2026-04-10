/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <simd/simd.h>

typedef enum FragmentIndex {
    FragmentIndex_RadiusX = 0,
    FragmentIndex_RadiusY = 1,
    FragmentIndex_Intensity = 2,
    FragmentIndex_Falloff = 3,
    FragmentIndex_Offset = 4,
    FragmentIndex_GlowColor = 5,
    FragmentIndex_ColorMode = 6,
    FragmentIndex_GradientLUT = 7,
    FragmentIndex_GradientType = 8,
    FragmentIndex_GradientAngle = 9,
    FragmentIndex_Noise = 10,
    FragmentIndex_NoiseOffset = 11
} FragmentIndex;

#define KK_GRADIENT_LUT_SIZE 64
