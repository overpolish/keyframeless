/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "ShaderTypes.h"
#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>

/// Build a stencil triangle fan for a path, one fan per contour.
/// Caller must free *outVerts.
NSUInteger KKBuildFillFan(KKBezierPath *_Nonnull path, float outputWidth,
                          float outputHeight,
                          CanvasFillVertex *_Nullable *_Nonnull outVerts);

/// Render fill for a path using stencil-based even-odd winding.
/// `pathXform` is bound at vertex/fragment buffer slot 2 for the stencil
/// pass; the color pass uses identity on the vertex (fullscreen quad must
/// stay in screen space) but `pathXform.mInv` on the fragment so the
/// gradient samples in the path's local pixel space.
void KKRenderFillForPath(KKBezierPath *_Nonnull path,
                         CanvasPathTransform pathXform, float outputWidth,
                         float outputHeight, id<MTLDevice> _Nonnull device,
                         id<MTLCommandBuffer> _Nonnull commandBuffer,
                         id<MTLTexture> _Nonnull outputTexture,
                         id<MTLTexture> _Nonnull stencilTexture,
                         id<MTLRenderPipelineState> _Nonnull fillStencilPS,
                         id<MTLRenderPipelineState> _Nonnull fillColorPS,
                         id<MTLDepthStencilState> _Nonnull fillStencilDSState,
                         id<MTLDepthStencilState> _Nonnull fillColorDSState,
                         simd_uint2 viewportSize);

/// Draw a hairline AA ribbon along the polygon outline using the fill color
/// and gradient. Run after KKRenderFillForPath to feather silhouette edges.
/// The ribbon overlaps the fill on its inner half (idempotent in
/// premultiplied source-over) and feathers off the outer half.
void KKRenderFillAAOutline(KKBezierPath *_Nonnull path,
                           CanvasPathTransform pathXform, float outputWidth,
                           float outputHeight, id<MTLDevice> _Nonnull device,
                           id<MTLCommandBuffer> _Nonnull commandBuffer,
                           id<MTLTexture> _Nonnull outputTexture,
                           id<MTLRenderPipelineState> _Nonnull strokePS,
                           simd_uint2 viewportSize);

/// Write the shape stencil only (no color pass). Used to clip sketch fills.
void KKRenderFillStencilOnly(
    KKBezierPath *_Nonnull path, CanvasPathTransform pathXform,
    float outputWidth, float outputHeight, id<MTLDevice> _Nonnull device,
    id<MTLCommandBuffer> _Nonnull commandBuffer,
    id<MTLTexture> _Nonnull outputTexture,
    id<MTLTexture> _Nonnull stencilTexture,
    id<MTLRenderPipelineState> _Nonnull fillStencilPS,
    id<MTLDepthStencilState> _Nonnull fillStencilDSState,
    simd_uint2 viewportSize);

/// Render sketch fill (hachure, cross-hatch, zigzag, dots) for a path.
void KKRenderSketchFillForPath(
    KKBezierPath *_Nonnull origPath, CanvasPathTransform pathXform,
    float outputWidth, float outputHeight, id<MTLDevice> _Nonnull device,
    id<MTLCommandBuffer> _Nonnull commandBuffer,
    id<MTLTexture> _Nonnull outputTexture,
    id<MTLTexture> _Nullable stencilTexture,
    id<MTLRenderPipelineState> _Nonnull strokePS,
    id<MTLDepthStencilState> _Nullable fillColorDSState,
    simd_uint2 viewportSize, BOOL useStencilClip);
