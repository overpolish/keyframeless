/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include "ShaderTypes.h"
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

typedef struct {
    float4 clipSpacePosition [[position]];
    float edgeDistance;
} StrokeRasterizerData;

vertex StrokeRasterizerData strokeVertexShader(uint vertexID [[vertex_id]],
                                               constant CanvasVertex *vertexArray [[buffer(0)]],
                                               constant vector_uint2 *viewportSizePointer [[buffer(1)]]) {
    StrokeRasterizerData out;

    float2 pixelSpacePosition = vertexArray[vertexID].position;
    float2 viewportSize = float2(*viewportSizePointer);

    out.clipSpacePosition.xy = pixelSpacePosition / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    out.edgeDistance = vertexArray[vertexID].edgeDistance;

    return out;
}

fragment float4 strokeFragmentShader(StrokeRasterizerData in [[stage_in]]) {
    float dist = abs(in.edgeDistance);
    float fw = fwidth(in.edgeDistance) * 1.5;
    float alpha = 1.0 - smoothstep(1.0 - fw, 1.0, dist);
    return float4(1.0, 0.0, 0.0, 1.0) * alpha;
}
