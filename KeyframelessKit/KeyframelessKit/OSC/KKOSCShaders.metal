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

constant float kDividerWidth = 0.04f;


/// Fragment shader for rendering arc-based OSC control with outline support.
fragment float4
KKArcOSCFragment(KKRasterizerData in [[stage_in]],
                  constant KKArcOSCParams *params [[buffer(KKOSCFragmentIndex_DrawColor)]])
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

/// Fragment shader for rendering a point/dot OSC control with outline and depth shadow.
fragment float4
KKPointOSCFragment(KKRasterizerData in [[stage_in]],
                constant KKPointOSCParams *params [[buffer(KKOSCFragmentIndex_DrawColor)]])
{
    float outerRadius = 1.0;
    float outlineWidth = params->outlineWidth;
    float4 fillColor = float4(params->fillColor);
    float4 outlineColor = float4(params->outlineColor);
    
    float2 pos = in.textureCoordinate;
    float dist = length(pos);
    
    float circleAlpha = kkEdgeAlpha(outerRadius - dist);
    if (circleAlpha < 0.001) discard_fragment();
    
    // Outline
    float outlineFactor = kkLineAlpha(abs(outerRadius - dist), outlineWidth);
    
    // Subtle shadow on lower half
    float shadowFactor = smoothstep(0.1, -0.3, -pos.y) * 0.15 * (1.0 - outlineFactor);
    float edgePadding = smoothstep(0.0, outlineWidth * 4.0, outerRadius - dist);
    shadowFactor *= edgePadding;
    
    float4 shadowColor = float4(0.0, 0.0, 0.0, outlineColor.a);
    float4 color = kkOSCColor(fillColor, outlineColor, outlineFactor, circleAlpha);
    color = mix(color, shadowColor, shadowFactor);
    
    return color;
}
