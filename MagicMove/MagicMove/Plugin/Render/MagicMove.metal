/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#include "ShaderTypes.h"
#include "RenderSupportTypes.h"
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} RasterizerData;

vertex RasterizerData vertexShader(uint vertexID [[vertex_id]],
                                   constant RSRenderVertex2D *vertexArray [[buffer(RSRenderVertexIndexVertices)]],
                                   constant vector_uint2 *viewportSizePointer
                                   [[buffer(RSRenderVertexIndexViewportSize)]]) {
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
                               constant MMTransform &transform [[buffer(0)]],
                               texture2d<half> colorTexture [[texture(0)]]) {
    if (transform.scale <= 0 || transform.scaleY <= 0) return float4(0);
    // The destination image is larger than the frame whenever the transform
    // carries content outside it, so convert to frame coordinates first.
    float2 frame = transform.frameOrigin + in.textureCoordinate * transform.frameScale;
    float2 p = frame - 0.5 - transform.offset;
    // The pivot is a fraction of the full frame, so it lands in the same place
    // at any render resolution and under any tiling the host chooses.
    p -= transform.anchor;
    // Orthographic projection of the source plane after local-axis scaling
    // and Euler rotation Rz * Ry * Rx. The inverse 2x2 projection maps the
    // destination sample back into the source texture.
    float cx=cos(transform.rotationX), sx=sin(transform.rotationX);
    float cy=cos(transform.rotationY), sy=sin(transform.rotationY);
    float cz=cos(transform.rotation), sz=sin(transform.rotation);
    float a=cz*cy*transform.aspect*transform.scale;
    float b=(cz*sy*sx-sz*cx)*transform.scaleY;
    float c=sz*cy*transform.aspect*transform.scale;
    float d=(sz*sy*sx+cz*cx)*transform.scaleY;
    float determinant=a*d-b*c;
    // The plane is edge-on when either projected cosine vanishes. Keep the
    // determinant fallback tight so valid very small scales remain renderable.
    if (fabs(cx*cy) < 1.0e-6 || fabs(determinant) < 1.0e-12) return float4(0);
    p.x *= transform.aspect;
    float2 source = float2((d*p.x-b*p.y)/determinant,
                           (-c*p.x+a*p.y)/determinant);
    source += transform.anchor;
    // Everything above is full-frame space. The delivered source tile may
    // cover only part of that frame, so map into the texture's own space; a
    // sample the host did not hand over falls outside it and reads as empty,
    // exactly like a sample outside the image.
    float2 uv = (source + 0.5 - transform.sourceOrigin) / transform.sourceSize;
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear,
                                     address::clamp_to_zero);
    return float4(colorTexture.sample(textureSampler, uv)) * clamp(transform.opacity, 0.0f, 1.0f);
}
