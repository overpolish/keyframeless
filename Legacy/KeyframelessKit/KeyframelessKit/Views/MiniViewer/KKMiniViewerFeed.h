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
/// Owns one persistent `IOSurface`-backed `MTLTexture` (long edge capped by
/// default),
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

/// Preserve the source as linear RGBA16F instead of the default display-coded
/// BGRA8 feed. Use for technical color processing that must retain HDR values
/// and wide-gamut components. Changing it recreates surfaces lazily.
@property(nonatomic) BOOL linearFloat;

/// Keep feed surfaces at the source raster instead of applying the normal
/// 2048-pixel long-edge preview cap. Resolution-sensitive renderers use this
/// when their integer sample grid must exactly match the host render.
/// Changing it recreates surfaces lazily.
@property(nonatomic) BOOL fullResolution;

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

/// Number of AUXILIARY textures this feed carries alongside the slots and
/// channel 1. Default 0 - a feed that never sets it publishes no `aux` key at
/// all, so consumers (and descriptors) are byte-identical to before.
///
/// Auxiliary means "extra whole textures the consumer indexes positionally",
/// which is neither of the existing shapes: slots are the same source at
/// different TIMES and their count tracks the filmstrip/onion fan-out, and
/// channel 1 is a single fixed second source. Mirage publishes its `// #frames`
/// neighbour frames here, in directive order, so the inspector-side preview
/// binds the real neighbours instead of clamping to the current frame.
///
/// Setting a different count discards excess surfaces. The `aux` key is
/// published only when EVERY slot holds a surface - a partially-filled array
/// would shift the consumer's indices onto the wrong entries.
@property(nonatomic) NSUInteger auxTextureCount;

/// Per-index variant of `-updateWithSourceTexture:`, downscaled by the same
/// long-edge rule and written in the same encoding as the slots, so a consumer
/// sampling an aux texture and slot 0 together sees consistent geometry.
/// Out-of-range indices are ignored (set `auxTextureCount` first).
- (void)updateAuxTexture:(id<MTLTexture>)sourceTexture
                 atIndex:(NSUInteger)index
                  device:(id<MTLDevice>)device
            commandQueue:(id<MTLCommandQueue>)commandQueue;

/// Pixel size of the SOURCE frame last written into slot 0 (not the downscaled
/// surface), or zero before the first publish. A caller pumping auxiliary
/// textures compares against this to reject a frame from a different render
/// pass (FCP's tiny library-preview run), which would otherwise land at a
/// different downscaled size than the slot it must line up with.
@property(nonatomic, readonly) CGSize primarySourceSize;

/// Output media pixel size, for a GENERATOR with no source frames to carry it.
/// When set (and there are no published slots), `publishDescriptor` writes a
/// dims-only descriptor (`srcWidth`/`srcHeight`, empty `slots`) so a consuming
/// `KKMiniViewerView` resolves `sourceMediaSize` - which px-scaled value fields
/// need. Ignored once real source slots are published (they carry their own).
@property(nonatomic) CGSize mediaSize;

/// Canonical frame size that raw `units="px"` controls are authored against.
/// For a scaled source this differs from `primarySourceSize`: a 4K source in a
/// 1080p project has a 3840x2160 source texture but a 1920x1080 pixel-reference
/// frame. Published in the descriptor so the inspector process can apply the
/// same pixel scale as the FxPlug render process.
@property CGSize pixelReferenceSize;

/// Exact output raster used by the host for the render tick being published.
/// Unlike `pixelReferenceSize` this includes FCP's current render scale
/// (viewer quality/proxy/thumbnails). Resolution-sensitive previews render at
/// this size so their integer pixel grid matches the main viewer exactly.
@property CGSize renderPixelSize;

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

/// Consecutive frames skipped for being a GESTURE-DEGRADED size (between the
/// hard thumbnail floor and the degrade threshold). FCP drops its render
/// resolution while a parameter gesture is open; publishing those frames made
/// the preview and the vectorscope visibly change resolution twice per click.
/// A long run means the smaller size is a real setting change (proxy media,
/// viewer quality) and is accepted as the new normal. Not persisted.
@property(nonatomic) NSUInteger degradedSourceRun;

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
