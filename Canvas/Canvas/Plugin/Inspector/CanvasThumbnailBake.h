/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@class CanvasMiniViewerRenderer;

NS_ASSUME_NONNULL_BEGIN

/// Renders a deterministic poster of this clip for the expression-picker menu
/// (the Canvas twin of MirageRenderThumbnailJPEGFromSource): the clip's real
/// footage from the mini feed (`source`; nil composites over black) with the
/// layer stack on top, pinned to fraction 0.5, JPEG-encoded at w x h.
/// `onlyLayerID` non-nil isolates ONE layer (plus its ancestor groups, so the
/// group transform still applies; a hidden layer is shown) - the per-layer
/// picker thumbnail. A GROUP layerID renders the group with all its nested
/// members (individually-hidden members stay hidden). Synchronous,
/// main-thread; the renderer's live state is saved and restored around the
/// bake.
NSData *_Nullable CanvasRenderThumbnailJPEG(CanvasMiniViewerRenderer *renderer,
                                            NSUInteger w, NSUInteger h,
                                            id<MTLTexture> _Nullable source,
                                            NSString *_Nullable onlyLayerID);

NS_ASSUME_NONNULL_END
