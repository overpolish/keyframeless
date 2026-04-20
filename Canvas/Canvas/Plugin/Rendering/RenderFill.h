/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
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
void KKRenderFillForPath(KKBezierPath *_Nonnull path, float outputWidth,
                         float outputHeight, id<MTLDevice> _Nonnull device,
                         id<MTLCommandBuffer> _Nonnull commandBuffer,
                         id<MTLTexture> _Nonnull outputTexture,
                         id<MTLTexture> _Nonnull stencilTexture,
                         id<MTLRenderPipelineState> _Nonnull fillStencilPS,
                         id<MTLRenderPipelineState> _Nonnull fillColorPS,
                         id<MTLDepthStencilState> _Nonnull fillStencilDSState,
                         id<MTLDepthStencilState> _Nonnull fillColorDSState,
                         simd_uint2 viewportSize);

/// Write the shape stencil only (no color pass). Used to clip sketch fills.
void KKRenderFillStencilOnly(
    KKBezierPath *_Nonnull path, float outputWidth, float outputHeight,
    id<MTLDevice> _Nonnull device, id<MTLCommandBuffer> _Nonnull commandBuffer,
    id<MTLTexture> _Nonnull outputTexture,
    id<MTLTexture> _Nonnull stencilTexture,
    id<MTLRenderPipelineState> _Nonnull fillStencilPS,
    id<MTLDepthStencilState> _Nonnull fillStencilDSState,
    simd_uint2 viewportSize);

/// Render sketch fill (hachure, cross-hatch, zigzag, dots) for a path.
void KKRenderSketchFillForPath(
    KKBezierPath *_Nonnull origPath, float outputWidth, float outputHeight,
    id<MTLDevice> _Nonnull device, id<MTLCommandBuffer> _Nonnull commandBuffer,
    id<MTLTexture> _Nonnull outputTexture,
    id<MTLTexture> _Nullable stencilTexture,
    id<MTLRenderPipelineState> _Nonnull strokePS,
    id<MTLDepthStencilState> _Nullable fillColorDSState,
    simd_uint2 viewportSize, BOOL useStencilClip);
