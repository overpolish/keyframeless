/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@class FxImageTile;

NS_ASSUME_NONNULL_BEGIN

/// Composites the diagonal trial watermark over `destTexture` when
/// `productID` (see KKLicense.h) has not been activated, treating the texture
/// as a WHOLE frame (mini-viewer previews, thumbnails). `topDown` for a texture
/// whose row 0 is the TOP of the image (the mini-viewer / offscreen
/// convention); NO for an FCP destination surface, which is bottom-up. No-op
/// once the product is activated.
FOUNDATION_EXPORT void
KKWatermarkEncodeIfUnlicensed(NSString *productID,
                              id<MTLCommandBuffer> commandBuffer,
                              id<MTLTexture> destTexture, BOOL topDown);

/// Tile-aware variant: the pattern is built for the FULL image and this tile
/// draws only its own sub-rect of it, so a frame split into several tiles
/// carries one continuous watermark instead of one copy per tile.
FOUNDATION_EXPORT void
KKWatermarkEncodeIfUnlicensedForTile(NSString *productID,
                                     id<MTLCommandBuffer> commandBuffer,
                                     id<MTLTexture> destTexture,
                                     FxImageTile *destinationImage);

/// Convenience for the common case: runs the watermark in its own command
/// buffer against the destination tile, blocking until done. Call after a
/// successful render, from renderDestinationImage:'s exit. No-op once the
/// product is activated.
FOUNDATION_EXPORT void
KKWatermarkApplyIfUnlicensed(NSString *productID,
                             FxImageTile *destinationImage);

NS_ASSUME_NONNULL_END
