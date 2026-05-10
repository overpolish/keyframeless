/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
    FragmentIndex_NoiseOffset = 11,
    FragmentIndex_NoiseSeed = 12,
    FragmentIndex_BlurUVScale = 13,
    FragmentIndex_Threshold = 14,
    FragmentIndex_TileOffsetPx = 15,
    FragmentIndex_DestImgSizePx = 16,
    FragmentIndex_SrcOriginInDestPx = 17,
    FragmentIndex_SrcImgSizePx = 18
} FragmentIndex;

#define KK_GRADIENT_LUT_SIZE 64
