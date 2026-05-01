/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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

// Sample the gradient at a pixel given in the same coordinate space as
// `p.bboxMin`/`p.bboxMax`. Linear pivots through the bbox center for any
// angle; radial reaches t=1 at every bbox edge (elliptical distance).
static float3 sampleCanvasGradientAtPixel(constant CanvasGradientParams &p, float2 pixel) {
    float2 bbCenter = (p.bboxMin + p.bboxMax) * 0.5;
    float2 bbSize = max(p.bboxMax - p.bboxMin, float2(1.0));
    float2 uv = (pixel - bbCenter) / bbSize; // [-0.5, 0.5]

    float t;
    if (p.gradientType == 1) {
        float ca = cos(p.gradientAngle);
        float sa = sin(p.gradientAngle);
        t = saturate(uv.x * ca - uv.y * sa + 0.5);
    } else {
        t = saturate(length(uv) * 2.0);
    }

    float lutPos = t * float(KK_GRADIENT_LUT_SIZE - 1);
    int idx0 = int(floor(lutPos));
    int idx1 = min(idx0 + 1, KK_GRADIENT_LUT_SIZE - 1);
    float3 srgb = mix(p.lut[idx0], p.lut[idx1], lutPos - float(idx0));
    return pow(srgb, 2.2);
}

// Fragment-shader entry: framebuffer pixel → centered-pixel space (matching
// the canvas vertex shader's coordinates) before sampling.
static float3 sampleCanvasGradient(constant CanvasGradientParams &p, float2 fbPixel, float2 viewport) {
    return sampleCanvasGradientAtPixel(p, fbPixel - viewport * 0.5);
}

fragment float4 strokeFragmentShader(StrokeRasterizerData in [[stage_in]],
                                     constant CanvasGradientParams &params [[buffer(0)]],
                                     constant vector_uint2 *viewportSizePointer [[buffer(1)]]) {
    float edgeDist = abs(in.edgeDistance);
    float edgeFw = fwidth(in.edgeDistance) * 1.5;
    float edgeAlpha = 1.0 - smoothstep(1.0 - edgeFw, 1.0, edgeDist);

    float capFw = fwidth(in.capDistance) * 1.5;
    float capAlpha = 1.0 - smoothstep(1.0 - capFw, 1.0, in.capDistance);

    float coverage = edgeAlpha * capAlpha;
    if (params.useGradient != 0) {
        float3 rgb = sampleCanvasGradient(params, in.clipSpacePosition.xy, float2(*viewportSizePointer));
        float a = params.opacity * coverage;
        return float4(rgb * a, a);
    }
    return params.solidColor * coverage;
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

fragment float4 fillFragmentShader(FillRasterizerData in [[stage_in]],
                                   constant CanvasGradientParams &params [[buffer(0)]],
                                   constant vector_uint2 *viewportSizePointer [[buffer(1)]]) {
    if (params.useGradient != 0) {
        float3 rgb = sampleCanvasGradient(params, in.clipSpacePosition.xy, float2(*viewportSizePointer));
        float a = params.opacity;
        return float4(rgb * a, a);
    }
    return params.solidColor;
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

// Generate a flat gradient texture sized to the image bounds.
// Used by image-fill tinting so gradient fill mode replaces the solid tint.
kernel void gradientFillKernel(texture2d<float, access::write> dst [[texture(0)]],
                               constant CanvasGradientParams &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint w = dst.get_width();
    uint h = dst.get_height();
    if (gid.x >= w || gid.y >= h)
        return;

    float3 rgb = sampleCanvasGradientAtPixel(p, float2(gid));
    dst.write(float4(rgb, 1.0), gid);
}

// --- JFA (Jump Flooding Algorithm) for image stroke outlines ---

kernel void jfaSeedInit(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
    uint w = src.get_width();
    uint h = src.get_height();
    if (gid.x >= w || gid.y >= h)
        return;

    // Read a 3x3 neighborhood and apply a binomial (1-2-1)² filter. For
    // binary-alpha source images the smoothed alpha varies smoothly across
    // the boundary, restoring sub-pixel info that would otherwise be lost.
    float aTL = (gid.x > 0 && gid.y > 0) ? src.read(uint2(gid.x - 1, gid.y - 1)).a : 0.0;
    float aT = (gid.y > 0) ? src.read(uint2(gid.x, gid.y - 1)).a : 0.0;
    float aTR = (gid.x < w - 1 && gid.y > 0) ? src.read(uint2(gid.x + 1, gid.y - 1)).a : 0.0;
    float aL = (gid.x > 0) ? src.read(uint2(gid.x - 1, gid.y)).a : 0.0;
    float aC = src.read(gid).a;
    float aR = (gid.x < w - 1) ? src.read(uint2(gid.x + 1, gid.y)).a : 0.0;
    float aBL = (gid.x > 0 && gid.y < h - 1) ? src.read(uint2(gid.x - 1, gid.y + 1)).a : 0.0;
    float aB = (gid.y < h - 1) ? src.read(uint2(gid.x, gid.y + 1)).a : 0.0;
    float aBR = (gid.x < w - 1 && gid.y < h - 1) ? src.read(uint2(gid.x + 1, gid.y + 1)).a : 0.0;

    float a = (aTL + 2.0 * aT + aTR + 2.0 * aL + 4.0 * aC + 2.0 * aR + aBL + 2.0 * aB + aBR) * (1.0 / 16.0);

    // Sample axis-direction smoothed alphas the same way to keep gradient
    // estimation consistent with the smoothed center.
    float aLs = (aTL + 2.0 * aL + aBL) * (1.0 / 4.0);
    float aRs = (aTR + 2.0 * aR + aBR) * (1.0 / 4.0);
    float aTs = (aTL + 2.0 * aT + aTR) * (1.0 / 4.0);
    float aBs = (aBL + 2.0 * aB + aBR) * (1.0 / 4.0);

    // A pixel is part of the boundary if its smoothed alpha sits between 0
    // and 1, OR if it is opaque next to a transparent neighbor (raw alpha
    // covers the case where smoothing pushes a near-edge pixel just past 0.5).
    bool isPartial = (a > 0.01 && a < 0.99);
    bool isOpaqueEdge = (aC > 0.5) && (aL <= 0.5 || aR <= 0.5 || aT <= 0.5 || aB <= 0.5);
    bool isEdge = isPartial || isOpaqueEdge;

    if (isEdge) {
        // Estimate edge offset from pixel center using the alpha gradient.
        // Boundary is the α = 0.5 isocontour; first-order expansion places
        // it at -(α - 0.5) / |∇α| along the gradient direction.
        float gx = (aRs - aLs) * 0.5;
        float gy = (aBs - aTs) * 0.5;
        float gMag = sqrt(gx * gx + gy * gy);
        float2 sub = float2(0.5);
        if (gMag > 0.001) {
            float t = clamp(-(a - 0.5) / gMag, -0.75, 0.75);
            sub += float2(gx, gy) / gMag * t;
        }
        dst.write(float4(float(gid.x) + sub.x, float(gid.y) + sub.y, 0, 0), gid);
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
                         constant float4 &strokeColor [[buffer(1)]],
                         constant CanvasGradientParams &gradParams [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
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

    // Seeds are sub-pixel positions; compare against this pixel's center.
    float2 diff = (float2(gid) + 0.5) - seed;
    float dist = length(diff);

    float outlineAlpha = 1.0 - smoothstep(radius - 1.0, radius, dist);

    float3 outlineRGB;
    if (gradParams.useGradient != 0) {
        outlineRGB = sampleCanvasGradientAtPixel(gradParams, float2(gid)) * gradParams.opacity;
    } else {
        outlineRGB = strokeColor.rgb;
    }

    float4 outline = float4(outlineRGB * outlineAlpha, outlineAlpha);

    // Composite: source over outline (both premultiplied)
    float4 result = src + outline * (1.0 - src.a);
    dstTex.write(result, gid);
}
