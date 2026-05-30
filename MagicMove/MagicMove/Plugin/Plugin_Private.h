/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "Constants.h"
#import "Plugin.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

@class KKTimelineInspectorView;
@class KKMiniCanvasFeed;
@class KKPlayheadPoller;
@class MagicMoveMiniCanvasRenderer;

@interface MagicMovePlugin ()
@property(nonatomic, weak, nullable) KKTimelineInspectorView *inspectorView;
@property(nonatomic, retain, nullable) KKMiniCanvasFeed *miniCanvasFeed;
@property(nonatomic, retain, nullable)
    MagicMoveMiniCanvasRenderer *miniCanvasRenderer;
@property(nonatomic) BOOL miniDragUndoStarted;
@property(nonatomic, retain, nonnull) KKV3RenderCache *renderCache;
@property(nonatomic, retain, nullable) KKPlayheadPoller *playheadPoller;
- (nullable KKTimeline *)timelineStampedWithClipDuration:
    (nullable KKTimeline *)timeline;
@end

@interface MagicMovePlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface MagicMovePlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
+ (NSArray<KKLane *> *)availableLanes;
@end

@interface MagicMovePlugin (Render)
- (BOOL)pluginState:(NSData *_Nullable *_Nonnull)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error;
- (BOOL)magicMoveParams:(MagicMoveParams *)outParams
                 atTime:(CMTime)time
                  error:(NSError **)error;
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError;
@end

NS_ASSUME_NONNULL_END
