/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKTiming.h>
#import <KeyframelessKit/KKTimingStage.h>
#import <Metal/Metal.h>

@class FxImageTile;
@class KKAnimatableProperty;
@class KKTimingSlot;
@class NSBezierPath;
@protocol PROAPIAccessing;
@protocol FxParameterCreationAPI_v5;

NS_ASSUME_NONNULL_BEGIN

/// Drop this macro into main.m to eliminate per-plugin boilerplate.
/// Every plugin's main() is identical, so this removes the need for the file.
#define KK_PLUGIN_MAIN()                                                       \
  int main(int argc, const char *argv[]) {                                     \
    @autoreleasepool {                                                         \
      [FxPrincipal                                                             \
          startServicePrincipalWithDelegate:[KKPlugin                          \
                                                servicePrincipalDelegate]];    \
    }                                                                          \
    return 0;                                                                  \
  }

@interface KKPlugin : NSObject

@property(nonatomic, weak) id<PROAPIAccessing> apiManager;

/// Extra parameter IDs to show/hide alongside the timing group's children.
/// Set before the first render pass (e.g. in addParametersWithError:).
@property(nonatomic, copy, nullable)
    NSArray<NSNumber *> *timingGroupExtraParamIDs;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

/// Convenience wrapper around KKMetalDeviceCache buildAndRegisterPipelineState.
/// Call from renderDestinationImage: to get or build the pipeline state for
/// this plugin.
- (nullable id<MTLRenderPipelineState>)
    pipelineStateForPluginID:(NSString *)pluginID
            destinationImage:(FxImageTile *)destinationImage
                vertexShader:(NSString *)vertexShader
              fragmentShader:(NSString *)fragmentShader
                   blendMode:(KKBlendMode)blendMode;

/// Shared rendering infrastructure for any plugin render pass.
/// Handles command buffer, render pass, viewport, fullscreen quad, and cleanup.
/// Your block receives the encoder and input texture - set pipeline state,
/// fragment bytes, and draw.
- (BOOL)
    encodeRenderCommandsForDestinationImage:(FxImageTile *)destinationImage
                               sourceImages:
                                   (NSArray<FxImageTile *> *)sourceImages
                                   commands:
                                       (void (^)(
                                           id<MTLRenderCommandEncoder> encoder,
                                           NSArray<id<MTLTexture>>
                                               *inputTextures))commands;

/// Simple single-pass render: validates inputs, gets pipeline state, encodes
/// a fullscreen quad with one source texture and your fragment bytes.
/// Covers the common case where you just need to pass a state struct to
/// the fragment shader. Uses "vertexShader"/"fragmentShader" function names
/// and premultiplied alpha blending.
- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                      pluginID:(NSString *)pluginID
                 fragmentBytes:(const void *)fragmentBytes
              fragmentBytesLen:(size_t)fragmentBytesLen
           fragmentBufferIndex:(NSUInteger)fragmentBufferIndex
                         error:(NSError *_Nullable *)outError;

/// Returns the shared FxPrincipalDelegate that captures the host ID into
/// KKHostInfo. Pass to +[FxPrincipal startServicePrincipalWithDelegate:] in
/// main().
+ (id)servicePrincipalDelegate;

/// Registers only the multi-stage timing params — Timing separator, curve
/// preview, enabled toggle (always YES, hidden), JSON data, selected
/// property/stage, and instance ID. Call this from
/// `addParametersWithError:` in plugins that are fully multi-stage (no
/// classic ease-in/hold/ease-out UI).
- (BOOL)addMultiStageParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                 error:(NSError **)error;

/// Registers multi-stage params (via `addMultiStageParametersWithAPI:`)
/// plus the classic animate-in / hold / animate-out toggles, durations,
/// intensities, frequencies, and interpolation popups. Use for plugins
/// that still expose classic-timing UI.
- (BOOL)addAnimationParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                error:(NSError **)error;

/// Returns per-phase timing at renderTime using the animation parameter IDs
/// in KKConstants.h.  Each phase carries enabled, duration, progress, an
/// interpolation block, and a convenience factor (= interpolate(progress)).
/// Plugins apply phases selectively to whichever properties they animate.
- (KKTimingResult *)timingAtTime:(CMTime)renderTime;

/// Adds an update banner at parameter ID 9990 that shows when a newer version
/// is available. Call at the end of addParametersWithError:.
- (BOOL)addUpdateBannerParameterWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                  error:(NSError **)error;

/// Adds a full-width informational text display occupying one parameter ID.
/// The parameter is not animatable and stores no meaningful value — it is
/// purely a static label in the inspector.
- (BOOL)addInfoParameterWithText:(NSString *)text
                            icon:(nullable NSImage *)icon
                     parameterID:(UInt32)parameterID
                         withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                           error:(NSError **)error;

/// Accepts an attributed string — use to embed KKKbd badges
/// or other inline styled content.
- (BOOL)addInfoParameterWithAttributedText:(NSAttributedString *)text
                                      icon:(nullable NSImage *)icon
                               parameterID:(UInt32)parameterID
                                   withAPI:
                                       (id<FxParameterCreationAPI_v5>)paramAPI
                                     error:(NSError **)error;

/// Adds a full-width horizontal divider occupying one parameter ID.
/// Pass text and/or icon to render  ──── [icon] [text] ────  centred on the
/// line; pass nil for both for a plain rule.
- (BOOL)addSeparatorParameterWithText:(nullable NSString *)text
                                 icon:(nullable NSImage *)icon
                          parameterID:(UInt32)parameterID
                              withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                error:(NSError **)error;

/// Updates timing parameter visibility based on the timing group's expand
/// state. Call from updateParameterVisibilityAtTime: in subclasses that use
/// animation.
- (void)updateTimingParameterVisibility;

/// Returns interpolated absolute values for each enabled multi-stage property
/// at renderTime, keyed by property label. Each value is an array matching
/// the property's valueParamIDs (e.g. @"Radius" -> @[@(35.2)],
/// @"Crop" -> @[@(0.1), @(0.1), @(0.05), @(0.05)]).
/// Returns nil when multi-stage is disabled — caller should fall back to
/// timingAtTime: factor-based path.
- (nullable NSDictionary<NSString *, NSArray<NSNumber *> *> *)
    multiStageValuesAtTime:(CMTime)renderTime;

/// Call from parameterChanged: to detect native param changes and stage
/// pending lane updates. Returns YES if the parameter matched a staged
/// property.
- (BOOL)multiStageHandleParameterChanged:(UInt32)parameterID
                                  atTime:(CMTime)time;

/// Call once per `drawOSC` tick. Flushes pending lanes, syncs from params
/// (undo/redo detection), and pumps playheads — all broadcast across every
/// live plugin instance on the timeline.
+ (void)multiStageDrawOSCTickForAPI:(id<PROAPIAccessing>)apiManager
                             atTime:(CMTime)time;

/// Call once per `renderDestinationImage:` tick. Converts the effect-local
/// `renderTime` to timeline time, flushes pending lanes, and pumps playheads
/// — subordinate to drawOSC (skipped if drawOSC pumped recently, and briefly
/// after any `parameterChanged:` to avoid FCP's warm-up renders flickering
/// the playhead to frame 0).
+ (void)multiStageRenderTickForAPI:(id<PROAPIAccessing>)apiManager
                            atTime:(CMTime)renderTime
                            sender:(id)sender;

/// Individual pump primitives beneath the consolidated ticks above. Most
/// plugins should call the `*TickForAPI:atTime:` methods instead of these;
/// they're exposed for cases that need to compose or skip parts of a tick.
+ (void)multiStageFlushPendingLanes;
+ (void)multiStageSyncFromParams:(id<PROAPIAccessing>)apiManager;
+ (void)multiStageUpdatePlayheadsForAPI:(id<PROAPIAccessing>)apiManager
                                 atTime:(CMTime)time;
+ (void)multiStageUpdatePlayheadsFromRenderForAPI:
            (id<PROAPIAccessing>)apiManager
                                           atTime:(CMTime)time
                                           sender:(id)sender;

/// Returns whether the OSC for the animatable property with `label` should
/// be drawn. Returns NO only when the user has toggled that lane's OSC off
/// in the sequencer. Returns YES otherwise (lane not found, classic mode,
/// or OSC explicitly on). Plugins call this at the top of their drawOSC
/// path to skip individual OSC parts.
+ (BOOL)multiStageOSCVisibleForAPI:(id<PROAPIAccessing>)apiManager
                             label:(NSString *)label;

/// Pairs of parameter IDs that maintain their aspect ratio when the user
/// holds Cmd while dragging either slider. Set before first use (e.g. in
/// addParametersWithError:). Each element is @[@(paramA), @(paramB)].
@property(nonatomic, copy, nullable)
    NSArray<NSArray<NSNumber *> *> *linkedParameterPairs;

/// Call from parameterChanged:atTime:error: for any parameter that may be
/// part of a linked pair. Returns YES if the change was handled (the other
/// parameter in the pair was updated to maintain ratio). Returns NO if the
/// parameter is not part of a pair or Cmd is not held.
- (BOOL)handleLinkedParameterChanged:(UInt32)parameterID atTime:(CMTime)time;

/// Override in subclasses to provide custom views that appear above the
/// duration slider, always visible when the timing group is expanded.
/// Build views using KK components (KKCheckboxView, KKSliderView, etc.)
/// and return them wrapped in KKTimingSlot objects with applyState blocks.
- (NSArray<KKTimingSlot *> *)timingGlobalSlots;

/// Override in subclasses to provide custom views that appear below the
/// graph, changing based on the selected section (0=In, 1=Hold, 2=Out).
- (NSArray<KKTimingSlot *> *)timingSlotsForSection:(NSInteger)section;

/// Override to declare animatable properties. When non-nil, the timing graph
/// auto-generates pill toggles for In/Hold/Out sections using the param IDs
/// from each KKAnimatableProperty. This replaces the manual holdPropertyView
/// mechanism — do not override both.
- (nullable NSArray<KKAnimatableProperty *> *)animatableProperties;

/// Override to hide specific animatable-property lanes from the multi-stage
/// sequencer based on current parameter state (e.g. a Color lane should
/// disappear when the plugin is in gradient-only mode). Segment data stays
/// in JSON — the lane reappears when the set no longer contains its label.
/// Call `-multiStageRefreshLaneVisibility` after any param change that would
/// affect the return value; the pump applies the filter on every push.
- (NSSet<NSString *> *)hiddenAnimatablePropertyLabels;

/// Override to declare which animatable-property labels render an on-screen
/// control (OSC) on canvas. Lanes in this set get a visibility-toggle icon
/// in the sequencer row; their OSC code checks `lane.oscVisible` before
/// drawing.
- (NSSet<NSString *> *)animatablePropertyLabelsWithOSC;

/// Recomputes `-hiddenAnimatablePropertyLabels`; if it differs from the last
/// snapshot, re-pushes the filtered lanes to the sequencer view. Safe to
/// over-call.
- (void)multiStageRefreshLaneVisibility;

/// Override to provide a view with hold property toggles. This view is added
/// as a direct subview of the timing graph and shown when the hold section is
/// selected and a non-static hold effect is active. Return nil for no toggles.
/// Ignored when animatableProperties returns non-nil.
- (nullable NSView *)holdPropertyView;
- (CGFloat)holdPropertyViewHeight;
- (nullable void (^)(id, CMTime))holdPropertyApplyState;

/// Reads the bool at forceShowParamID; if YES, sets every param in paramIDs
/// to kFxParameterFlag_DEFAULT and returns YES.  Caller should early-return
/// from updateParameterVisibilityAtTime: when this returns YES.
- (BOOL)forceShowAllParametersIfEnabled:(UInt32)forceShowParamID
                               paramIDs:(NSArray<NSNumber *> *)paramIDs
                                 atTime:(CMTime)time;

/// Creates a collapsible group header view wired to a hidden bool toggle.
/// Use from createViewForParameterID: — the returned view reads/writes
/// the expanded state at expandedParamID via an action scope.
- (NSView *)createGroupHeaderWithTitle:(NSString *)title
                                  icon:(nullable NSImage *)icon
                           parameterID:(UInt32)parameterID
                       expandedParamID:(UInt32)expandedParamID
    NS_RETURNS_RETAINED;

@end

NS_ASSUME_NONNULL_END
