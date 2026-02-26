//
//  Rounded.metal
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;


#include <KeyframelessKit/KKShaderTypes.h>
#include "RoundedShaderTypes.h"

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} RasterizerData;


vertex RasterizerData vertexShader(
                                   uint vertexID [[vertex_id]],
                                   constant KKVertex2D *vertexArray [[buffer(KKVertexInputIndex_Vertices)]],
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
    
    float2 center = (*imageSize) * 0.5;
    float2 pos = pixelInFullImage - center;
    
    float2 halfSize = (*imageSize) * 0.5;
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
    
    return float4(float3(colorSample.rgb) * alpha, alpha);
}
