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
    
    float2 pixelSpacePosition = vertexArray[vertexID].position.xy;
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
                                  constant float *params [[buffer(ROFI_DrawColor)]])
{
    float innerRadius = params[0];
    float outerRadius = params[1];
    float gapAngle = params[2];
    float outlineWidth = params[3];
    float4 fillColor = float4(params[4], params[5], params[6], 1.0);
    float4 outlineColor = float4(0.0, 0.0, 0.0, 1.0);
    
    float2 pos = in.textureCoordinate;
    float dist = length(pos);
    
    float angle = atan2(pos.y, pos.x);
    if (angle < 0.0) {
        angle += 2.0 * M_PI_F;
    }
    
    // AA parameters
    float delta = fwidth(dist);
    float halfDelta = delta * 0.5;
    
    // Find which arc we're in and calculate angular distance
    float arcSize = M_PI_2_F - gapAngle;
    float minPerpendicularDist = 1000.0;
    float minAngularDist = 1000.0;
    bool inArc = false;
    
    for (int i = 0; i < 4; i++) {
        float arcStart = float(i) * M_PI_2_F + gapAngle * 0.5;
        float arcEnd = arcStart + arcSize;
        
        // Check if we're near this arc
        float distToArcStart = angle - arcStart;
        float distToArcEnd = arcEnd - angle;
        
        // Handle angle wrapping
        if (distToArcStart < 0.0) distToArcStart += 2.0 * M_PI_F;
        if (distToArcEnd < 0.0) distToArcEnd += 2.0 * M_PI_F;
        
        if (angle >= arcStart && angle <= arcEnd) {
            float2 startEdgeDir = float2(cos(arcStart), sin(arcStart));
            float2 endEdgeDir = float2(cos(arcEnd), sin(arcEnd));
            
            float distToStart = abs(pos.x * startEdgeDir.y - pos.y * startEdgeDir.x);
            float distToEnd = abs(pos.x * endEdgeDir.y - pos.y * endEdgeDir.x);
            
            minPerpendicularDist = min(distToStart, distToEnd);
            minAngularDist = min(min(distToArcStart, distToArcEnd) * dist, minPerpendicularDist);
            inArc = true;
            break;
        }
    }
    
    // Anti-aliased arc boundaries
    float arcAlpha = 1.0;
    if (inArc) {
        float angularDelta = fwidth(minPerpendicularDist);
        arcAlpha = smoothstep(-angularDelta, angularDelta, minPerpendicularDist);
    } else {
        arcAlpha = 0.0;
    }
    
    // Anti-aliased radial boundaries
    float innerEdgeDist = dist - innerRadius;
    float outerEdgeDist = outerRadius - dist;
    
    float innerAlpha = smoothstep(-halfDelta, halfDelta, innerEdgeDist);
    float outerAlpha = smoothstep(-halfDelta, halfDelta, outerEdgeDist);
    
    // Combine all alpha values
    float shapeAlpha = innerAlpha * outerAlpha * arcAlpha;
    
    // Early discard for fully transparent pixels
    if (shapeAlpha < 0.001) {
        discard_fragment();
    }
    
    // Calculate distances for outline
    float distToInner = abs(innerEdgeDist);
    float distToOuter = abs(outerEdgeDist);
    
    // Outline blend factors with AA
    float innerOutlineFactor = 1.0 - smoothstep(outlineWidth - halfDelta, outlineWidth + halfDelta, distToInner);
    float outerOutlineFactor = 1.0 - smoothstep(outlineWidth - halfDelta, outlineWidth + halfDelta, distToOuter);
    float angularOutlineFactor = 1.0 - smoothstep((outlineWidth * 0.5) - halfDelta,
                                                   (outlineWidth * 0.5) + halfDelta,
                                                   minPerpendicularDist);
    
    float outlineFactor = max(max(innerOutlineFactor, outerOutlineFactor), angularOutlineFactor);
    
    // Blend color with outline
    float4 color = mix(fillColor, outlineColor, outlineFactor);
    
    // Apply anti-aliased alpha
    color.a = shapeAlpha;
    
    return color;
}
