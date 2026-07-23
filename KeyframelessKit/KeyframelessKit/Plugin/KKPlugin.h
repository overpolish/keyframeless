/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKTimingLane.h>
#import <KeyframelessKit/KKTimingStage.h>
#import <Metal/Metal.h>

@class FxImageTile;
@class KKMiniViewerFeed;
@class KKCustomGroupHeaderView;
@class KKHelpSection;
@class KKHelpShortcut;
@class KKHelpGuide;
@class KKTimingLane;
@class KKTimingSegment;
@class KKRenderCache;
@class KKTimelineInspectorView;
@class NSBezierPath;
@protocol PROAPIAccessing;
@protocol FxParameterCreationAPI_v5;
@protocol FxParameterRetrievalAPI_v6;
@protocol FxParameterSettingAPI_v5;

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

/// Runs `block` inside a bare parameter action scope (`startAction:self` ...
/// `endAction:self`) - the one correct place to resolve any API that returns
/// nil OUTSIDE a scope (get/set/timing/command/undo; the #1 FxPlug mistake). A
/// no-op (block not run) when the action API is unavailable; early-returning
/// from the block still ends the action. Use -kkInParamAction: when you only
/// need get/set.
- (void)kkInActionScope:(void (^)(void))block;

/// -kkInActionScope: with the parameter get/set APIs and the action's current
/// time resolved inside the scope and handed to `block` (the time is what most
/// `getXValue:...atTime:` / `setXValue:...atTime:` reads and writes want). Any
/// param may be used or ignored.
- (void)kkInParamAction:(void (^)(id<FxParameterRetrievalAPI_v6> getAPI,
                                  id<FxParameterSettingAPI_v5> setAPI,
                                  CMTime actionTime))block;

/// Set while a continuous mini-viewer / inspector handle drag is coalescing its
/// per-tick timeline writes into one undo group. Toggled by the standard
/// inspector onDragBegin/onDragEnd callbacks (see KKPlugin+InspectorCallbacks).
@property(nonatomic) BOOL miniDragUndoStarted;

/// The mini-viewer source feed published from renderDestinationImage: and the
/// descriptor path it was created with. Managed by the shared feed-publish
/// helper (see KKPlugin+MiniViewerFeed); recreated when the path changes.
@property(nonatomic, strong, nullable) KKMiniViewerFeed *miniViewerFeed;
@property(nonatomic, copy, nullable) NSString *miniViewerFeedPath;

/// Extra parameter IDs to show/hide alongside the timing group's children.
/// Set before the first render pass (e.g. in addParametersWithError:).
@property(nonatomic, copy, nullable)
    NSArray<NSNumber *> *timingGroupExtraParamIDs;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

/// Namespace under which this plugin's animation presets are stored and listed
/// (see KKPresets / the inspector Presets row). Defaults to the plugin's bundle
/// identifier - stable and unique per plugin. Override only to share a preset
/// namespace between plugins.
- (NSString *)presetPluginKey;

/// Parameter-link discovery: the EFFECTIVE referenceable lanes this clip
/// exposes as a link source (directive-seeded constants for Shader, the static
/// param set for others). Default nil = this plugin doesn't advertise
/// (opt-out). Override to opt in, then call -writeLinkManifest from the render
/// tick. The kit filters out non-referenceable lanes (code / palette bars), so
/// return the full set.
- (nullable NSArray<KKLane *> *)linkableLanesForManifest;
/// Display name for this plugin in the reference picker ("<name> @
/// <timecode>"). Defaults to the bundle name. Override to force a specific
/// label.
- (NSString *)linkManifestEffectName;
/// Advertise this clip as a link source: compute its absolute span from the
/// timing API and write its manifest (uuid + display name + params) via
/// KKLinkWriteManifest. No-op unless -linkableLanesForManifest returns lanes.
/// Call from the render tick, where the clip's timeline position resolves.
/// Cheap (idempotent skip-if-unchanged).
- (void)writeLinkManifest;

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

/// Like `encodeRenderCommandsForDestinationImage:...` but targets an
/// arbitrary MTLTexture and uses a caller-owned command buffer (no commit).
/// Used by KKMotionBlur to draw plugin samples into pool textures, sharing
/// one command buffer across all sub-frame passes plus the accumulation
/// pass. Sets up the render pass with clear-to-zero, full-screen quad
/// vertices, and viewport matching `destTexture` dimensions, then invokes
/// `commands` with the encoder.
- (BOOL)
    encodeFullScreenQuadIntoTexture:(id<MTLTexture>)destTexture
                   destinationImage:(nullable FxImageTile *)destinationImage
                      commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                     sourceTextures:(NSArray<id<MTLTexture>> *)sourceTextures
                           commands:
                               (void (^)(id<MTLRenderCommandEncoder>,
                                         NSArray<id<MTLTexture>> *))commands;

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

/// Registers only the multi-stage timing params - Timing separator, curve
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

/// Registers the shared motion-blur param group (Enabled toggle + Shutter
/// and Quality sliders) at IDs 9924–9926. Add to `addParametersWithError:`
/// in any plugin that wants opt-in motion blur. The plugin then wraps its
/// render body in `[KKMotionBlur renderWithAPI:...]` to apply it.
- (BOOL)addMotionBlurParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                 error:(NSError **)error;

/// Hides/reveals the Motion Blur Length and Quality rows based on the
/// header's expanded state. Call from `parameterChanged:atTime:error:`
/// alongside `updateTimingParameterVisibility`.
- (void)updateMotionBlurParameterVisibility;

/// Adds the inspector chrome banner at parameter ID 9990: Keyframeless logo
/// plus optional accessories (help button, update CTA when available).
/// Call at the end of addParametersWithError:.
- (BOOL)addLogoBannerParameterWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                error:(NSError **)error;

/// Best-effort screen rect of THIS effect instance's FCP header row, derived
/// from its own logo banner. NSZeroRect if the banner isn't placed. Use to
/// anchor a guide step at the header; correct with multiple effect instances
/// (unlike a process-global lookup).
- (NSRect)effectHeaderScreenRect;

/// Best-effort screen rect of THIS effect instance's Help (`?`) button in its
/// logo banner. NSZeroRect if the banner isn't placed or has no Help button.
/// Use to anchor a guide's closing step on the Help button.
- (NSRect)helpButtonScreenRect;

/// Adds a full-width informational text display occupying one parameter ID.
/// The parameter is not animatable and stores no meaningful value - it is
/// purely a static label in the inspector.
- (BOOL)addInfoParameterWithText:(NSString *)text
                            icon:(nullable NSImage *)icon
                     parameterID:(UInt32)parameterID
                         withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                           error:(NSError **)error;

/// Accepts an attributed string - use to embed KKKbd badges
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

/// Updates the selected segment of the lane matching `label` with `values`
/// and persists. Used by `parameterChanged:` to translate slider drags into
/// segment edits. Plugin owns the `paramID → (label, values)` mapping -
/// no `KKAnimatableProperty` lookup is performed.
///
/// Returns YES when a lane matched and was updated; NO when no enabled
/// lane has the label, or no segment is selected, or the persist scope
/// isn't available. Stamps the "recent parameter change" timestamp so the
/// pump's playhead-suppression heuristics still apply.
- (BOOL)multiStageUpdateSelectedSegmentForLabel:(NSString *)label
                                         values:(NSArray<NSNumber *> *)values;

/// Coalesced + deferred + host-undo-aware variant of
/// `multiStageUpdateSelectedSegmentForLabel:values:` for use from
/// `parameterChanged:`-driven live-update paths.
///
/// Schedules the underlying write on a 16ms `dispatch_after` so that:
///  - During a host cmd-Z, the multi-stage param's MS-REFRESH lands
///    first and sets `hostUndoSuppressionPending`; this method then
///    correctly skips its write instead of layering a stale animatable
///    revert into a fresh undo entry.
///  - During a continuous drag, multiple calls per runloop coalesce
///    via `liveUpdatePending` (last-wins per label in
///    `pendingLiveUpdates`), so a 60fps drag produces ~60 writes
///    instead of 60×(num linked params) writes.
///
/// Plugins should call this from their `_xxxHandleAnimatableParameter
/// Change:` switch instead of the synchronous variant. The synchronous
/// variant remains for code paths that need an immediate write (e.g.
/// segment-selection write-back, opt-drag commit) where the caller
/// already owns the action scope.
- (void)multiStageDeferLiveUpdateForLabel:(NSString *)label
                                   values:(NSArray<NSNumber *> *)values;

/// Returns the active segment of the lane matching `label` at `time`. Lets
/// plugins reach per-segment data (e.g. `pathData`) - the only remaining
/// pump-side accessor since `multiStageValuesAtTime:` was retired in
/// favour of `KKTimingLaneValueAtFraction`.
///
/// `outSegments` (optional) is the lane's segments array - useful for
/// `KKTimingBoundaryBefore/After` when interpreting transitions.
/// `outLocalT` (optional) is the un-eased `t` inside the segment's range
/// (0 at segment start, 1 at end). Plugins typically pass it through
/// `KKApplyEasing(...)` to get the eased t for interpolation.
///
/// Returns nil when multi-stage is disabled, no lanes are loaded, or the
/// label doesn't match any lane.
- (nullable KKTimingSegment *)
    multiStageActiveSegmentForLabel:(NSString *)label
                             atTime:(CMTime)time
                           segments:(NSArray<KKTimingSegment *> *_Nullable
                                         *_Nullable)outSegments
                             localT:(double *_Nullable)outLocalT;

/// Whether any enabled multi-stage lane is currently inside a Transition
/// segment at `time`. Used by motion blur (and similar features) to skip
/// expensive per-frame work during pure Hold portions where nothing is
/// actually moving. Returns NO when multi-stage is disabled.
- (BOOL)multiStageAnyLaneInTransitionAtTime:(CMTime)time;

/// Persists `pathData` (or nil to clear) onto the segment at `segmentIndex`
/// inside the lane matching `label`. Pushes the updated lanes through the
/// same path as user edits - re-renders the sequencer view, broadcasts to
/// other instances, persists the JSON. Returns YES on success.
- (BOOL)multiStageSetPathData:(nullable NSData *)pathData
                     forLabel:(NSString *)label
                 segmentIndex:(NSInteger)segmentIndex;

/// Call once per `drawOSC` tick. Flushes pending lanes, syncs from params
/// (undo/redo detection), and pumps playheads - all broadcast across every
/// live plugin instance on the timeline.
+ (void)multiStageDrawOSCTickForAPI:(id<PROAPIAccessing>)apiManager
                             atTime:(CMTime)time;

/// Call once per `renderDestinationImage:` tick. Converts the effect-local
/// `renderTime` to timeline time, flushes pending lanes, and pumps playheads
/// - subordinate to drawOSC (skipped if drawOSC pumped recently, and briefly
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

/// Force-refresh path for *external* changes to `kKKParamMultiStageData`
/// (host cmd-Z reverts the param outside our action scopes). The hot
/// `multiStageSyncFromParams` short-circuits on a stale in-memory snapshot
/// + lastPushed pointer; this method busts those caches and re-reads JSON
/// straight from the param, then pushes to seq. Plugins should call from
/// their `parameterChanged:` when `parameterID == kKKParamMultiStageData`.
+ (void)multiStageRefreshFromParamForAPI:(id<PROAPIAccessing>)apiManager;

/// Force-refresh path for `kKKParamTimingLoopEnabled` - read the current
/// param value and push it to all rulers' `loopEnabled`. Plugins call from
/// `parameterChanged:` when the loopback param changes (host cmd-Z, etc).
+ (void)multiStageRefreshLoopFromParamForAPI:(id<PROAPIAccessing>)apiManager;
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

/// Per-layer variant: scopes the lookup to the lane whose `groupKey`
/// matches. Use when a plugin has multiple lanes sharing a property label
/// (one per layer/group). When `groupKey` is nil, behaves like the
/// label-only overload.
+ (BOOL)multiStageOSCVisibleForAPI:(id<PROAPIAccessing>)apiManager
                             label:(NSString *)label
                          groupKey:(nullable NSString *)groupKey;

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

/// After `handleLinkedParameterChanged:` writes the partner via
/// `setFloatValue:`, FCP does NOT echo a separate `parameterChanged:` for
/// the partner (FCP suppresses recursive echoes). This means
/// `parameterChanged:`-driven persistence (e.g. Canvas's
/// `kkPushParamToLane:`) never runs for the partner, and any backing
/// blob/path-side effect for it is skipped - the inspector value updates
/// but the persistent state lags. Plugins that mirror inspector values
/// to a backing blob should query this after `handleLinkedParameterChanged:`
/// returns and run the same per-edit hook for the partner ID. Returns 0
/// when the last call did not write a partner.
- (UInt32)linkedPartnerWrittenForLastChange;

/// Returns the current "live" values for the lane labeled `label` from the
/// plugin's source of truth (FxPlug params for built-in plugins, per-layer
/// state for Canvas, etc). Used by the segment-select handler to write back
/// any in-flight inspector edits into the previously selected segment
/// before switching. Returns nil when the label is unknown.
/// `groupKey` is the lane's `groupKey` (Canvas: layer UUID) or nil for
/// flat plugins where the propertyLabel uniquely identifies the lane.
- (nullable NSArray<NSNumber *> *)
    currentValuesForLaneLabel:(NSString *)label
                     groupKey:(nullable NSString *)groupKey
                       atTime:(CMTime)time;

/// Disables (or re-enables) inspector editing for the lane's underlying
/// params. Called when a lane's selected segment is an HTH transition
/// (whose values are derived from the surrounding holds, so editing them
/// would be a no-op). Plugins toggle `kFxParameterFlag_DISABLED` on each
/// underlying paramID; Canvas-style plugins with no per-lane FxPlug params
/// can no-op. `groupKey` disambiguates lanes sharing a propertyLabel.
- (void)setEditingDisabled:(BOOL)disabled
              forLaneLabel:(NSString *)label
                  groupKey:(nullable NSString *)groupKey;

/// Pushes lane values back into the plugin's source of truth so the
/// inspector reflects the newly selected segment (and downstream non-FxPlug
/// UI like the gradient control stays in sync). Plugins are responsible
/// for clearing any DISABLED flags they had set on involved params, since
/// FxPlug silently drops writes to disabled params. Returns YES if the
/// label was recognized. `groupKey` disambiguates lanes sharing a
/// propertyLabel.
- (BOOL)applyLaneValues:(NSArray<NSNumber *> *)values
               forLabel:(NSString *)label
               groupKey:(nullable NSString *)groupKey
                 atTime:(CMTime)time;

/// Override to return the seed lanes used when no persisted JSON exists.
/// Each lane should have `propertyLabel`, `valueComponentKinds`, and a
/// single Hold segment whose `values` reflects the current FxPlug param
/// state. Returns nil/empty when the plugin has no animation lanes.
- (nullable NSArray<KKTimingLane *> *)
    defaultLanesAtTime:(CMTime)time
           paramGetAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI;

/// Override for plugins whose lane set tracks an external source (Canvas:
/// the layer list). Receives the lanes just read from JSON and returns a
/// reconciled array - typically by matching existing lanes against the
/// current source items via `groupKey`, updating labels, dropping stale
/// entries, and seeding lanes for new items. Default returns `existing`
/// unchanged. The framework persists the new array when it differs from
/// the input.
- (nullable NSArray<KKTimingLane *> *)
    reconcileLanes:(NSArray<KKTimingLane *> *)existing
            atTime:(CMTime)time
       paramGetAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI;

/// Optional cheap fingerprint of the inputs `reconcileLanes:` would consume
/// (for Canvas: layerIDs + the path bits that flip lane visibility/labels).
/// Computed from in-memory state - must NOT do FCP param I/O. The pump
/// short-circuits the reconcile (skipping the JSON read + plugin call)
/// when the fingerprint matches the previous successful reconcile.
/// Default returns nil → no caching, current behavior preserved.
- (nullable NSString *)kkReconcileFingerprintForAPI:
    (id<PROAPIAccessing>)apiManager;

/// Override to return YES when the plugin registers motion blur params
/// via `addMotionBlurParametersWithAPI:`. Default NO. Used to auto-include
/// the Motion Blur section in the help window.
- (BOOL)usesMotionBlur;

/// Override to hide specific animatable-property lanes from the multi-stage
/// sequencer based on current parameter state (e.g. a Color lane should
/// disappear when the plugin is in gradient-only mode). Segment data stays
/// in JSON - the lane reappears when the set no longer contains its label.
/// Call `-multiStageRefreshLaneVisibility` after any param change that would
/// affect the return value; the pump applies the filter on every push.
- (NSSet<NSString *> *)hiddenAnimatablePropertyLabels;

/// Override to declare which animatable-property labels render an on-screen
/// control (OSC) on canvas. Lanes in this set get a visibility-toggle icon
/// in the sequencer row; their OSC code checks `lane.oscVisible` before
/// drawing.
- (NSSet<NSString *> *)animatablePropertyLabelsWithOSC;

/// Override to declare labels whose lane should seed with `oscVisible = NO`.
/// Used for OSC parts that are only shown via a modifier (e.g. rotation X/Y
/// rings revealed by holding Opt) and shouldn't appear by default. Returns an
/// empty set by default.
- (NSSet<NSString *> *)animatablePropertyLabelsWithOSCDefaultOff;

/// Override to drive the sequencer's "selected group" highlight - return
/// the `groupKey` (typically a layer/object ID) of the currently-selected
/// item, or nil for none. The default returns nil.
///
/// When selection changes, call `-kkRefreshSequencerSelectedGroup` to push
/// the new value into all active sequencer views.
- (nullable NSString *)kkSelectedGroupKey;

/// Override to handle a track-side click on a group header in the sequencer
/// (the summary span bar, not the chevron/label). The default falls back
/// to toggling the group's collapse state - i.e. behaves identically to
/// clicking the label. Plugins that want a custom action (e.g. selecting
/// the underlying object so editing is faster while animating) override
/// this and dispatch their own selection write.
- (void)kkHandleGroupSegmentClickedForKey:(NSString *)groupKey;

/// Identifies how the sequencer's segment-add/remove handlers mutated a
/// lane. Passed to the subclass hook below.
typedef NS_ENUM(NSInteger, KKLaneSegmentMutation) {
  KKLaneSegmentMutationInserted = 0,
  KKLaneSegmentMutationRemoved = 1,
};

/// Subclass hook: invoked inside the action scope after a sequencer-driven
/// segment add/remove has been written to a lane, before
/// `timingGraphApplyState`. Plugins override this to keep out-of-band
/// per-segment storage in sync (e.g. Canvas's path-morph snapshots, which live
/// on the path blob rather than in the lane's `values`). `lane` is the
/// post-mutation lane; `index` is the inserted or removed segment index. The
/// default implementation does nothing.
- (void)kkHandleLaneSegmentMutation:(KKLaneSegmentMutation)mutation
                               lane:(KKTimingLane *)lane
                            atIndex:(NSInteger)index
                             getAPI:(id<FxParameterRetrievalAPI_v6>)getAPI
                             setAPI:(id<FxParameterSettingAPI_v5>)setAPI;

/// Subclass hook: invoked inside the action scope after `selectedSegment`
/// changes on a lane, before applyState. Plugins override this to load
/// out-of-band per-segment state into the source of truth (e.g. Canvas
/// loads `morphTargets[segment]` into the path's points so the canvas
/// shows the segment's authored geometry while the user edits it). The
/// default implementation does nothing. Mirrors `applyLaneValues:` but
/// runs alongside it for non-scalar payloads.
- (void)kkLoadLaneSegmentForLabel:(NSString *)label
                         groupKey:(NSString *)groupKey
                          segment:(NSInteger)segmentIndex
                           getAPI:(id<FxParameterRetrievalAPI_v6>)getAPI
                           setAPI:(id<FxParameterSettingAPI_v5>)setAPI;

/// Subclass hook: invoked inside the action scope after a sequencer
/// opt-drag value-copy on a lane. Plugins override this to mirror
/// out-of-band per-segment payloads alongside the scalar values copy
/// (e.g. Canvas duplicates path-morph snapshots). Default no-op.
- (void)kkCopyLaneSegmentForLabel:(NSString *)label
                         groupKey:(NSString *)groupKey
                      fromSegment:(NSInteger)srcSegmentIndex
                        toSegment:(NSInteger)dstSegmentIndex
                           getAPI:(id<FxParameterRetrievalAPI_v6>)getAPI
                           setAPI:(id<FxParameterSettingAPI_v5>)setAPI;

/// Pushes `[self kkSelectedGroupKey]` into every active sequencer view
/// (primary + any additional timing views). Call this whenever your
/// selection state changes.
- (void)kkRefreshSequencerSelectedGroup;

/// Override to supply the empty-state message shown when the sequencer has
/// zero lanes (e.g. Canvas with no layers). Return nil (default) to leave
/// the empty view hidden in that case.
- (nullable NSString *)emptyLanesMessageWhenNoLanes;

/// SF Symbol name paired with `emptyLanesMessageWhenNoLanes`. Default
/// `rectangle.on.rectangle.slash` matches the "all lanes hidden" state.
- (NSString *)emptyLanesIconNameWhenNoLanes;

/// Reads the bool at forceShowParamID; if YES, sets every param in paramIDs
/// to kFxParameterFlag_DEFAULT and returns YES.  Caller should early-return
/// from updateParameterVisibilityAtTime: when this returns YES.
- (BOOL)forceShowAllParametersIfEnabled:(UInt32)forceShowParamID
                               paramIDs:(NSArray<NSNumber *> *)paramIDs
                                 atTime:(CMTime)time;

/// Subclass hook: return YES when the plugin's "Force Show All Parameters"
/// toggle is on. `updateTimingParameterVisibility` and
/// `updateMotionBlurParameterVisibility` treat their group as expanded when
/// this returns YES, mirroring Canvas's `(expanded || forceShow)` pattern.
/// Default NO.
- (BOOL)forceShowAllParameters;

/// Indicates whether this effect requires the user to wrap their footage
/// in an Adjustment Clip or a Compound Clip before applying. The help
/// window auto-prepends a matching tip when this is non-`None`.
typedef NS_ENUM(NSInteger, KKClipWrappingMode) {
  /// No wrapping required - clips can take the effect directly.
  KKClipWrappingModeNone = 0,
  /// Effect samples underlying frames - needs an Adjustment
  /// Clip or Compound Clip so it sees moving content.
  KKClipWrappingModeAdjustmentOrCompound,
  /// Effect transforms a single clip past its natural bounds
  /// - needs a Compound Clip to avoid being clipped.
  KKClipWrappingModeCompound,
};

/// Override to declare how this effect needs to be wrapped before use.
/// Default: `KKClipWrappingModeNone`.
- (KKClipWrappingMode)clipWrappingMode;

/// Reads the flat JSON dict stored at `paramID`, patches `{key: value}` into
/// it, and writes it back - all in a fresh action scope. Suitable for any
/// plugin that keeps lightweight UI state (tab index, toggle values, etc.) in
/// a single custom-string param as a JSON object. The param must already be
/// registered as a custom-string parameter.
- (void)patchUIStateKey:(NSString *)key value:(id)value paramID:(UInt32)paramID;

/// Like `patchUIStateKey:value:paramID:` but patches several keys into the JSON
/// dict in ONE action scope, so a set of related UI-state changes lands as a
/// single undo entry (avoids the "takes two cmd-Z" problem of back-to-back
/// single-key writes).
- (void)patchUIStateKeys:(NSDictionary<NSString *, id> *)values
                 paramID:(UInt32)paramID;

/// Persists the "Maintain Timing" toggle into the UI-state blob at `paramID`.
/// When enabling, captures the current source-media in-point + clip duration
/// (read from FxTimingAPI inside the action scope) as the anchor the render
/// remap pins keyposes to, so trimming/growing/splitting holds their absolute
/// position. All keys are written in one action scope (single undo entry).
- (void)patchMaintainTimingEnabled:(BOOL)enabled paramID:(UInt32)paramID;

/// "Maintain Timing" bake. Call from the render tick (after
/// KKRefreshRenderCache populates `cache`). When the lock is on and the clip's
/// source range has moved away from the stored anchor (a trim/grow surfaced
/// this tick), it rewrites the timeline blob's keypose fractions to hold their
/// absolute media position and advances the anchor - both in one action scope
/// (dispatched to the main queue, since the render tick has no action scope).
/// The blob write flows to the Advanced graph via the normal parameterChanged
/// path, so the keyposes visibly move. A per-tick guard on `cache` makes it
/// fire once per trim, not every frame while the async write is in flight.
/// No-op when the lock is off, no anchor is set, or the range already matches.
- (void)bakeMaintainTimingForCache:(KKRenderCache *)cache
                   timelineParamID:(UInt32)timelineParamID
                    uiStateParamID:(UInt32)uiStateParamID;

/// The plugin's timeline inspector, if open. Override to return it so the bake
/// can push the retimed timeline straight to the graph (the parameterChanged
/// round-trip from a self-write isn't always reliable). Default nil.
- (nullable KKTimelineInspectorView *)maintainTimingInspectorView;

/// Maintain-timing persistence override point. Retime the stored animation
/// blob(s) from the old media anchor [fromSrcIn,fromDur] to the new clip range
/// [toSrcIn,toDur], writing the result back under `timelineParamID`. The
/// default retimes the single kKKParamTimelineData KKTimeline. A per-layer
/// plugin (Canvas) overrides it to retime every layer's animationJSON in its
/// layer blob. Return the timeline to push to the inspector graph, or nil to
/// skip that push (a plugin that refreshes its own multi-layer graph returns
/// nil). Called inside the bake's action scope.
- (nullable KKTimeline *)
    _retimeMaintainTimingBlobWithParamID:(UInt32)timelineParamID
                                  getAPI:(id<FxParameterRetrievalAPI_v6>)getAPI
                                  setAPI:(id<FxParameterSettingAPI_v5>)setAPI
                               fromSrcIn:(double)fromSrcIn
                                 fromDur:(double)fromDur
                                 toSrcIn:(double)toSrcIn
                                   toDur:(double)toDur
                                 edgeEps:(double)edgeEps;

/// Override to provide help/keyboard-shortcut sections. Each section is
/// rendered as a titled block with a tips bullet list and/or a 2-column
/// shortcuts table. Returning a non-empty array makes the logo-banner
/// help button visible. Default: empty array.
- (NSArray<KKHelpSection *> *)helpSections;

/// Override to give the help window a title bar at the very top: the plugin's
/// name beside its icon, so it's clear which plugin the window belongs to. If
/// a `helpSections` entry carries the same title, its inline heading is
/// dropped (the title now lives in the header) and its body is promoted to an
/// intro block above the contents table. Default: nil (no header bar).
- (nullable NSString *)helpHeaderTitle;

/// SF Symbol or image shown beside `helpHeaderTitle` in the help window's top
/// title bar. Default: nil.
- (nullable NSImage *)helpHeaderIcon;

/// Build a help section whose tips are rendered from one of this plugin's
/// bundled `AIKnowledge` markdown topics - the same `.md` the AI assistant
/// reads - so the help window and the AI stay single-sourced. `topicID` is the
/// `.md` filename (no extension) in the plugin bundle's `AIKnowledge`
/// subdirectory. Markdown `**bold**` renders as an accent run and `` `code` ``
/// as a key badge. `localizer`, if non-nil, localizes each rendered tip - pass
/// your plugin's Loc (e.g. `^(NSString *s){ return MMLoc(s, @"..."); }`) so the
/// translations live in your plugin's own catalog. `symbol` is an optional SF
/// Symbol name for the section icon. Tips are empty if the topic file is
/// missing. Use this from `-helpSections`.
- (KKHelpSection *)helpSectionFromKnowledgeTopic:(NSString *)topicID
                                           title:(NSString *)title
                                          symbol:(nullable NSString *)symbol
                                       localizer:(nullable NSString * (^)(
                                                     NSString *tip))localizer;

/// The generic on-screen-control + mini-viewer shortcut rows that every plugin
/// with on-screen controls shares (hide a control, reveal hidden ones, reset
/// the mini-viewer zoom). Append your plugin-specific rows and pass the
/// combined array as a help section's `shortcuts`, so each plugin's shortcuts
/// table lists its own gestures plus the shared ones. Localized via the kit
/// catalog.
+ (NSArray<KKHelpShortcut *> *)sharedOnScreenControlShortcuts;

/// Override to provide interactive guide entries shown at the top of the
/// help window. Each guide has a title, optional subtitle, and an onStart
/// block that launches the in-inspector walkthrough. Default: empty array.
- (NSArray<KKHelpGuide *> *)helpGuides;

/// Override to return an NSNotificationName that signals guide enabled-state
/// may have changed. When non-nil, the help window automatically calls
/// refreshGuideRows when the notification is posted. Default: nil.
- (nullable NSNotificationName)helpGuideRefreshNotificationName;

/// Opens the host's remote window with the rendered `helpSections` and guides.
- (void)openHelpRemoteWindow;

/// Override to attach an AI accessory view (built via `KeyframelessAI`'s
/// `KKAIBannerHost`) to the leading edge of the logo banner. Default: nil
/// (no AI button).
- (nullable NSView *)aiAccessoryView;

/// Generic host remote-window presenter. Runs the required action scope,
/// resolves FxRemoteWindowAPI, attaches to the correctly-sized superview,
/// clears any prior remote content, and wraps `contentProvider()`'s view in a
/// key handler that forwards Space / Cmd-Z / Cmd-Shift-Z to the host command
/// API. Every plugin's remote window (help, editor, …) gets those keystrokes
/// for free. The provider is invoked on the reply to build the content view.
- (void)presentRemoteWindowOfSize:(CGSize)size
                  contentProvider:(NSView * (^)(void))contentProvider;

/// Asks the host to close this instance's remote window if the resolved
/// FxRemoteWindowAPI supports it (v3+). Runs inside an action scope.
- (void)closeRemoteWindowIfSupported;

/// Creates a collapsible group header view wired to a hidden bool toggle.
/// Use from createViewForParameterID: - the returned view reads/writes
/// the expanded state at expandedParamID via an action scope.
- (NSView *)createGroupHeaderWithTitle:(NSString *)title
                                  icon:(nullable NSImage *)icon
                           parameterID:(UInt32)parameterID
                       expandedParamID:(UInt32)expandedParamID
    NS_RETURNS_RETAINED;

/// Same as above but with a checkbox bound to `enabledParamID`. The two
/// extra closures run **inside** the same action scope as the bool write,
/// so any extra writes (e.g. mutating selected-path properties for the
/// undo entry to coalesce) coalesce with the user's checkbox/chevron
/// change as one undo entry - matches motion blur's pattern. Pass nil if
/// not needed. The header is auto-registered via `registerGroupHeader:`.
- (KKCustomGroupHeaderView *)
    createCheckboxGroupHeaderWithTitle:(NSString *)title
                                  icon:(nullable NSImage *)icon
                        enabledParamID:(UInt32)enabledParamID
                       expandedParamID:(UInt32)expandedParamID
                        onEnabledExtra:(void (^_Nullable)(
                                           BOOL isEnabled,
                                           id<FxParameterSettingAPI_v5> setAPI))
                                           onEnabledExtra
                       onExpandedExtra:(void (^_Nullable)(
                                           BOOL isExpanded,
                                           id<FxParameterSettingAPI_v5> setAPI))
                                           onExpandedExtra NS_RETURNS_RETAINED;

/// Re-reads `expandedParamID` and pushes the result into the matching
/// generic group header's `isExpanded` (chevron). Plugins should call this
/// from `parameterChanged:` when host undo/redo of the expanded bool param
/// could leave the chevron out of sync with the persisted state. No-op if
/// no header was registered for that paramID.
- (void)syncGroupHeaderExpandedForExpandedParamID:(UInt32)expandedParamID;

/// Writes `lanes` to `kKKParamMultiStageData` (KKDataBlob, undoable) and
/// the lockstep `kKKParamMultiStageDataMirror` (native string, OSC/render
/// readable), and updates the per-instance lanesSnapshot. Plugins that
/// mutate lanes outside the standard kit handlers (e.g. routing inspector
/// slider edits into the selected segment) MUST use this rather than
/// writing the blob directly - otherwise the mirror trails and the render
/// scope reads stale lane values until something else triggers a write.
/// Caller must already be inside an FxCustomParameterActionAPI_v4 scope.
/// Convenience wrapper around the C-level `KKWriteLanesJSON`.
- (void)kkWriteLanesJSON:(NSArray<KKTimingLane *> *)lanes
                  setAPI:(id<FxParameterSettingAPI_v5>)setAPI;

/// Re-reads `enabledParamID` (a native bool toggle) and pushes the result
/// into the matching group header's `isEnabled` (checkbox). Counterpart
/// to `syncGroupHeaderExpandedForExpandedParamID:` for plugins whose
/// headers expose a checkbox. No-op if no header was registered for the
/// matching enabled paramID.
- (void)syncGroupHeaderEnabledForEnabledParamID:(UInt32)enabledParamID
                                         atTime:(CMTime)time;

/// Register an externally-built group header so KK kit's sync helpers can
/// find and update it from `parameterChanged:`. Use when a plugin builds
/// its own header (e.g. with a checkbox) instead of going through
/// `createGroupHeaderWithTitle:…`. Pass `enabledParamID = 0` if the header
/// has no checkbox. Map values are weak - caller retains the header.
- (void)registerGroupHeader:(KKCustomGroupHeaderView *)header
             enabledParamID:(UInt32)enabledParamID
            expandedParamID:(UInt32)expandedParamID;

/// FxPlug calls this to learn the value classes for any custom parameter
/// when unarchiving a saved project. Subclasses MUST call super and union
/// in their own KKDataBlob param IDs (e.g. expand-state blobs created by
/// `addCropParametersWithAPI:` or any plugin-local custom blob param).
/// Reads return nil and saved state evaporates if the class isn't
/// registered here. Base impl covers KKMultiStage / Gradient / Color /
/// Timing / MotionBlur expand state.
- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID;

@end

/// C-callable counterpart to `-[KKPlugin kkWriteLanesJSON:setAPI:]` for
/// callers outside the plugin instance (e.g. an OSC principal with its
/// own apiManager). Caller must already be inside an action scope.
extern void KKWriteLanesJSON(NSArray<KKTimingLane *> *_Nonnull lanes,
                             id<FxParameterSettingAPI_v5> _Nonnull setAPI,
                             id<PROAPIAccessing> _Nullable apiManager);

/// Stack-style undo grouping. Pair every `KKBeginUndoGroup` with exactly
/// one `KKEndUndoGroup` along every code path (including early returns).
/// Returns YES if the group was actually started - pass that BOOL into
/// `KKEndUndoGroup` so the end is a no-op when the start was a no-op.
/// Nested calls return NO; only the outermost begin/end pair starts the
/// host-level undo group.
extern BOOL KKBeginUndoGroup(id<PROAPIAccessing> _Nullable apiManager,
                             NSString *_Nonnull name);
extern void KKEndUndoGroup(id<PROAPIAccessing> _Nullable apiManager,
                           BOOL started);

@interface KKPlugin (MultiStageInstance)
/// Recomputes `-hiddenAnimatablePropertyLabels`; if it differs from the last
/// snapshot, re-pushes the filtered lanes to the sequencer view. Safe to
/// over-call.
- (void)multiStageRefreshLaneVisibility;
@end

/// The `sourceImages` tile belonging to an image-well parameter, or nil when
/// the well is empty or was never requested.
///
/// Found by parameter ID rather than by INDEX, which is the whole point: a
/// plug-in's `-scheduleInputs:` can return a varying number of effect-clip
/// tiles (motion-blur sub-frames, a boundary preview), so a well's position in
/// the array moves under you. The tile is only present at all if
/// `-scheduleInputs:` asked for it with `kFxImageTileRequestSourceParameter`
/// and this ID.
FOUNDATION_EXPORT FxImageTile *_Nullable KKImageTileForParameterID(
    NSArray<FxImageTile *> *_Nullable sourceImages, UInt32 parameterID);

NS_ASSUME_NONNULL_END
