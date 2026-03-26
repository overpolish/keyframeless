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
    float4 outlineColor = float4(params->outlineColor);

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
        color = kkOSCColor(fillColor, outlineColor, outlineFactor, gapAlpha, ringAlpha);
    }

    // Composite plus on top
    if (plusAlpha > 0.001) {
        float4 plusColor = kkOSCColor(fillColor, outlineColor, plusOutlineFactor, plusAlpha);
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
    float4 outlineColor = float4(params->outlineColor);

    float2 pos = in.textureCoordinate;
    float dist = length(pos);

    float ringDist = abs(dist - ringRadius);
    float outerHalfWidth = fillHalfWidth + outlineWidth;

    float shapeAlpha = kkEdgeAlpha(outerHalfWidth - ringDist);
    if (shapeAlpha < 0.001)
        discard_fragment();

    float outlineFactor = 1.0 - kkEdgeAlpha(fillHalfWidth - ringDist);

    return kkOSCColor(fillColor, outlineColor, outlineFactor, shapeAlpha);
}

/// Fragment shader for rendering a point/dot OSC control with outline and depth shadow.
fragment float4 KKPointOSCFragment(KKRasterizerData in [[stage_in]],
                                   constant KKPointOSCParams *params [[buffer(KKOSCFragmentIndex_DrawColor)]]) {
    float outerRadius = 1.0;
    float outlineWidth = params->outlineWidth;
    float4 fillColor = float4(params->fillColor);
    float4 outlineColor = float4(params->outlineColor);

    float2 pos = in.textureCoordinate;
    float dist = length(pos);

    float circleAlpha = kkEdgeAlpha(outerRadius - dist);
    if (circleAlpha < 0.001)
        discard_fragment();

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
