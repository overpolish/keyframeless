/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

#import <KeyframelessKit/KKPlugin.h>

@class FxImageTile;
@class KKRenderCache;

NS_ASSUME_NONNULL_BEGIN

@interface KKPlugin (MiniViewerFeed)

/// Publish the raw source tile(s) into this instance's mini-viewer feed
/// (`self.miniViewerFeed`), recreating the feed when `descriptorPath` changes.
/// Single-slot (playhead) by default; when `multiSlotActive` AND
/// `boundaryReqSecs` is non-empty, each requested time claims its closest
/// delivered tile by mediaTime (boundary preview / filmstrip / onion). Skips
/// sub-tiles (parent Scale > 100%) and dest/source aspect mismatches (FCP
/// library-preview render). `defaultTag` is the slot tag used when no
/// `boundaryReqFracs` entry exists. Call from renderDestinationImage:.
///
/// `renderCache` (optional) supplies the playhead sample that paces the
/// single-slot publish during playback. FCP's render schedule is NOT the
/// playhead: it stalls on the first frame through pre-roll and then jumps, and
/// it runs ahead to fill its cache. Consuming that stream directly made the
/// mini skip the start of an animation and then race. With a fresh sample, a
/// slot-0 frame more than a few frames AHEAD of the playhead is held back.
/// Pass nil to publish unpaced (previous behaviour).
- (void)
    kkPublishMiniViewerFeedForDestination:(FxImageTile *)destinationImage
                             sourceImages:(NSArray<FxImageTile *> *)sourceImages
                           descriptorPath:(NSString *)descriptorPath
                          boundaryReqSecs:
                              (nullable NSArray<NSNumber *> *)boundaryReqSecs
                         boundaryReqFracs:
                             (nullable NSArray<NSNumber *> *)boundaryReqFracs
                          multiSlotActive:(BOOL)multiSlotActive
                        changesOutputSize:(BOOL)changesOutputSize
                             linearFloat:(BOOL)linearFloat
                          fullResolution:(BOOL)fullResolution
                               defaultTag:(double)defaultTag
                              renderCache:(nullable KKRenderCache *)renderCache;

/// Publish an image-well parameter's frame as the feed's SECOND texture, so a
/// mini-viewer can preview a shader that samples two sources.
///
/// Call after the slot publish (which is what creates the feed); a no-op until
/// then, and a no-op when the well is empty - an unfilled well leaves the last
/// published texture alone rather than tearing it down. Finds the tile by
/// `wellParameterID`, since a caller's request count can vary.
///
/// The tile must have been requested in `-scheduleInputs:` with
/// `kFxImageTileRequestSourceParameter` and this parameter ID, or it will never
/// appear in `sourceImages`.
- (void)kkPublishMiniViewerChannel1ForDestination:
            (FxImageTile *)destinationImage
                                     sourceImages:
                                         (NSArray<FxImageTile *> *)sourceImages
                                  wellParameterID:(UInt32)wellParameterID;

/// Publish already-resolved AUXILIARY textures into the feed, in the caller's
/// order, so an inspector-side renderer can bind them positionally. Pass an
/// empty array to drop the whole set (the descriptor's `aux` key disappears).
/// `textures` may carry `NSNull` for a slot the caller could not resolve; that
/// index keeps whatever it last held.
///
/// General on purpose - the feed is shared, and a plugin that never calls this
/// publishes byte-identical descriptors. Mirage uses it for a `// #frames`
/// shader's neighbour frames.
///
/// Call AFTER the slot publish (which is what creates the feed); a no-op until
/// then. Textures must be full frames on the destination's device, the same
/// pixel size as the frame being fed to slot 0 - the feed downscales them by
/// the same long-edge rule, so a differently-sized frame (FCP's tiny
/// library-preview render) would land at a size that no longer lines up with
/// the slot it must be sampled against, and is dropped with a warning.
- (void)kkPublishMiniViewerAuxTexturesForDestination:
            (FxImageTile *)destinationImage
                                            textures:(NSArray *)textures;

@end

NS_ASSUME_NONNULL_END
