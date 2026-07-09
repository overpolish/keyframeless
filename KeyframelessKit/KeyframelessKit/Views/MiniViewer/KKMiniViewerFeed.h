/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Render-side source feed for a mini-viewer preview, reusable by any plugin.
///
/// Owns one persistent `IOSurface`-backed `MTLTexture` (long edge capped),
/// MPS-downscales the effect's source frame into it on full-frame render
/// ticks, and publishes a tiny JSON descriptor file so a `KKMiniViewerView`
/// - which lives in the separate ViewBridge process and cannot see an
/// `MTLTexture` from the render XPC - can `IOSurfaceLookup` the ID and
/// composite it in its own process. The descriptor path is the cross-process
/// rendezvous; the plugin picks it and points its `KKMiniViewerView` at the
/// same path.
@interface KKMiniViewerFeed : NSObject

/// `descriptorPath`: the `/tmp` file this feed publishes and the matching
/// `KKMiniViewerView.sourceDescriptorPath` consumes. Single-instance
/// assumption - one path per plugin.
- (instancetype)initWithDescriptorPath:(NSString *)descriptorPath;

/// Downscale the full source frame into the persistent surface and publish
/// the descriptor. Safe to call every full-frame render tick - it
/// self-throttles and skips when nothing changed. Caller must pass a
/// full-frame source texture (not a sub-tile) and the device/queue the
/// texture lives on.
///
/// Slot 0 of a single-slot feed (default), backward-compatible with
/// non-onion-skin callers.
- (void)updateWithSourceTexture:(id<MTLTexture>)sourceTexture
                         device:(id<MTLDevice>)device
                   commandQueue:(id<MTLCommandQueue>)commandQueue;

#pragma mark - Multi-slot (onion-skin)

/// Number of independent IOSurface slots managed by this feed. Each slot
/// holds one source frame at one time, published as a separate entry in the
/// descriptor's `slots` array. Default is 1 (single-slot behavior). Setting
/// a different count discards excess slots and resets unmatched
/// per-frame-tag state.
@property(nonatomic) NSUInteger slotCount;

/// Per-slot variant. `tag` is an opaque caller-supplied value (e.g. the
/// fraction the slot represents) written into the descriptor so consumers
/// can match slots to keyposes. Throttled per slot independently.
- (void)updateSlot:(NSUInteger)slot
    withSourceTexture:(id<MTLTexture>)sourceTexture
                  tag:(double)tag
               device:(id<MTLDevice>)device
         commandQueue:(id<MTLCommandQueue>)commandQueue;

/// Output media pixel size, for a GENERATOR with no source frames to carry it.
/// When set (and there are no published slots), `publishDescriptor` writes a
/// dims-only descriptor (`srcWidth`/`srcHeight`, empty `slots`) so a consuming
/// `KKMiniViewerView` resolves `sourceMediaSize` - which px-scaled value fields
/// need. Ignored once real source slots are published (they carry their own).
@property(nonatomic) CGSize mediaSize;

/// Publish whatever state the feed currently has (no surface update). Used
/// when only `slotCount` changes - consumers need a fresh descriptor.
- (void)publishDescriptor;

@end

NS_ASSUME_NONNULL_END
