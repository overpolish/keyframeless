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

fragment float4 fragmentShader(RasterizerData in [[stage_in]],
                               texture2d<half> colorTexture [[texture(KKTextureIndex_InputImage)]],
                               constant float *radius [[buffer(FragmentIndex_Radius)]],
                               constant float2 *imageSize [[buffer(FragmentIndex_ImageSize)]],
                               constant float2 *tileOffsetPx [[buffer(FragmentIndex_TileOffsetPx)]],
                               constant float2 *cropCenter [[buffer(FragmentIndex_CropCenter)]],
                               constant float2 *cropSize [[buffer(FragmentIndex_CropSize)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

    // Source sampling: dest texture = source tile (in-place effect), so
    // tile-normalized UV is just framebuffer-pixel / texture-size.
    float2 textureSize = float2(colorTexture.get_width(), colorTexture.get_height());
    float2 sampleUV = in.clipSpacePosition.xy / textureSize;
    half4 colorSample = colorTexture.sample(textureSampler, sampleUV);

    // Y-down screen-pixel position in the final composited image.
    // tileOffsetPx places this fragment at the right spot regardless of
    // whether FCP composites the full image or a sub-tile.
    float2 pixelInFullImage = in.clipSpacePosition.xy + (*tileOffsetPx);

    // Crop bounding box: center of image + crop offset, sized by cropSize
    float2 imageCenter = (*imageSize) * 0.5;
    float2 boxCenter = imageCenter + (*cropCenter);
    float2 halfSize = (*cropSize) * 0.5;

    float2 pos = pixelInFullImage - boxCenter;

    float scaledRadius = (*radius / 100.0) * min(halfSize.x, halfSize.y);

    float alpha;

    if (scaledRadius < 0.5) {
        float2 d = abs(pos) - halfSize;
        float distance = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
        alpha = 1.0 - smoothstep(0.0, fwidth(distance) * 2.0, distance);
    } else {
        float2 insetSize = max(halfSize - scaledRadius, 0.0);
        float2 q = max(abs(pos) - insetSize, 0.0) / scaledRadius;
        float t = *radius / 100.0;
        float power = mix(5.0, 2.0, t);
        float distance = pow(pow(q.x, power) + pow(q.y, power), 1.0 / power) - 1.0;
        alpha = 1.0 - smoothstep(0.0, fwidth(distance) * 2.0, distance);
    }

    float sourceAlpha = colorSample.a;
    float combinedAlpha = sourceAlpha * alpha;
    return float4(float3(colorSample.rgb) * alpha, combinedAlpha);
}
