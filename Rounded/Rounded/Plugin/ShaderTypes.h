//
//  ShaderTypes.h
//  Rounded
//
//  Created by Dom on 24/02/2026.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#import <simd/simd.h>

typedef enum FragmentIndex {
    FragmentIndex_Radius      = 0,
    FragmentIndex_ImageSize   = 1,
    FragmentIndex_TileOffset  = 2
} FragmentIndex;

#endif /* ShaderTypes_h */
