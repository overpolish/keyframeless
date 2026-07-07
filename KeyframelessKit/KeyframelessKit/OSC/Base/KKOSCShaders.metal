/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
    float2 radii = float2(params->ringRadiusX, params->ringRadiusY);
    float fillHalfWidth = params->fillHalfWidth;
    float outlineWidth = params->outlineWidth;
    float4 fillColor = float4(params->fillColor);
    float4 strokeColor = float4(params->strokeColor);

    float2 pos = in.textureCoordinate;
    // Implicit ellipse: f(p) = (x/a)^2 + (y/b)^2 - 1
    // Approximate distance to boundary: |f| / |grad f|
    float2 pr = pos / radii;
    float f = dot(pr, pr) - 1.0;
    float2 grad = 2.0 * pos / (radii * radii);
    float gradLen = length(grad);
    float ringDist = (gradLen > 0.0001) ? abs(f) / gradLen : 0.0;
    float outerHalfWidth = fillHalfWidth + outlineWidth;

    float shapeAlpha = kkEdgeAlpha(outerHalfWidth - ringDist);
    if (shapeAlpha < 0.001)
        discard_fragment();

    float outlineFactor = 1.0 - kkEdgeAlpha(fillHalfWidth - ringDist);

    return kkOSCColor(fillColor, strokeColor, outlineFactor, shapeAlpha);
}

/// 3-ring sphere rotation gizmo. Samples each great-circle (the ring of one
/// axis projected to screen) as a polyline and picks the closest ring per
/// pixel; back-hemisphere half is alpha-dimmed via the sign of the world Z
/// at the closest point.
fragment float4 KKRotationOSCFragment(KKRasterizerData in [[stage_in]],
                                      constant KKRotationOSCParams *params [[buffer(KKOSCFragmentIndex_DrawColor)]]) {
    // The OSC quad has metalPosition.y flipped (see KKOnScreenControl
    // encodeRenderCommands), so textureCoordinate.y is already Y-DOWN
    // relative to canvas. The renderer also works in Y-DOWN screen space,
    // and the hit-test mirrors that (negating canvas-Y when forming its
    // local point), so all three agree without needing a flip here.
    float2 pos = in.textureCoordinate;

    float3 col0 = float3(params->rotCol0);
    float3 col1 = float3(params->rotCol1);
    float3 col2 = float3(params->rotCol2);
    float radius = params->radius;
    float ringHW = params->ringHalfWidth;
    float outlineW = params->outlineWidth;
    float backDim = params->backDim;
    float4 outlineColor = float4(params->outlineColor);
    int active = params->activeRing;
    float activeBoost = params->activeBoost;
    float4 ringColors[3];
    ringColors[0] = float4(params->ringColorX);
    ringColors[1] = float4(params->ringColorY);
    ringColors[2] = float4(params->ringColorZ);

    // X ring spans the world Y/Z basis; Y ring spans X/Z; Z ring spans X/Y.
    // (The axis's own column is its normal, which is dropped here.)
    float3 ringU[3];
    float3 ringV[3];
    ringU[0] = col1;
    ringV[0] = col2;
    ringU[1] = col0;
    ringV[1] = col2;
    ringU[2] = col0;
    ringV[2] = col1;

    const int N = 64;
    const float twoPi = 6.28318530718;

    // Track FRONT (z<=0) and BACK (z>0) winners separately. The hit-test
    // prefers front-only samples across all rings, so when a back segment of
    // ring A is geometrically closer than a front segment of ring B at the
    // same pixel, hit-test still grabs ring B. We mirror that here: if any
    // ring's front passes within ring range, render that front ring;
    // otherwise fall back to the closest back-facing ring (dimmed). Result:
    // the bright (grabbable) half is what's visible at every pixel.
    float frontBestDist = 1.0e9;
    int frontBestRing = -1;
    float backBestDist = 1.0e9;
    int backBestRing = -1;
    float backBestZ = 0.0;

    for (int k = 0; k < 3; k++) {
        if (params->ringVisible[k] <= 0.0) {
            continue; // ring hidden via the OSC-visibility popover
        }
        float3 prev = radius * ringU[k]; // t = 0
        for (int i = 1; i <= N; i++) {
            float t = twoPi * (float(i) / float(N));
            float3 cur = radius * (cos(t) * ringU[k] + sin(t) * ringV[k]);
            float2 a = prev.xy;
            float2 b = cur.xy;
            float2 d = b - a;
            float L2 = max(dot(d, d), 1.0e-9);
            float u = clamp(dot(pos - a, d) / L2, 0.0, 1.0);
            float2 closest = a + u * d;
            float dist = length(pos - closest);
            float zAt = prev.z + u * (cur.z - prev.z);
            if (zAt <= 0.0) {
                if (dist < frontBestDist) {
                    frontBestDist = dist;
                    frontBestRing = k;
                }
            } else {
                if (dist < backBestDist) {
                    backBestDist = dist;
                    backBestRing = k;
                    backBestZ = zAt;
                }
            }
            prev = cur;
        }
    }

    float outerHW = ringHW + outlineW;
    int bestRing = -1;
    float bestDist = 0.0;
    float bestZ = 0.0;
    if (frontBestRing >= 0 && frontBestDist <= outerHW + 0.002) {
        bestRing = frontBestRing;
        bestDist = frontBestDist;
        bestZ = 0.0; // force "front" → no dimming
    } else if (backBestRing >= 0 && backBestDist <= outerHW + 0.002) {
        bestRing = backBestRing;
        bestDist = backBestDist;
        bestZ = backBestZ;
    } else {
        discard_fragment();
    }

    float shapeAlpha = kkEdgeAlpha(outerHW - bestDist);
    float outlineFactor = 1.0 - kkEdgeAlpha(ringHW - bestDist);

    float4 fill = ringColors[bestRing];
    if (bestRing == active) {
        fill.rgb = mix(fill.rgb, float3(1.0, 1.0, 1.0), activeBoost);
    }

    float4 color = kkOSCColor(fill, outlineColor, outlineFactor, shapeAlpha);

    // z > 0 is BEHIND the source plane from the camera at z = -camD; that's
    // the back hemisphere that should fade. z <= 0 is closer to the camera
    // and stays full brightness.
    if (bestZ > 0.0) {
        color *= backDim;
    }

    // ringVisible doubles as a per-ring alpha multiplier: 1.0 = normal, a low
    // value (e.g. 0.3) draws the ring as a dimmed "ghost" during opt-reveal.
    // color is premultiplied, so scaling the whole vector dims it correctly.
    color *= params->ringVisible[bestRing];

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
    float a = alpha * color->a;
    return float4(color->rgb * a, a);
}

/// Like KKLineFragment but filled with a gradient instead of a solid colour.
/// textureCoordinate.y is the signed edge distance (AA, same as KKLineFragment);
/// textureCoordinate.x is the gradient position 0..1, which the caller bakes per
/// vertex (so the gradient geometry - linear / radial across a bbox - is decided
/// CPU-side and this shader just samples). buffer 0 = the gradient LUT
/// (KK_GRADIENT_LUT_SIZE sRGB float3 samples, from KKColorLanesResolve); buffer
/// 1 = opacity. Output is premultiplied to match the line pipeline's blend.
fragment float4 KKGradientLineFragment(KKRasterizerData in [[stage_in]],
                                       constant float3 *lut [[buffer(0)]],
                                       constant float *opacity [[buffer(1)]]) {
    float dist = abs(in.textureCoordinate.y);
    float alpha = 1.0 - smoothstep(1.0 - fwidth(dist) * 2.0, 1.0, dist);
    if (alpha < 0.001)
        discard_fragment();
    const int n = 64; // == KK_GRADIENT_LUT_SIZE (KKColor.h)
    float lutPos = saturate(in.textureCoordinate.x) * float(n - 1);
    int i0 = int(floor(lutPos));
    int i1 = min(i0 + 1, n - 1);
    // LUT is sRGB; the render works in linear space, so linearise before output
    // (same pow(2.2) Glow applies to its gradient + solid colour).
    float3 rgb = pow(mix(lut[i0], lut[i1], lutPos - float(i0)), 2.2);
    float a = alpha * (*opacity);
    return float4(rgb * a, a);
}

/// Fragment shader for rendering a text label texture.
fragment float4 KKLabelFragment(KKRasterizerData in [[stage_in]], texture2d<float> labelTexture [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    return labelTexture.sample(s, in.textureCoordinate);
}

/// Signed distance to a rounded rectangle centered at the origin.
inline float kkRoundedRectSDF(float2 p, float2 halfSize, float cornerRadius) {
    float2 d = abs(p) - halfSize + cornerRadius;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - cornerRadius;
}

/// Fragment shader for rendering an anchor point OSC as a rounded square with
/// drop shadow and outline, similar to the point OSC style.
fragment float4 KKSquarePointOSCFragment(KKRasterizerData in [[stage_in]], constant KKSquarePointOSCParams *params
                                         [[buffer(KKOSCFragmentIndex_DrawColor)]]) {
    float cornerRadius = params->cornerRadius;
    float outlineWidth = params->outlineWidth;
    float shadowOffset = params->shadowOffset;
    float shadowRadius = params->shadowRadius;
    float4 fillColor = float4(params->fillColor);
    float4 strokeColor = float4(params->strokeColor);
    float4 shadowColor = float4(params->shadowColor);

    float2 pos = in.textureCoordinate;

    float halfSize = 1.0 - outlineWidth;

    // Shadow (offset downward)
    float2 shadowPos = pos - float2(0.0, shadowOffset);
    float shadowDist = kkRoundedRectSDF(shadowPos, float2(halfSize), cornerRadius);
    float shadowAlpha = shadowColor.a * (1.0 - smoothstep(-shadowRadius, 0.0, shadowDist));

    // Main shape
    float dist = kkRoundedRectSDF(pos, float2(halfSize), cornerRadius);
    float shapeAlpha = kkEdgeAlpha(-dist);

    if (shapeAlpha < 0.001 && shadowAlpha < 0.001)
        discard_fragment();

    // Start with shadow
    float4 color = float4(shadowColor.rgb * shadowAlpha, shadowAlpha);

    // Composite shape on top
    if (shapeAlpha > 0.001) {
        float outlineFactor = 1.0 - kkEdgeAlpha(-(dist + outlineWidth));
        float4 shapeColor = kkOSCColor(fillColor, strokeColor, outlineFactor, shapeAlpha);
        color = color * (1.0 - shapeColor.a) + shapeColor;
    }

    return color;
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
