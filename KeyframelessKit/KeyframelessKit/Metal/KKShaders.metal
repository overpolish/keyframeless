/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKShaderTypes.h"
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

/// Standard vertex shader for OSC controls and quads.
vertex KKRasterizerData KKVertexShader(uint vertexID [[vertex_id]],
                                       constant KKVertex2D *vertexArray [[buffer(KKVertexInputIndex_Vertices)]],
                                       constant vector_uint2 *viewportSizePointer
                                       [[buffer(KKVertexInputIndex_ViewportSize)]]) {
    KKRasterizerData out;

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
