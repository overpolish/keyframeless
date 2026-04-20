/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>
#import <Metal/Metal.h>

/// Load (or retrieve from cache) an image texture from disk.
id<MTLTexture> _Nullable KKGetOrLoadImageTexture(NSString *_Nullable path,
                                                 id<MTLDevice> _Nonnull device);

/// Apply fill tint to an image texture via Core Image.
id<MTLTexture> _Nonnull KKApplyImageFill(id<MTLTexture> _Nonnull rawTexture,
                                         KKBezierPath *_Nonnull path,
                                         id<MTLDevice> _Nonnull device,
                                         id<MTLCommandBuffer> _Nonnull cb);

/// Apply stroke outline to an image via JFA distance field. The returned
/// texture may be padded larger than the input.
id<MTLTexture> _Nonnull KKApplyImageStroke(id<MTLTexture> _Nonnull srcTexture,
                                           KKBezierPath *_Nonnull path,
                                           id<MTLDevice> _Nonnull device,
                                           id<MTLCommandBuffer> _Nonnull cb);

/// Apply a sketch fill pattern to an image, masked by its alpha channel.
id<MTLTexture> _Nonnull KKApplyImageSketchFill(
    id<MTLTexture> _Nonnull rawTexture, KKBezierPath *_Nonnull path,
    id<MTLDevice> _Nonnull device, id<MTLCommandBuffer> _Nonnull cb);

/// Apply fill and/or stroke effects to a raw image texture.
/// Returns the raw texture unchanged when no effects are enabled.
id<MTLTexture> _Nonnull KKProcessImageWithEffects(
    id<MTLTexture> _Nonnull rawTexture, KKBezierPath *_Nonnull path,
    id<MTLDevice> _Nonnull device, id<MTLCommandBuffer> _Nonnull cb);
