//
//  Rounded.metal
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;


#include <KeyframelessKit/ShaderTypes.h>
#include "RoundedShaderTypes.h"

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} RasterizerData;


vertex RasterizerData vertexShader(
                                   uint vertexID [[vertex_id]],
                                   constant KeyframelessKitVertex2D *vertexArray [[buffer(KKVertexInputIndex_Vertices)]],
                                   constant vector_uint2 *viewportSizePointer [[buffer(KKVertexInputIndex_ViewportSize)]])
{
    RasterizerData out;
    
    float2 pixelSpacePosition = vertexArray[vertexID].position.xy;
    float2 viewportSize = float2(*viewportSizePointer);
    
    out.clipSpacePosition.xy = pixelSpacePosition / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;
    
    return out;
}

/// Return rounded corner distance using signed distance function.
float roundedBoxSDF(float2 centerPosition, float2 size, float radius) {
    return length(max(abs(centerPosition) - size + radius, 0.0)) - radius;
}

fragment float4 fragmentShader(RasterizerData in [[stage_in]],
                               texture2d<half> colorTexture [[texture(KKTextureIndex_InputImage)]],
                               constant float* radius [[buffer(RFragmentIndex_Radius)]],
                               constant float2* imageSize [[buffer(RFragmentIndex_ImageSize)]],
                               constant float2* tileOffset [[buffer(RFragmentIndex_TileOffset)]])
{
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    
    half4 colorSample = colorTexture.sample(textureSampler, in.textureCoordinate);
    
    float2 tileSize = float2(colorTexture.get_width(), colorTexture.get_height());
    float2 pixelInTile = in.textureCoordinate * tileSize;
    float2 pixelInFullImage = pixelInTile + (*tileOffset);
    
    // Position from center of full image
    float2 center = (*imageSize) * 0.5;
    float2 pos = pixelInFullImage - center;
    
    // Distance to rounded rectangle edge
    float2 halfSize = (*imageSize) * 0.5;
    float scaledRadius = (*radius / 100.0) * min(halfSize.x, halfSize.y);
    float distance = roundedBoxSDF(pos, halfSize, scaledRadius);
    
    float alpha = 1.0 - smoothstep(0.0, 1.0, distance);
    
    return float4(float3(colorSample.rgb) * alpha, alpha);
}
