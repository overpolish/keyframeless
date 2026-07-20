/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@class KKMiniViewerRenderer;

NS_ASSUME_NONNULL_BEGIN

/// Render a still preview of the shader the mini-viewer `renderer` currently
/// describes (its timeline / values) into a `w`x`h` JPEG, sampling a synthetic
/// test-pattern source on iChannel0 so texture-processing shaders have detail.
/// Returns nil if Metal is unavailable. Used to bake `preview.jpg` on save +
/// publish, so a catalog entry shows what the shader looks like.
FOUNDATION_EXPORT NSData *_Nullable ShaderRenderThumbnailJPEG(
    KKMiniViewerRenderer *renderer, NSUInteger w, NSUInteger h);

/// Deterministic thumbnail rendered on a SPECIFIC source texture (the clip's
/// real footage, loaded headless from the mini-viewer feed) at a fixed clip
/// fraction (0.5), restoring the renderer's live time after. Pass a nil
/// `source` for a generator (it re-renders on the bundled reference). Used by
/// the link reference-menu bake, where the inspector has no live canvas to
/// capture from.
FOUNDATION_EXPORT NSData *_Nullable ShaderRenderThumbnailJPEGFromSource(
    KKMiniViewerRenderer *renderer, NSUInteger w, NSUInteger h,
    id<MTLTexture> _Nullable source);

NS_ASSUME_NONNULL_END
