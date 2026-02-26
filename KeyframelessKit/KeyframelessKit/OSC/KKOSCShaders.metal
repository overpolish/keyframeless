//
//  KKOSCShaders.metal
//  KeyframelessKit
//
//  Created by Dom on 26/02/2026.
//

#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

#include "../Metal/KKShaderTypes.h"
#include "KKOSCShaderTypes.h"

constant float kGapAngle = 0.0f;
constant float kDividerWidth = 0.04f;


/// Fragment shader for rendering arc-based OSC controls (like progress rings)
/// with anti-aliasing (AA) and outline support.
fragment float4
KKOSCRingFragment(KKRasterizerData in [[stage_in]],
                  constant KKOSCRingParams *params [[buffer(KKOSCFragmentIndex_DrawColor)]])
{
    float outerRadius = 1.0;
    float innerRadius = params->innerRadius;
    float outlineWidth = params->outlineWidth;
    float4 fillColor = float4(params->fillColor);
    float4 outlineColor = float4(params->outlineColor);
    
    float2 pos = in.textureCoordinate;
    float dist = length(pos);
    
    float ringAlpha = kkEdgeAlpha(dist - innerRadius) * kkEdgeAlpha(outerRadius - dist);
    if (ringAlpha < 0.001) discard_fragment();
    
    // Gap dividers
    float gapAlpha = 0.0;
    for (int i = 0; i < 4; i++) {
        float2 dividerDir    = float2(cos(float(i) * M_PI_2_F), sin(float(i) * M_PI_2_F));
        float  distToDivider = abs(pos.x * dividerDir.y - pos.y * dividerDir.x);
        gapAlpha = max(gapAlpha, kkLineAlpha(distToDivider, kDividerWidth));
    }
    
    float outlineFactor = max(kkLineAlpha(abs(dist - innerRadius), outlineWidth),
                              kkLineAlpha(abs(outerRadius - dist), outlineWidth));
    
    return kkOSCColor(fillColor, outlineColor, outlineFactor, gapAlpha, ringAlpha);
}
