//
//  KKOSCShaderTypes.h
//  KeyframelessKit
//
//  Created by Dom on 26/02/2026.
//

#ifndef KKOSCShaderTypes_h
#define KKOSCShaderTypes_h

#import <simd/simd.h>

typedef enum KKOSCFragmentIndex {
    KKOSCFragmentIndex_DrawColor      = 0
} KKOSCFragmentIndex;


typedef struct KKOSCRingParams {
    float         innerRadius;
    float         outlineWidth;
    vector_float4 fillColor;
    vector_float4 outlineColor;
} KKOSCRingParams;

#endif /* KKOSCShaderTypes_h */
