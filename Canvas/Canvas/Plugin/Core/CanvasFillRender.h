/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@class KKBezierPath;
@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// TEMP solid-fill rendering for closed vector paths (SVG fills, boolean /
/// outline results). A proper fill (gradients, antialiased edges, sketch
/// styles) is a later feature; this draws a flat solid fill so filled shapes
/// are visible at all. Ported from the pre-v3 stencil even-odd approach
/// (handles holes + concave shapes), pared down to one solid colour and reusing
/// the kit's KKTransformVertexShader + KKSolidColorFragment (no new .metal).

/// A scratch Stencil8 texture sized to the render tile, cached per process
/// (each FxPlug instance is its own XPC process, so a static is per-instance).
/// Recreated when the tile size or device changes. Returns nil on failure.
id<MTLTexture> _Nullable CanvasFillStencilTexture(id<MTLDevice> device,
                                                  NSUInteger width,
                                                  NSUInteger height);

/// Build (and cache on the shared KKMetalDeviceCache) the two pipelines + two
/// depth-stencil states the fill pass needs. Any out-param is left nil on
/// failure (e.g. the kit Metal library is unavailable); the caller skips fills.
void CanvasFillBuildPipelines(
    id<MTLDevice> device, uint64_t registryID, MTLPixelFormat pixelFormat,
    id<MTLRenderPipelineState> _Nullable *_Nonnull outStencilPS,
    id<MTLRenderPipelineState> _Nullable *_Nonnull outColorPS,
    id<MTLDepthStencilState> _Nullable *_Nonnull outStencilDS,
    id<MTLDepthStencilState> _Nullable *_Nonnull outColorDS);

/// Draw the solid fill for every fill-enabled (non-image / non-group) layer
/// with stencil-based even-odd winding. Runs its own stencil + colour render
/// passes on `commandBuffer` over `outputTexture` (loaded, not cleared), so
/// call it after the image / stroke composite has been committed to that
/// texture. `stencilTexture` must match the render TILE size.
/// `imageWidth/Height` + `tileShift` match the values handed to
/// CanvasEncodeVectorLayers; `tileWidth/ Height` are the destination tile
/// dimensions (the shader viewport).
void CanvasEncodeFilledLayers(
    NSArray<KKBezierPath *> *layers, id<MTLDevice> device,
    id<MTLCommandBuffer> commandBuffer, id<MTLTexture> outputTexture,
    id<MTLTexture> stencilTexture, id<MTLRenderPipelineState> fillStencilPS,
    id<MTLRenderPipelineState> fillColorPS,
    id<MTLDepthStencilState> fillStencilDS,
    id<MTLDepthStencilState> fillColorDS, float imageWidth, float imageHeight,
    float tileWidth, float tileHeight, float tileShiftX, float tileShiftY,
    double frac, NSString *_Nullable overrideLayerID,
    KKTimeline *_Nullable overrideTimeline);

NS_ASSUME_NONNULL_END
