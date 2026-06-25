/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKShaderTypes.h> // KKVertex2D
#import <Metal/Metal.h>
#import <simd/simd.h>

@class KKBezierPath;
@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// Flatten every contour of `geom` into a triangle fan (one fan per contour
/// from its own centroid) in CENTERED-PIXEL object space ((norm - 0.5) * (w,
/// h)). Returns the triangle COUNT; mallocs `*outVerts` (count*3 verts, a
/// triangle LIST) which the caller frees, and fills `outMin`/`outMax` with the
/// point bbox. The render strokes it via even-odd stencil; the hit-test reuses
/// it so a click matches the drawn fill (a point covered by an ODD number of
/// fan triangles is inside).
NSUInteger CanvasBuildFillFan(KKBezierPath *geom, float w, float h,
                              KKVertex2D *_Nullable *_Nonnull outVerts,
                              simd_float2 *outMin, simd_float2 *outMax);

/// Fill rendering for closed vector paths (shapes, SVG fills, boolean / outline
/// results): a stencil even-odd fill (holes + concave) of a solid colour or
/// bbox gradient, rasterised MULTISAMPLED and resolved so the silhouette is
/// antialiased, then composited over the dest.

/// The fill pass's pipelines + depth-stencil states, built once and threaded as
/// a unit. `mask*` are the image-layer hachure variants (clip to the image
/// alpha). Pointers are unretained (the KKMetalDeviceCache owns them); the
/// struct is a stack value passed by address for the synchronous encode.
typedef struct {
  __unsafe_unretained id<MTLRenderPipelineState> stencil;
  __unsafe_unretained id<MTLRenderPipelineState> color;
  __unsafe_unretained id<MTLRenderPipelineState> gradient;
  __unsafe_unretained id<MTLRenderPipelineState> composite;
  __unsafe_unretained id<MTLRenderPipelineState> colorMask;
  __unsafe_unretained id<MTLRenderPipelineState> gradientMask;
  __unsafe_unretained id<MTLDepthStencilState> stencilDS;
  __unsafe_unretained id<MTLDepthStencilState> colorDS;
} CanvasFillPipelines;

/// Build (and cache on the shared KKMetalDeviceCache) the fill pipelines into
/// `outPipelines` (zeroed on failure, e.g. the kit Metal library is
/// unavailable). The caller skips fills when `stencil`/`color`/`composite` are
/// nil (a nil `gradient`/`*Mask` just disables that one variant).
void CanvasFillBuildPipelines(id<MTLDevice> device, uint64_t registryID,
                              MTLPixelFormat pixelFormat,
                              CanvasFillPipelines *outPipelines);

/// Draw the fill for every fill-enabled (non-group) layer. Each layer
/// rasterises its even-odd fan into an internal 4x multisample target, resolves
/// to a 1x texture (coverage AA), and the composite pipeline blits that over
/// `outputTexture` (loaded, not cleared) - so call it after the image / stroke
/// composite is on that texture. `textureCache` supplies the image alpha for an
/// image-layer hachure (its silhouette mask). `imageWidth/Height` + `tileShift`
/// match the values handed to CanvasEncodeVectorLayers; `tileWidth/Height` are
/// the destination tile dimensions (the shader viewport + MSAA target size).
void CanvasEncodeFilledLayers(
    NSArray<KKBezierPath *> *layers, id<MTLDevice> device,
    NSMutableDictionary<NSString *, id<MTLTexture>> *_Nullable textureCache,
    id<MTLCommandBuffer> commandBuffer, id<MTLTexture> outputTexture,
    const CanvasFillPipelines *pipelines, float imageWidth, float imageHeight,
    float tileWidth, float tileHeight, float tileShiftX, float tileShiftY,
    double frac, NSString *_Nullable overrideLayerID,
    KKTimeline *_Nullable overrideTimeline);

NS_ASSUME_NONNULL_END
