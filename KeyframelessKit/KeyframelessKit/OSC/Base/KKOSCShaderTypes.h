/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <simd/simd.h>

typedef enum KKOSCFragmentIndex { KKOSCFragmentIndex_DrawColor = 0 } KKOSCFragmentIndex;

typedef struct KKArcOSCParams {
    float innerRadius;
    float outlineWidth;
    float plusHalfLen;
    float plusFillHalfWidth;
    float plusOutlineWidth;
    vector_float4 fillColor;
    vector_float4 strokeColor;
} KKArcOSCParams;

typedef struct KKRingOSCParams {
    float ringRadius;
    float fillHalfWidth;
    float outlineWidth;
    vector_float4 fillColor;
    vector_float4 strokeColor;
} KKRingOSCParams;

typedef struct KKPointOSCParams {
    float outlineWidth;
    vector_float4 fillColor;
    vector_float4 strokeColor;
} KKPointOSCParams;

typedef struct KKRotationOSCParams {
    float armLength;
    float centerOffset;
    float circleRadius;
    float lineHalfWidth;
    float outlineWidth;
    float angle;
    vector_float4 fillColor;
    vector_float4 strokeColor;
    float donutRadius;
    float donutFillHalfWidth;
    float donutOutlineWidth;
    vector_float4 donutFillColor;
    vector_float4 donutStrokeColor;
    float markerAngle;
    float markerRadius;
    float markerOutlineWidth;
    vector_float4 markerFillColor;
    vector_float4 markerStrokeColor;
} KKRotationOSCParams;

#ifdef __METAL_VERSION__

#include <metal_stdlib>
using namespace metal;

/// Returns a smooth 0-1 alpha for a signed distance field edge.
/// signedDist > 0 = inside, signedDist < 0 = outside.
inline float kkEdgeAlpha(float signedDist) {
    float delta = fwidth(signedDist);
    return smoothstep(-delta * 0.5, delta * 0.5, signedDist);
}

/// Returns a 0-1 factor for a line of a given half-width at a perpendicular distance.
inline float kkLineAlpha(float distToLine, float halfWidth) {
    float aa = fwidth(distToLine);
    return smoothstep(halfWidth + aa, halfWidth - aa, distToLine);
}

/// Composites fill, outline, and divider colors with correct alpha handling.
inline float4 kkOSCColor(float4 fillColor, float4 strokeColor, float outlineFactor, float dividerFactor,
                         float shapeAlpha) {
    float4 premultOutline = float4(strokeColor.rgb * strokeColor.a, strokeColor.a);
    float blendFactor = max(outlineFactor, dividerFactor);
    float4 color = mix(fillColor, premultOutline, outlineFactor);
    color = mix(color, premultOutline, dividerFactor);
    color.a = shapeAlpha * mix(fillColor.a, strokeColor.a, blendFactor);
    return color;
}

/// Composites fill and outline colors with correct alpha handling.
inline float4 kkOSCColor(float4 fillColor, float4 strokeColor, float outlineFactor, float shapeAlpha) {
    return kkOSCColor(fillColor, strokeColor, outlineFactor, 0.0, shapeAlpha);
}

/// Source-over composite of two straight-alpha colors, returning straight alpha.
inline float4 kkCompositeOver(float4 src, float4 dst) {
    float4 srcPM = float4(src.rgb * src.a, src.a);
    float4 dstPM = float4(dst.rgb * dst.a, dst.a);
    float4 out = srcPM + dstPM * (1.0 - srcPM.a);
    return out.a > 0.001 ? float4(out.rgb / out.a, out.a) : float4(0.0);
}

/// Computes a filled circle color with outline and subtle bottom shadow (used by point and rotation handles).
inline float4 kkPointColor(float4 fillColor, float4 strokeColor, float outlineFactor, float shapeAlpha, float relY,
                           float radius, float dist, float outlineWidth) {
    float shadowFactor = smoothstep(0.1, -0.3, -relY) * 0.15 * (1.0 - outlineFactor);
    float edgePadding = smoothstep(0.0, outlineWidth * 4.0, radius - dist);
    shadowFactor *= edgePadding;
    float4 color = kkOSCColor(fillColor, strokeColor, outlineFactor, shapeAlpha);
    return mix(color, float4(0.0, 0.0, 0.0, strokeColor.a), shadowFactor);
}

#endif