/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Render-side source feed for a mini-canvas preview, reusable by any plugin.
///
/// Owns one persistent `IOSurface`-backed `MTLTexture` (long edge capped),
/// MPS-downscales the effect's source frame into it on full-frame render
/// ticks, and publishes a tiny JSON descriptor file so a `KKMiniCanvasView`
/// — which lives in the separate ViewBridge process and cannot see an
/// `MTLTexture` from the render XPC — can `IOSurfaceLookup` the ID and
/// composite it in its own process. The descriptor path is the cross-process
/// rendezvous; the plugin picks it and points its `KKMiniCanvasView` at the
/// same path.
@interface KKMiniCanvasFeed : NSObject

/// `descriptorPath`: the `/tmp` file this feed publishes and the matching
/// `KKMiniCanvasView.sourceDescriptorPath` consumes. Single-instance
/// assumption — one path per plugin.
- (instancetype)initWithDescriptorPath:(NSString *)descriptorPath;

/// Downscale the full source frame into the persistent surface and publish
/// the descriptor. Safe to call every full-frame render tick — it
/// self-throttles and skips when nothing changed. Caller must pass a
/// full-frame source texture (not a sub-tile) and the device/queue the
/// texture lives on.
- (void)updateWithSourceTexture:(id<MTLTexture>)sourceTexture
                         device:(id<MTLDevice>)device
                   commandQueue:(id<MTLCommandQueue>)commandQueue;

@end

NS_ASSUME_NONNULL_END
