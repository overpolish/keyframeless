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

#pragma mark - Channel 1 (a second texture)

/// Publish a SECOND source texture, independent of the slots.
///
/// Slots mean "the same source at different times" (onion-skin / filmstrip),
/// and `slotCount` moves with the caller's preview mode - so a second *texture*
/// can't live there without its index shifting underfoot. This gets its own
/// persistent surface and its own `channel1` descriptor key, absent entirely
/// when never called, so existing feeds are unaffected.
///
/// Used by Shader for the "To" image well (the incoming clip of a transition),
/// which the mini-viewer needs to preview a two-texture shader. Same contract
/// as `-updateWithSourceTexture:`: full-frame texture, self-throttling.
- (void)updateChannel1WithSourceTexture:(id<MTLTexture>)sourceTexture
                                 device:(id<MTLDevice>)device
                           commandQueue:(id<MTLCommandQueue>)commandQueue;

/// Output media pixel size, for a GENERATOR with no source frames to carry it.
/// When set (and there are no published slots), `publishDescriptor` writes a
/// dims-only descriptor (`srcWidth`/`srcHeight`, empty `slots`) so a consuming
/// `KKMiniViewerView` resolves `sourceMediaSize` - which px-scaled value fields
/// need. Ignored once real source slots are published (they carry their own).
@property(nonatomic) CGSize mediaSize;

/// Live playhead fraction (0..1) at publish time, or < 0 when unknown / not
/// playing. Published as `playheadFrac` in the descriptor.
///
/// FCP renders a CONSTANT ~0.27s (16-20 frames at 60fps) ahead of the playhead,
/// so a slot's own `tag` - correct for its pixels - is that far ahead of where
/// the viewer actually is, and an animation previewed at the tag visibly starts
/// early. Truly delaying the frames would mean buffering ~20 surfaces (~9MB
/// each), so instead a live-playback consumer evaluates the EFFECT at this
/// fraction while still drawing the delivered pixels. Measured, not assumed.
@property(nonatomic) double playheadFrac;

/// Largest source frame size seen by the publish gate, for a FILTER path. FCP
/// re-runs the same instance at a tiny project-library / browser-thumbnail size
/// (~112x64, ~same aspect as the timeline), which the aspect gate can't catch;
/// publishing it would size the mini-viewer's media + OSC to the thumbnail and
/// draw it upscaled/blurry. The publish gate tracks the largest seen here and
/// skips materially-smaller frames. Not persisted.
@property(nonatomic) CGSize largestSourceSizeSeen;

/// Publish whatever state the feed currently has (no surface update). Used
/// when only `slotCount` changes - consumers need a fresh descriptor.
- (void)publishDescriptor;

@end

/// Headless reader for a feed's PRIMARY source frame: reads the JSON descriptor
/// at `descriptorPath`, looks up slot 0's published `IOSurface`, and wraps it
/// as a shader-readable `MTLTexture` on `device`. Returns nil if the descriptor
/// is missing / carries no source slot (a generator feed publishes none) / the
/// surface is gone. Lets code WITHOUT a live `KKMiniViewerView` (e.g. a link
/// thumbnail bake) get the same per-instance source frame the mini composites.
FOUNDATION_EXPORT id<MTLTexture> _Nullable KKMiniViewerFeedLoadPrimarySource(
    NSString *descriptorPath, id<MTLDevice> device);

/// Cross-process rendezvous paths for a product's mini-viewer feed - THE one
/// path scheme (the per-product path functions in each plugin are one-line
/// wrappers over these). The render side publishes its IOSurface descriptor
/// at the DESCRIPTOR path; the inspector's boundary/filmstrip/onion previews
/// write requested clip fractions at the REQUEST path. Per-instance when
/// `uuid` is non-empty (two stacked clips must not cross-pollute); empty uuid
/// = the product's shared legacy path.
FOUNDATION_EXPORT NSString *
KKMiniViewerFeedDescriptorPath(NSString *productSlug, NSString *_Nullable uuid);
FOUNDATION_EXPORT NSString *
KKMiniViewerFeedRequestPath(NSString *productSlug, NSString *_Nullable uuid);

NS_ASSUME_NONNULL_END
