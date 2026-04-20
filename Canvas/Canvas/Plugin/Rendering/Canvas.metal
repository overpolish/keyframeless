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
    float capDistance;
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
    out.capDistance = vertexArray[vertexID].capDistance;

    return out;
}

fragment float4 strokeFragmentShader(StrokeRasterizerData in [[stage_in]], constant float4 *strokeColor [[buffer(0)]]) {
    float edgeDist = abs(in.edgeDistance);
    float edgeFw = fwidth(in.edgeDistance) * 1.5;
    float edgeAlpha = 1.0 - smoothstep(1.0 - edgeFw, 1.0, edgeDist);

    float capFw = fwidth(in.capDistance) * 1.5;
    float capAlpha = 1.0 - smoothstep(1.0 - capFw, 1.0, in.capDistance);

    return *strokeColor * edgeAlpha * capAlpha;
}

typedef struct {
    float4 clipSpacePosition [[position]];
} FillRasterizerData;

vertex FillRasterizerData fillVertexShader(uint vertexID [[vertex_id]],
                                           constant CanvasFillVertex *vertexArray [[buffer(0)]],
                                           constant vector_uint2 *viewportSizePointer [[buffer(1)]]) {
    FillRasterizerData out;
    float2 viewportSize = float2(*viewportSizePointer);
    out.clipSpacePosition.xy = vertexArray[vertexID].position / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    return out;
}

fragment float4 fillFragmentShader(FillRasterizerData in [[stage_in]], constant float4 *fillColor [[buffer(0)]]) {
    return *fillColor;
}

// Composite shader: draws a fullscreen quad sampling an intermediate texture,
// multiplied by an opacity value.  Used so that per-object opacity is applied
// once to the flattened fill+stroke instead of per-primitive.

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 texCoord;
} CompositeRasterizerData;

vertex CompositeRasterizerData compositeVertexShader(uint vertexID [[vertex_id]]) {
    // Fullscreen triangle strip: 4 vertices → 2 triangles via triangle_strip
    float2 positions[4] = {{-1, -1}, {1, -1}, {-1, 1}, {1, 1}};
    float2 texCoords[4] = {{0, 1}, {1, 1}, {0, 0}, {1, 0}};

    CompositeRasterizerData out;
    out.clipSpacePosition = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 compositeFragmentShader(CompositeRasterizerData in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                        constant float *opacity [[buffer(0)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);
    float4 color = tex.sample(s, in.texCoord);
    return color * *opacity;
}

// Image shader: draws a positioned quad sampling an image texture with opacity.

typedef struct {
    float4 clipSpacePosition [[position]];
    float2 texCoord;
} ImageRasterizerData;

vertex ImageRasterizerData imageVertexShader(uint vertexID [[vertex_id]],
                                             constant CanvasFillVertex *vertexArray [[buffer(0)]],
                                             constant vector_uint2 *viewportSizePointer [[buffer(1)]]) {
    // Triangle strip: 4 vertices (BL, BR, TL, TR)
    // Image data is top-down, so BL maps to bottom of texture (v=1),
    // TL maps to top of texture (v=0).
    float2 texCoords[4] = {{0, 0}, {1, 0}, {0, 1}, {1, 1}};

    ImageRasterizerData out;
    float2 viewportSize = float2(*viewportSizePointer);
    out.clipSpacePosition.xy = vertexArray[vertexID].position / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 imageFragmentShader(ImageRasterizerData in [[stage_in]], texture2d<float> tex [[texture(0)]],
                                    constant float *opacity [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float4 color = tex.sample(s, in.texCoord);
    return float4(color.rgb * color.a, color.a) * *opacity;
}

// --- JFA (Jump Flooding Algorithm) for image stroke outlines ---

kernel void jfaSeedInit(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    uint w = src.get_width();
    uint h = src.get_height();
    if (gid.x >= w || gid.y >= h)
        return;

    float a = src.read(gid).a;
    bool isEdge = false;
    if (a > 0.5) {
        float aL = (gid.x > 0) ? src.read(uint2(gid.x - 1, gid.y)).a : 0.0;
        float aR = (gid.x < w - 1) ? src.read(uint2(gid.x + 1, gid.y)).a : 0.0;
        float aU = (gid.y > 0) ? src.read(uint2(gid.x, gid.y - 1)).a : 0.0;
        float aD = (gid.y < h - 1) ? src.read(uint2(gid.x, gid.y + 1)).a : 0.0;
        isEdge = (aL <= 0.5 || aR <= 0.5 || aU <= 0.5 || aD <= 0.5);
    }
    if (isEdge) {
        dst.write(float4(float(gid.x), float(gid.y), 0, 0), gid);
    } else {
        dst.write(float4(-1.0, -1.0, 0, 0), gid);
    }
}

kernel void jfaFloodPass(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]], constant int &stepSize [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    int w = src.get_width();
    int h = src.get_height();
    if (int(gid.x) >= w || int(gid.y) >= h)
        return;

    float2 bestSeed = src.read(gid).xy;
    float bestDist = 1e20;
    if (bestSeed.x >= 0.0) {
        float2 diff = float2(gid) - bestSeed;
        bestDist = dot(diff, diff);
    }

    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 nb = int2(gid) + int2(dx, dy) * stepSize;
            if (nb.x < 0 || nb.x >= w || nb.y < 0 || nb.y >= h)
                continue;
            float2 seed = src.read(uint2(nb)).xy;
            if (seed.x < 0.0)
                continue;
            float2 diff = float2(gid) - seed;
            float d = dot(diff, diff);
            if (d < bestDist) {
                bestDist = d;
                bestSeed = seed;
            }
        }
    }
    dst.write(float4(bestSeed, 0, 0), gid);
}

kernel void jfaComposite(texture2d<float, access::read> srcTex [[texture(0)]],
                         texture2d<float, access::read> jfaTex [[texture(1)]],
                         texture2d<float, access::write> dstTex [[texture(2)]], constant float &radius [[buffer(0)]],
                         constant float4 &strokeColor [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
    uint w = srcTex.get_width();
    uint h = srcTex.get_height();
    if (gid.x >= w || gid.y >= h)
        return;

    float4 src = srcTex.read(gid);
    float2 seed = jfaTex.read(gid).xy;

    if (seed.x < 0.0) {
        dstTex.write(src, gid);
        return;
    }

    float2 diff = float2(gid) - seed;
    float dist = length(diff);

    float outlineAlpha = 1.0 - smoothstep(radius - 1.0, radius, dist);
    float4 outline = float4(strokeColor.rgb * outlineAlpha, outlineAlpha);

    // Composite: source over outline (both premultiplied)
    float4 result = src + outline * (1.0 - src.a);
    dstTex.write(result, gid);
}
