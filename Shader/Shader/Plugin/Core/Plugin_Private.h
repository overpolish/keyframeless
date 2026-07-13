/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "Plugin.h"
#import "ShaderInspectorView.h"
#import <KeyframelessKit/KeyframelessKit.h>

@class KKPlayheadPoller;

@interface ShaderPlugin ()
@property(nonatomic, weak, nullable) ShaderInspectorView *inspectorView;
// miniViewerFeed + miniDragUndoStarted now live on the KKPlugin base.
@property(nonatomic, strong, nonnull) KKRenderCache *renderCache;
@property(nonatomic, strong, nullable) KKPlayheadPoller *playheadPoller;
/// Persistent feedback-buffer state for Custom multi-pass shaders that read
/// their own (or a later) buffer's previous frame. Keyed by "WxH" so the main
/// viewer, thumbnails, and library previews keep independent ping-pong sets.
/// Holds `_ShaderFeedbackSet` values (private to Plugin+Render.m).
@property(nonatomic, strong, nullable) NSMutableDictionary *feedbackSets;
/// Returns a copy of `timeline` with every lane's lastKnownClipDuration set
/// to the current effect duration (seconds), so the Basic ruler/hover have a
/// duration without extra plumbing. Must be called inside an action scope.
- (nullable KKTimeline *)timelineStampedWithClipDuration:
    (nullable KKTimeline *)timeline;
@end

NS_ASSUME_NONNULL_BEGIN

@interface ShaderPlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error;
@end

@interface ShaderPlugin (CustomUI)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
+ (NSArray<KKLane *> *)availableLanes;
/// Source-aware lane set: Core lanes + the dynamic lanes the given shader
/// source declares (e.g. the `// #color` Colours group).
+ (NSArray<KKLane *> *)availableLanesForShaderSource:(NSString *)source;
/// The current shader source from a timeline's "Shader" code lane (baked
/// default when absent).
+ (NSString *)shaderSourceFromTimeline:(KKTimeline *)timeline;
/// The OSC-visibility compound groups (empty for now - the legacy Origin /
/// Scale / Rotation controls are gone pending shader-exposed OSCs). Single
/// source of truth: createView wires these and parameterChanged refreshes from
/// them, so the element-key list can't drift out of sync (which silently breaks
/// OSC hide persistence + opt-click).
+ (NSArray<NSArray<NSString *> *> *)oscCompounds;
@end

@interface ShaderPlugin (Render)
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
