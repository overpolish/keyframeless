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
@property(nonatomic, strong, nullable) KKMiniCanvasFeed *miniCanvasFeed;
/// The /tmp descriptor path the current feed publishes to (per-instance, keyed
/// by the instance UUID). Tracked so the feed is recreated if the UUID resolves
/// after the feed was first made with the no-UUID fallback path.
@property(nonatomic, copy, nullable) NSString *miniCanvasFeedPath;
@property(nonatomic, strong, nullable)
    MagicMoveMiniCanvasRenderer *miniCanvasRenderer;
@property(nonatomic) BOOL miniDragUndoStarted;
@property(nonatomic, strong, nonnull) KKRenderCache *renderCache;
@property(nonatomic, strong, nullable) KKPlayheadPoller *playheadPoller;
- (nullable KKTimeline *)timelineStampedWithClipDuration:
    (nullable KKTimeline *)timeline;
@end

@interface MagicMovePlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface MagicMovePlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
+ (NSArray<KKLane *> *)availableLanes;
/// OSC-visibility pills grouped into compounds for the settings popover:
/// @[ @[@"Position"], @[@"Rotation", @"Rotation.X", @"Rotation.Y",
/// @"Rotation.Z"] ]. Segment 0 of a compound is its master.
+ (NSArray<NSArray<NSString *> *> *)oscCompounds;
/// Flattened element keys across all compounds (persistence + state seeding).
+ (NSArray<NSString *> *)oscElementKeys;
/// Read the per-element OSC visibility from the persisted UI-state blob and
/// push the derived hidden-element set to this instance's per-instance state
/// (read by the OSC) and the mini-canvas renderer.
- (void)applyOSCElementsFromUIState:(NSDictionary *)uiState;
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
