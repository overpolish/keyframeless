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
/// `productID` (see KKLicense.h) has not been activated. Call once at the end
/// of renderDestinationImage:, on the same command buffer as the final pass.
/// No-op once the product is activated.
FOUNDATION_EXPORT void
KKWatermarkEncodeIfUnlicensed(NSString *productID,
                              id<MTLCommandBuffer> commandBuffer,
                              id<MTLTexture> destTexture);

/// Convenience for the common case: runs the watermark in its own command
/// buffer against the destination tile, blocking until done. Call after a
/// successful render, from renderDestinationImage:'s exit. No-op once the
/// product is activated.
FOUNDATION_EXPORT void
KKWatermarkApplyIfUnlicensed(NSString *productID,
                             FxImageTile *destinationImage);

NS_ASSUME_NONNULL_END
