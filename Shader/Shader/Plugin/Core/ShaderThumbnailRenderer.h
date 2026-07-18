/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>

@class KKMiniViewerRenderer;

NS_ASSUME_NONNULL_BEGIN

/// Render a still preview of the shader the mini-viewer `renderer` currently
/// describes (its timeline / values) into a `w`x`h` JPEG, sampling a synthetic
/// test-pattern source on iChannel0 so texture-processing shaders have detail.
/// Returns nil if Metal is unavailable. Used to bake `preview.jpg` on save +
/// publish, so a catalog entry shows what the shader looks like.
FOUNDATION_EXPORT NSData *_Nullable ShaderRenderThumbnailJPEG(
    KKMiniViewerRenderer *renderer, NSUInteger w, NSUInteger h);

NS_ASSUME_NONNULL_END
