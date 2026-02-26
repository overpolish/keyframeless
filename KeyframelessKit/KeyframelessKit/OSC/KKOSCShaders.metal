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
    
    float angle = atan2(pos.y, pos.x);
    if (angle < 0.0) {
        angle += 2.0 * M_PI_F;
    }
    
    // AA parameters
    float delta = fwidth(dist);
    float halfDelta = delta * 0.5;
    
    // Radial boundaries
    float innerEdgeDist = dist - innerRadius;
    float outerEdgeDist = outerRadius - dist;
    
    float innerAlpha = smoothstep(-halfDelta, halfDelta, innerEdgeDist);
    float outerAlpha = smoothstep(-halfDelta, halfDelta, outerEdgeDist);
    float ringAlpha  = innerAlpha * outerAlpha;
    
    if (ringAlpha < 0.001) discard_fragment();
    
    // Gap dividers - render as solid black lines over the full ring
    float kDividerWidth = 0.04f;
    
    float gapAlpha = 0.0;
    for (int i = 0; i < 4; i++) {
        float  dividerAngle  = float(i) * M_PI_2_F;
        float2 dividerDir    = float2(cos(dividerAngle), sin(dividerAngle));
        float  distToDivider = abs(pos.x * dividerDir.y - pos.y * dividerDir.x);
        float  aa            = fwidth(distToDivider);
        float  dividerFactor = smoothstep(kDividerWidth + aa, kDividerWidth - aa, distToDivider);
        gapAlpha = max(gapAlpha, dividerFactor);
    }
    
    // Outline factors
    float distToInner = abs(innerEdgeDist);
    float distToOuter = abs(outerEdgeDist);
    
    float innerOutlineFactor = 1.0 - smoothstep(outlineWidth - halfDelta, outlineWidth + halfDelta, distToInner);
    float outerOutlineFactor = 1.0 - smoothstep(outlineWidth - halfDelta, outlineWidth + halfDelta, distToOuter);
    float outlineFactor      = max(innerOutlineFactor, outerOutlineFactor);
    
    // Combine: outline takes priority, then gap dividers, then fill
    float4 color = mix(fillColor, outlineColor, outlineFactor);
    color        = mix(color, outlineColor, gapAlpha);
    color.a      = ringAlpha;
    
    return color;
}
