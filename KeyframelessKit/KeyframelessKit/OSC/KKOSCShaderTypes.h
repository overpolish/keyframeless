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

#ifdef __METAL_VERSION__

/// Returns a smooth 0-1 alpha for a signed distance field edge.
/// signedDist > 0 = inside, signedDist < 0 = outside.
inline float kkEdgeAlpha(float signedDist)
{
    float delta = fwidth(signedDist);
    return smoothstep(-delta * 0.5, delta * 0.5, signedDist);
}

/// Returns a 0-1 factor for a line of a given half-width at a perpendular distance.
inline float kkLineAlpha(float distToLine, float halfWidth)
{
    float aa = fwidth(distToLine);
    return smoothstep(halfWidth + aa, halfWidth - aa, distToLine);
}

/// Composites fill, outline, and divider colors with correct alpha handling.
inline float4 kkOSCColor(float4 fillColor,
                         float4 outlineColor,
                         float outlineFactor,
                         float dividerFactor,
                         float shapeAlpha)
{
    float4 premultOutline = float4(outlineColor.rgb * outlineColor.a, outlineColor.a);
    float blendFactor = max(outlineFactor, dividerFactor);
    float4 color = mix(fillColor, premultOutline, outlineFactor);
    color = mix(color, premultOutline, dividerFactor);
    color.a = shapeAlpha * mix(fillColor.a, outlineColor.a, blendFactor);
    return color;
}

/// Composites fill and outline colors with correct alpha handling.
inline float4 kkOSCColor(float4 fillColor,
                         float4 outlineColor,
                         float  outlineFactor,
                         float  shapeAlpha)
{
    return kkOSCColor(fillColor, outlineColor, outlineFactor, 0.0, shapeAlpha);
}

#endif

#endif /* KKOSCShaderTypes_h */
