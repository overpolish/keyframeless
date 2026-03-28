/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "../../Metal/KKShaderTypes.h"
#include "KKOSCShaderTypes.h"
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

constant float kDividerWidth = 0.04f;

/// Fragment shader for rendering arc-based OSC control with outline support.
fragment float4 KKArcOSCFragment(KKRasterizerData in [[stage_in]],
                                 constant KKArcOSCParams *params [[buffer(KKOSCFragmentIndex_DrawColor)]]) {
    float outerRadius = 1.0;
    float innerRadius = params->innerRadius;
    float outlineWidth = params->outlineWidth;
    float4 fillColor = float4(params->fillColor);
    float4 strokeColor = float4(params->strokeColor);

    float2 pos = in.textureCoordinate;
    float dist = length(pos);

    float ringAlpha = kkEdgeAlpha(dist - innerRadius) * kkEdgeAlpha(outerRadius - dist);

    // Plus sign in center when active
    float plusAlpha = 0.0;
    float plusOutlineFactor = 0.0;
    if (params->plusHalfLen > 0.0) {
        float phl = params->plusHalfLen;
        float pfhw = params->plusFillHalfWidth;
        float pow = params->plusOutlineWidth;
        float ohw = pfhw + pow;

        // Fill SDF (inner cross)
        float hFill = max(abs(pos.x) - phl, abs(pos.y) - pfhw);
        float vFill = max(abs(pos.y) - phl, abs(pos.x) - pfhw);
        float fillSDF = min(hFill, vFill);

        // Outer SDF (fill + outline)
        float hOuter = max(abs(pos.x) - (phl + pow), abs(pos.y) - ohw);
        float vOuter = max(abs(pos.y) - (phl + pow), abs(pos.x) - ohw);
        float outerSDF = min(hOuter, vOuter);

        plusAlpha = kkEdgeAlpha(-outerSDF);
        plusOutlineFactor = 1.0 - kkEdgeAlpha(-fillSDF);
    }

    if (ringAlpha < 0.001 && plusAlpha < 0.001)
        discard_fragment();

    // Ring coloring
    float4 color = float4(0.0);
    if (ringAlpha > 0.001) {
        float gapAlpha = 0.0;
        for (int i = 0; i < 4; i++) {
            float2 dividerDir = float2(cos(float(i) * M_PI_2_F), sin(float(i) * M_PI_2_F));
            float distToDivider = abs(pos.x * dividerDir.y - pos.y * dividerDir.x);
            gapAlpha = max(gapAlpha, kkLineAlpha(distToDivider, kDividerWidth));
        }
        float outlineFactor =
            max(kkLineAlpha(abs(dist - innerRadius), outlineWidth), kkLineAlpha(abs(outerRadius - dist), outlineWidth));
        color = kkOSCColor(fillColor, strokeColor, outlineFactor, gapAlpha, ringAlpha);
    }

    // Composite plus on top
    if (plusAlpha > 0.001) {
        float4 plusColor = kkOSCColor(fillColor, strokeColor, plusOutlineFactor, plusAlpha);
        color = color * (1.0 - plusColor.a) + plusColor;
    }

    return color;
}

/// Fragment shader for rendering a thin ring OSC control with fill and outline.
fragment float4 KKRingOSCFragment(KKRasterizerData in [[stage_in]],
                                  constant KKRingOSCParams *params [[buffer(KKOSCFragmentIndex_DrawColor)]]) {
    float ringRadius = params->ringRadius;
    float fillHalfWidth = params->fillHalfWidth;
    float outlineWidth = params->outlineWidth;
    float4 fillColor = float4(params->fillColor);
    float4 strokeColor = float4(params->strokeColor);

    float2 pos = in.textureCoordinate;
    float dist = length(pos);

    float ringDist = abs(dist - ringRadius);
    float outerHalfWidth = fillHalfWidth + outlineWidth;

    float shapeAlpha = kkEdgeAlpha(outerHalfWidth - ringDist);
    if (shapeAlpha < 0.001)
        discard_fragment();

    float outlineFactor = 1.0 - kkEdgeAlpha(fillHalfWidth - ringDist);

    return kkOSCColor(fillColor, strokeColor, outlineFactor, shapeAlpha);
}

/// Fragment shader for rendering a rotation arm with a handle circle at the end.
fragment float4 KKRotationOSCFragment(KKRasterizerData in [[stage_in]],
                                      constant KKRotationOSCParams *params [[buffer(KKOSCFragmentIndex_DrawColor)]]) {
    float armLength = params->armLength;
    float centerOffset = params->centerOffset;
    float circleRadius = params->circleRadius;
    float lineHalfWidth = params->lineHalfWidth;
    float outlineWidth = params->outlineWidth;
    float angle = params->angle;
    float4 fillColor = float4(params->fillColor);
    float4 strokeColor = float4(params->strokeColor);

    float2 pos = in.textureCoordinate;

    // --- Donut ring around center (hover indicator) ---
    float donutRadius = params->donutRadius;
    float4 donutColor = float4(0.0);
    if (donutRadius > 0.0) {
        float dist = length(pos);
        float donutFillHW = params->donutFillHalfWidth;
        float donutOW = params->donutOutlineWidth;
        float donutDist = abs(dist - donutRadius);
        float donutOuterHW = donutFillHW + donutOW;
        float donutShape = kkEdgeAlpha(donutOuterHW - donutDist);
        if (donutShape > 0.001) {
            float donutOutlineFactor = 1.0 - kkEdgeAlpha(donutFillHW - donutDist);
            float4 df = float4(params->donutFillColor);
            float4 ds = float4(params->donutStrokeColor);
            float3 col = mix(df.rgb, ds.rgb, donutOutlineFactor);
            float a = mix(df.a, ds.a, donutOutlineFactor) * donutShape;
            donutColor = float4(col, a);
        }

        // Marker circle at initial position on the donut ring
        float markerRadius = params->markerRadius;
        if (markerRadius > 0.0) {
            float markerAngle = params->markerAngle;
            float2 markerCenter = donutRadius * float2(cos(markerAngle), sin(markerAngle));
            float markerDist = length(pos - markerCenter);
            float markerOW = params->markerOutlineWidth;
            float markerShape = kkEdgeAlpha((markerRadius + markerOW) - markerDist);
            if (markerShape > 0.001) {
                float markerOutlineFactor = kkLineAlpha(abs(markerRadius - markerDist), markerOW);
                float4 mf = float4(params->markerFillColor);
                float4 ms = float4(params->markerStrokeColor);
                float4 markerColor = float4(mix(mf.rgb, ms.rgb, markerOutlineFactor),
                                            mix(mf.a, ms.a, markerOutlineFactor) * markerShape);
                donutColor = kkCompositeOver(markerColor, donutColor);
            }
        }
    }

    // --- Rotate into local space where the arm points along +x ---
    float cs = cos(angle);
    float sn = sin(angle);
    float2 lp = float2(pos.x * cs + pos.y * sn, -pos.x * sn + pos.y * cs);

    // Circle handle at end of arm
    float2 circleCenter = float2(armLength, 0.0);
    float circleDist = length(lp - circleCenter);
    float circleAlpha = kkEdgeAlpha(circleRadius - circleDist);
    float circleOutlineFactor = kkLineAlpha(abs(circleRadius - circleDist), outlineWidth);

    // Line segment from centerOffset to armLength (open at center end)
    float lineDist = abs(lp.y);
    float lineOuter = lineHalfWidth + outlineWidth;
    float lineAlpha =
        kkEdgeAlpha(lineOuter - lineDist) * kkEdgeAlpha(lp.x - centerOffset) * kkEdgeAlpha(armLength - lp.x);
    float lineOutlineFactor = 1.0 - kkEdgeAlpha(lineHalfWidth - lineDist);

    float totalAlpha = max(circleAlpha, lineAlpha);
    if (totalAlpha < 0.001 && donutColor.a < 0.001)
        discard_fragment();

    // Composite: line first, circle on top
    float4 color = float4(0.0);

    if (lineAlpha > 0.001) {
        color = kkOSCColor(fillColor, strokeColor, lineOutlineFactor, lineAlpha);
    }

    if (circleAlpha > 0.001) {
        float2 circleWorldCenter = float2(armLength * cos(angle), armLength * sin(angle));
        float relY = (pos - circleWorldCenter).y;
        float4 cColor = kkPointColor(fillColor, strokeColor, circleOutlineFactor, circleAlpha, relY, circleRadius,
                                     circleDist, outlineWidth);
        color = color * (1.0 - cColor.a) + cColor;
    }

    // Composite arm/circle over donut
    if (donutColor.a > 0.001) {
        color = kkCompositeOver(color, donutColor);
    }

    return color;
}

/// Fragment shader for an antialiased line. textureCoordinate.y encodes
/// signed distance from the line center in normalized units (-1 to 1).
fragment float4 KKLineFragment(KKRasterizerData in [[stage_in]],
                               constant float4 *color [[buffer(KKOSCFragmentIndex_DrawColor)]]) {
    float dist = abs(in.textureCoordinate.y);
    float alpha = 1.0 - smoothstep(1.0 - fwidth(dist) * 2.0, 1.0, dist);
    if (alpha < 0.001)
        discard_fragment();
    return float4(color->rgb * alpha, alpha);
}

/// Fragment shader for rendering a text label texture.
fragment float4 KKLabelFragment(KKRasterizerData in [[stage_in]], texture2d<float> labelTexture [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    return labelTexture.sample(s, in.textureCoordinate);
}

/// Fragment shader for rendering a point/dot OSC control with outline and depth shadow.
fragment float4 KKPointOSCFragment(KKRasterizerData in [[stage_in]],
                                   constant KKPointOSCParams *params [[buffer(KKOSCFragmentIndex_DrawColor)]]) {
    float outerRadius = 1.0;
    float outlineWidth = params->outlineWidth;
    float4 fillColor = float4(params->fillColor);
    float4 strokeColor = float4(params->strokeColor);

    float2 pos = in.textureCoordinate;
    float dist = length(pos);

    float circleAlpha = kkEdgeAlpha(outerRadius - dist);
    if (circleAlpha < 0.001)
        discard_fragment();

    float outlineFactor = kkLineAlpha(abs(outerRadius - dist), outlineWidth);

    return kkPointColor(fillColor, strokeColor, outlineFactor, circleAlpha, pos.y, outerRadius, dist, outlineWidth);
}
