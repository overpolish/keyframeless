//
//  ShaderTypes.h
//  Rounded
//
//  Created by Dom on 24/02/2026.
//
#pragma once
#import <simd/simd.h>

typedef enum FragmentIndex {
    FragmentIndex_Radius = 0,
    FragmentIndex_ImageSize = 1,
    FragmentIndex_TileOffset = 2
} FragmentIndex;