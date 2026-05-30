/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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

// Solid-color triangle with anti-aliased edges via barycentric coordinates.
// Each vertex should have textureCoordinate set to one of (1,0), (0,1), (0,0).
// The minimum barycentric component gives distance-to-edge which is smoothed.
fragment float4 triangleFragment(RasterizerData in [[stage_in]], constant float4 *color [[buffer(0)]]) {
    float2 bary2 = in.textureCoordinate;
    float bary3 = 1.0 - bary2.x - bary2.y;
    float edge = min(bary2.x, min(bary2.y, bary3));
    float aa = smoothstep(0.0, fwidth(edge) * 1.5, edge);
    return *color * aa;
}

fragment float4 fragmentShader(RasterizerData in [[stage_in]],
                               texture2d<half> colorTexture [[texture(KKTextureIndex_InputImage)]],
                               constant MagicMoveParams *params [[buffer(FragmentIndex_Params)]],
                               constant float2 *tileOffsetPx [[buffer(FragmentIndex_TileOffsetPx)]]) {
    // Source is the full source image (sourceTileRect returns
    // imagePixelBounds), so colorTexture dims == image dims. Use the
    // fragment's framebuffer position + tile offset (Y-down, FCP's project-
    // library convention) to recover the normalized centered position
    // regardless of whether we're rendering full-image or a sub-tile.
    float2 imageSizePx = float2(colorTexture.get_width(), colorTexture.get_height());
    float2 pixelInImage = in.clipSpacePosition.xy + (*tileOffsetPx);
    float2 p = pixelInImage / imageSizePx - 0.5;

    p -= params->translate;

    float2 anchor = params->anchorOffset;
    p -= anchor;

    float aspect = float(colorTexture.get_width()) / float(colorTexture.get_height());
    p.x *= aspect;

    // True 3D rotation: R = Ry * Rx * Rz applied to the source image plane.
    // The shader's screen-space p is Y-DOWN (FCP image-pixel convention)
    // but the OSC visualizes rings in math Y-UP convention, so we flip p.y
    // at input and the result's y at output. That way the same R matrix
    // produces visually-matching rotations on both sides (the ring you drag
    // in the OSC corresponds 1:1 to how the image spins).
    float cx = cos(params->rotationX), sx = sin(params->rotationX);
    float cy = cos(params->rotationY), sy = sin(params->rotationY);
    float cz = cos(params->rotation), sz = sin(params->rotation);
    float3 col0 = float3(cy * cz + sy * sx * sz, cx * sz, -sy * cz + cy * sx * sz);
    float3 col1 = float3(-cy * sz + sy * sx * cz, cx * cz, sy * sz + cy * sx * cz);
    float3 col2 = float3(sy * cx, -sx, cy * cx);
    float camD = 2.0;
    float3 Oworld = float3(0.0, 0.0, -camD);
    float3 Dworld = float3(p.x, -p.y, camD); // Y-up world coords.
    float3 O = float3(dot(col0, Oworld), dot(col1, Oworld), dot(col2, Oworld));
    float3 D = float3(dot(col0, Dworld), dot(col1, Dworld), dot(col2, Dworld));
    if (abs(D.z) < 0.0001)
        return float4(0.0);
    float tHit = -O.z / D.z;
    p = float2(O.x + tHit * D.x, -(O.y + tHit * D.y)); // flip back to Y-down

    p.x /= aspect;

    if (abs(params->scaleX) < 0.001 || abs(params->scaleY) < 0.001)
        return float4(0.0);
    p.x /= params->scaleX;
    p.y /= params->scaleY;

    p += anchor;

    float2 src = p + 0.5;

    float2 fw = fwidth(src);
    float edgeAA = smoothstep(0.0, fw.x, src.x) * smoothstep(0.0, fw.x, 1.0 - src.x) * smoothstep(0.0, fw.y, src.y) *
                   smoothstep(0.0, fw.y, 1.0 - src.y);

    if (edgeAA <= 0.0)
        return float4(0.0);

    constexpr sampler s(mag_filter::linear, min_filter::linear);
    half4 c = colorTexture.sample(s, src);
    return float4(c) * params->opacity * edgeAA;
}
