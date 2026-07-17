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
/// Holds `ShaderFeedbackSet` values (see ShaderFeedbackSet.h).
@property(nonatomic, strong, nullable) NSMutableDictionary *feedbackSets;
/// Last-read Sonar tickets (key -> ticket), refreshed by `syncAudioTickets…`.
///
/// Cached because the lane builder needs them where the param APIs don't
/// resolve: `availableLanesProvider` fires from a code-commit callback, which
/// is outside any action scope, and reading a parameter there returns nil.
@property(nonatomic, copy, nullable) NSDictionary<NSString *, id> *audioTickets;
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
/// As above, plus what this instance remembers about its `#audio` bindings, so
/// a lane bound to a source not published here can name it instead of reading
/// "None". Pass nil where that doesn't matter (the OSC draws no such label).
+ (NSArray<KKLane *> *)
    availableLanesForShaderSource:(NSString *)source
                     audioTickets:
                         (nullable NSDictionary<NSString *, id> *)tickets;
/// The current shader source from a timeline's "Shader" code lane (baked
/// default when absent).
+ (NSString *)shaderSourceFromTimeline:(KKTimeline *)timeline;
/// The OSC-visibility compound groups (empty for now - the legacy Origin /
/// Scale / Rotation controls are gone pending shader-exposed OSCs). Single
/// source of truth: createView wires these and parameterChanged refreshes from
/// them, so the element-key list can't drift out of sync (which silently breaks
/// OSC hide persistence + opt-click).
+ (NSArray<NSArray<NSString *> *> *)oscCompounds;
/// Per-shader OSC-visibility compounds: one element per `osc`-annotated lane
/// the given source declares (point handle / rotation gizmo / ...). Drives the
/// settings-cog popover + hide persistence for the current shader.
+ (NSArray<NSArray<NSString *> *> *)oscCompoundsForShaderSource:
    (NSString *)source;
@end

@interface ShaderPlugin (AudioTickets)
/// Records what each `#audio` lane is bound to, so the binding can still be
/// named on a Mac where the source was never published (nothing but plugin
/// parameters travels inside an FCP library).
///
/// Idempotent and self-scoping: writes only when something actually changed,
/// and opens its own action scope. Never call from the render path.
///
/// Takes the timeline rather than reading the process snapshot, which is empty
/// until something seeds it - a caller that already holds the canonical one
/// shouldn't be made to depend on having seeded it first.
- (void)syncAudioTicketsForTimeline:(nullable KKTimeline *)timeline;
@end

@interface ShaderPlugin (Render)
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError;
@end

@interface ShaderPlugin (RenderState)
- (BOOL)pluginState:(NSData *_Nullable *_Nonnull)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
