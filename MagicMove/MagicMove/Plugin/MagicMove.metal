/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "ShaderTypes.h"
#include <KeyframelessKit/KKShaderTypes.h>
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} RasterizerData;

vertex RasterizerData vertexShader(uint vertexID [[vertex_id]],
                                   constant KKVertex2D *vertexArray [[buffer(KKVertexInputIndex_Vertices)]],
                                   constant vector_uint2 *viewportSizePointer
                                   [[buffer(KKVertexInputIndex_ViewportSize)]]) {
    RasterizerData out;

    float2 pixelSpacePosition = vertexArray[vertexID].position.xy;
    float2 viewportSize = float2(*viewportSizePointer);

    out.clipSpacePosition.xy = pixelSpacePosition / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;

    return out;
}

fragment float4 fragmentShader(RasterizerData in [[stage_in]],
                               texture2d<half> colorTexture [[texture(KKTextureIndex_InputImage)]],
                               constant MagicMoveParams *params [[buffer(FragmentIndex_Params)]]) {
    float2 p = in.textureCoordinate - 0.5;

    p -= params->translate;

    float aspect = float(colorTexture.get_width()) / float(colorTexture.get_height());
    p.x *= aspect;
    float cs = cos(params->rotation);
    float sn = sin(params->rotation);
    p = float2(cs * p.x - sn * p.y, sn * p.x + cs * p.y);

    // 3D rotation (X/Y) with perspective via ray-plane intersection.
    // Camera at (0,0,-camD), ray through screen point, inverse-rotated into
    // source image space and intersected with z=0.
    float sinRX = sin(params->rotationX), cosRX = cos(params->rotationX);
    float sinRY = sin(params->rotationY), cosRY = cos(params->rotationY);
    float camD = 2.0;

    float3 O = float3(camD * sinRY * cosRX, -camD * sinRX, -camD * cosRY * cosRX);
    float3 D = float3(p.x * cosRY + p.y * sinRY * sinRX - camD * sinRY * cosRX, p.y * cosRX + camD * sinRX,
                      p.x * sinRY - p.y * cosRY * sinRX + camD * cosRY * cosRX);

    if (abs(D.z) < 0.0001)
        return float4(0.0);
    float tHit = -O.z / D.z;
    p = float2(O.x + tHit * D.x, O.y + tHit * D.y);

    p.x /= aspect;

    if (abs(params->scaleX) < 0.001 || abs(params->scaleY) < 0.001)
        return float4(0.0);
    p.x /= params->scaleX;
    p.y /= params->scaleY;

    float2 src = p + 0.5;

    if (src.x < 0.0 || src.x > 1.0 || src.y < 0.0 || src.y > 1.0)
        return float4(0.0);

    constexpr sampler s(mag_filter::linear, min_filter::linear);
    half4 c = colorTexture.sample(s, src);
    return float4(c) * params->opacity;
}
