/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "Plugin.h"
#import "MeshInspectorView.h"
#import <KeyframelessKit/KeyframelessKit.h>

@class KKPlayheadPoller;

@interface MeshPlugin ()
@property(nonatomic, weak, nullable) MeshInspectorView *inspectorView;
// miniViewerFeed + miniDragUndoStarted now live on the KKPlugin base.
@property(nonatomic, strong, nonnull) KKRenderCache *renderCache;
@property(nonatomic, strong, nullable) KKPlayheadPoller *playheadPoller;
/// Returns a copy of `timeline` with every lane's lastKnownClipDuration set
/// to the current effect duration (seconds), so the Basic ruler/hover have a
/// duration without extra plumbing. Must be called inside an action scope.
- (nullable KKTimeline *)timelineStampedWithClipDuration:
    (nullable KKTimeline *)timeline;
@end

NS_ASSUME_NONNULL_BEGIN

@interface MeshPlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface MeshPlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
+ (NSArray<KKLane *> *)availableLanes;
@end

typedef struct {
  double radius;
  double cropW; // 0..1 fraction of image width
  double cropH; // 0..1 fraction of image height
  double cropX; // center offset, -0.5..0.5 (+ = right)
  double cropY; // center offset, -0.5..0.5 (+ = up)
} MeshPluginState;

@interface MeshPlugin (Render)
- (BOOL)pluginState:(NSData *_Nullable *_Nonnull)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error;
/// Computes the per-frame mesh params at `time`. Used by both the
/// normal render path (via pluginState:atTime:) and the motion blur
/// sub-frame sample loop.
- (BOOL)meshParams:(MeshPluginState *)outParams
               atTime:(CMTime)time
                error:(NSError **)error;
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError;
@end

NS_ASSUME_NONNULL_END
