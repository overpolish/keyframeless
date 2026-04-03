/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <simd/simd.h>

typedef enum FragmentIndex {
    FragmentIndex_Radius = 0,
    FragmentIndex_ImageSize = 1,
    FragmentIndex_TileOffset = 2,
    FragmentIndex_CropCenter = 3,
    FragmentIndex_CropSize = 4
} FragmentIndex;