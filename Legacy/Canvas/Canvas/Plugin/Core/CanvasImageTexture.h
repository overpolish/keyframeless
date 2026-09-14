/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Loads the image at `path` into a premultiplied-sRGB MTLTexture, caching the
/// result in `cache` keyed by path. Returns nil if the file can't be decoded.
/// The texture is stored top-row-first (v=0 is the top of the image), so it
/// uploads upright for a standard top-left UV quad. A cached entry bound to a
/// different device is rebuilt.
id<MTLTexture> _Nullable CanvasImageTextureForPath(
    NSString *path, id<MTLDevice> device,
    NSMutableDictionary<NSString *, id<MTLTexture>> *cache);

NS_ASSUME_NONNULL_END
