//
//  KKShaderTypes.h
//  KeyframelessKit
//
//  Created by Dom on 24/02/2026.
//

#ifndef KKShaderTypes_h
#define KKShaderTypes_h

#import <simd/simd.h>

typedef enum KKVertexInputIndex {
    KKVertexInputIndex_Vertices        = 0,
    KKVertexInputIndex_ViewportSize    = 1
} KKVertexInputIndex;

typedef enum KKTextureIndex {
    KKTextureIndex_InputImage = 0
} KKTextureIndex;

typedef struct KKVertex2D {
    vector_float2   position;
    vector_float2   textureCoordinate;
} KKVertex2D;

#ifdef __METAL_VERSION__
typedef struct {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} KKRasterizerData;
#endif


#endif /* KKShaderTypes_h */
