/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@class KKBezierPath;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

/// Reads `kParamLayerData` (action-scoped) and returns the decoded layer stack,
/// or an empty array when there's no data. `target` is the action identity
/// token (pass the host-recognized plugin where available; nil is tolerated for
/// reads). Used by the inspector to feed the mini-viewer renderer and by the
/// layer list to load its rows - one source of truth for decoding the blob.
NSMutableArray<KKBezierPath *> *CanvasReadLayerPaths(
    id<PROAPIAccessing> _Nullable api, id _Nullable target);

/// Draws every visible image layer as a textured quad over whatever the encoder
/// already drew, back-to-front (array index 0 = topmost, drawn last). The
/// caller must have set an image pipeline (kit `KKVertexShader` + premultiplied
/// passthrough fragment) on `encoder` and bound the viewport-size buffer at
/// `KKVertexInputIndex_ViewportSize`; this only re-sets the per-quad vertex
/// buffer + texture. Object space is normalized [0,1] with Y=0 at the bottom,
/// mapped across `outputWidth` x `outputHeight`. Non-image / hidden / group /
/// non-rect layers are skipped. Shared by the main render and the mini-viewer
/// so both composite identically.
void CanvasEncodeImageLayers(
    NSArray<KKBezierPath *> *layers, id<MTLRenderCommandEncoder> encoder,
    id<MTLDevice> device,
    NSMutableDictionary<NSString *, id<MTLTexture>> *cache, float outputWidth,
    float outputHeight);

NS_ASSUME_NONNULL_END
