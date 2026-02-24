//
//  RoundedShaderTypes.h
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#ifndef RoundedShaderTypes_h
#define RoundedShaderTypes_h

#import <simd/simd.h>

typedef enum RoundedVertexInputIndex {
    RVI_Vertices        = 0,
    RVI_ViewportSize    = 1
} RoundedVertexInputIndex;

typedef enum RoundedTextureIndex {
    RTI_InputImage = 0
} RoundedTextureIndex;

typedef enum RoundedFragmentIndex {
    RFI_Radius      = 0,
    RFI_ImageSize   = 1,
    RFI_TileOffset  = 2
} RoundedFragmentIndex;

typedef enum RoundedOSCFragmentIndex {
    ROFI_DrawColor      = 0
} RoundedOSCFragmentIndex;

typedef struct Vertex2D {
    vector_float2   position;
    vector_float2   textureCoordinate;
} Vertex2D;

#endif /* RoundedShaderTypes_h */
