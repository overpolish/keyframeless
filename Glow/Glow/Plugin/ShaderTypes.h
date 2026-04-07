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
    FragmentIndex_GlowColor = 3,
    FragmentIndex_ColorMode = 4
} FragmentIndex;
