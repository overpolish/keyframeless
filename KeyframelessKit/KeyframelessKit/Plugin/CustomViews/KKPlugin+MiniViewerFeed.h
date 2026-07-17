/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

#import <KeyframelessKit/KKPlugin.h>

@class FxImageTile;

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
                               defaultTag:(double)defaultTag;

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

@end

NS_ASSUME_NONNULL_END
