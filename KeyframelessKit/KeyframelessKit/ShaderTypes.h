//
//  ShaderTypes.h
//  KeyframelessKit
//
//  Created by Dom on 24/02/2026.
//

#ifndef ShaderTypes_h
#define ShaderTypes_h

#import <simd/simd.h>

typedef enum KeyframelessKitVertexInputIndex {
    KKVertexInputIndex_Vertices        = 0,
    KKVertexInputIndex_ViewportSize    = 1
} KeyframelessKitVertexInputIndex;

typedef enum KeyframelessKitTextureIndex {
    KKTextureIndex_InputImage = 0
} KeyframelessKitTextureIndex;

typedef enum KeyframelessKitOSCFragmentIndex {
    KKOSCFragmentIndex_DrawColor      = 0
} KeyframelessKitOSCFragmentIndex;

typedef struct KeyframelessKitVertex2D {
    vector_float2   position;
    vector_float2   textureCoordinate;
} KeyframelessKitVertex2D;

#endif /* ShaderTypes_h */
