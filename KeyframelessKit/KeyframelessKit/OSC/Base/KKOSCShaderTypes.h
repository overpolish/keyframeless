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
    vector_float4 armFillColor;
    vector_float4 armStrokeColor;
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

/// Computes a filled circle color with outline and a top-to-bottom black-to-white gradient
/// inset by the outline width for an inner-stroke effect.
inline float4 kkPointColor(float4 fillColor, float4 strokeColor, float outlineFactor, float shapeAlpha, float relY,
                           float radius, float dist, float outlineWidth) {
    float4 color = kkOSCColor(fillColor, strokeColor, outlineFactor, shapeAlpha);
    float inset = smoothstep(0.0, outlineWidth, radius - outlineWidth - dist);
    float gradient = (-relY / radius) * 0.5 + 0.5;
    color.rgb = mix(color.rgb, mix(float3(0.0), float3(1.0), gradient), inset * 0.35);
    return color;
}

#endif