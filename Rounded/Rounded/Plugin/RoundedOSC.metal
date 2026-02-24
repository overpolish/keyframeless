//
//  RoundedOSC.metal
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

#include "RoundedShaderTypes.h"

typedef struct
{
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} RasterizerData;

vertex RasterizerData
OSCVertexShader(uint vertexID [[vertex_id]],
                constant Vertex2D *vertexArray [[buffer(RVI_Vertices)]],
                constant vector_uint2 *viewportSizePointer [[buffer(RVI_ViewportSize)]])
{
    RasterizerData out;
    
    // Get the pixel space position
    float2 pixelSpacePosition = vertexArray[vertexID].position.xy;
    
    // Get viewport size
    float2 viewportSize = float2(*viewportSizePointer);
    
    // Convert to clip space (-1 to 1)
    out.clipSpacePosition.xy = pixelSpacePosition / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    
    // Pass through texture coordinate
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;
    
    return out;
}

fragment float4 OSCFragmentShader(RasterizerData in [[stage_in]],
                                  constant float4 *color [[buffer(ROFI_DrawColor)]])
{
    return *color;
}
