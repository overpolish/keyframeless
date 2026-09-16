/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "Plugin.h"
#import "MMRenderHost.h"
#import "MMParameterData.h"
#import "MMCombinedPose.h"
#import "MMPropertyLane.h"
#import "MMScalePose.h"

NS_ASSUME_NONNULL_BEGIN

@interface MagicMovePlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface MagicMovePlugin (Render)
- (BOOL)pluginState:(NSData *_Nullable *_Nonnull)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error;
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError;
@end

@interface MagicMovePlugin (DeferredEdits)
// Caller owns the host action. Explicit button state keeps gesture tests deterministic.
- (BOOL)updateTimingEditorsAtTime:(CMTime)time mouseDown:(BOOL)mouseDown error:(NSError **)error;
- (BOOL)commitPendingEditsWithMouseDown:(BOOL)mouseDown atTime:(CMTime)time error:(NSError **)error;
@end

@interface MagicMovePlugin (Links)
- (BOOL)syncLinkedLane:(MMTimingLane *)lane parameterID:(UInt32)parameterID
                 data:(NSMutableData *)data atTime:(CMTime)time error:(NSError **)error;
- (nullable MMLinkEdit *)prepareLinkedLane:(MMTimingLane *)lane parameterID:(UInt32)parameterID
                 data:(NSMutableData *)data atTime:(CMTime)time error:(NSError **)error;
- (BOOL)applyLinkedEdit:(MMLinkEdit *)edit error:(NSError **)error;
- (void)invalidateTimingLane:(MMTimingLane *)lane;
@end

// Inspector view caches. One set per plugin instance, published once: the
// token identifies the cache, not the row, so rebuilding a row must not repeat
// the host write. Motion rebuilds every row several times per selection and
// holds more than one generation at a time, so a per-row write cost tens of
// milliseconds each time.
@interface MagicMovePlugin (ViewCaches)
// Idempotent; a no-op until the host exposes its setting API.
- (void)publishViewCaches;
- (nullable MMCombinedPoseCache *)sharedCombinedCache;
- (nullable MMScalePoseCache *)sharedScaleCache;
- (nullable MMPropertyPoseCache *)sharedCacheForLane:(MMPropertyLane *)lane;
@end

NS_ASSUME_NONNULL_END