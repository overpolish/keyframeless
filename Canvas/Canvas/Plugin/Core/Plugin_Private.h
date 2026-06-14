/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "CanvasInspectorView.h"
#import "Plugin.h"
#import <KeyframelessKit/KeyframelessKit.h>

@class KKPlayheadPoller;

@interface CanvasPlugin ()
@property(nonatomic, weak, nullable) CanvasInspectorView *inspectorView;
@property(nonatomic, strong, nonnull) KKRenderCache *renderCache;
@property(nonatomic, strong, nullable) KKPlayheadPoller *playheadPoller;
/// Returns a copy of `timeline` with every lane's lastKnownClipDuration set to
/// the current effect duration (seconds). Must be called inside an action
/// scope (FxTimingAPI resolves there).
- (nullable KKTimeline *)timelineStampedWithClipDuration:
    (nullable KKTimeline *)timeline;
@end

NS_ASSUME_NONNULL_BEGIN

@interface CanvasPlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface CanvasPlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
+ (NSArray<KKLane *> *)availableLanes;
@end

@interface CanvasPlugin (Render)
- (BOOL)scheduleInputs:(NSArray<FxImageTileRequest *> *_Nullable *_Nullable)
                           inputImageRequests
       withPluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error;
- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
       sourceImageIndex:(NSUInteger)sourceImageIndex
           sourceImages:(NSArray<FxImageTile *> *)sourceImages
    destinationTileRect:(FxRect)destinationTileRect
       destinationImage:(FxImageTile *)destinationImage
            pluginState:(NSData *_Nullable)pluginState
                 atTime:(CMTime)renderTime
                  error:(NSError *_Nullable *)outError;
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

NS_ASSUME_NONNULL_END
