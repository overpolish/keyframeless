/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMetalDeviceCache.h>
#import <KeyframelessKit/KKTimeline.h>
#import <Metal/Metal.h>

@class FxImageTile;
@class KKMiniViewerFeed;
@class KKCustomGroupHeaderView;
@class KKHelpSection;
@class KKHelpShortcut;
@class KKHelpGuide;
@class KKDragUndoSession;
@class KKLinkLayerSource;
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

/// The mini-viewer drag's undo session (group-only mode: begin/end each in
/// their own brief scope, per-tick writes self-scope). Owned here so the
/// standard inspector callbacks and any teardown path share one lifecycle;
/// the session's dealloc safety net closes an interrupted drag's group.
@property(nonatomic, strong, nullable) KKDragUndoSession *miniDragSession;

/// The mini-viewer source feed published from renderDestinationImage: and the
/// descriptor path it was created with. Managed by the shared feed-publish
/// helper (see KKPlugin+MiniViewerFeed); recreated when the path changes.
@property(nonatomic, strong, nullable) KKMiniViewerFeed *miniViewerFeed;
@property(nonatomic, copy, nullable) NSString *miniViewerFeedPath;
/// Smoothed lead of the render stream over the playhead, in clip fractions,
/// maintained by the feed helper. < 0 until a first sample lands.
///
/// The raw playhead sample is far COARSER than the frame tags (measured: ~15Hz
/// against a 60Hz tag stream, because the poller is a main-queue timer in a
/// process that is busy rendering), so subtracting it directly quantised the
/// animation into 4-frame steps. The lead itself is near-constant, so smoothing
/// it and subtracting from the per-frame tag keeps 60Hz smoothness AND
/// playhead-correct timing.
@property(atomic) double miniViewerPlayheadLead;

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
/// Layered link discovery (layers are "sub-clips": Canvas layers). Default
/// nil = a flat source. Override to advertise per-layer params: return one
/// KKLinkLayerSource per layer (stable layerID + display name + that layer's
/// EFFECTIVE `lanes`); tokens store `${uuid.layerID.label}` and the picker
/// shows Clip > Layer > Param. Combines with -linkableLanesForManifest for
/// any clip-wide params (either may be nil, not both).
- (nullable NSArray<KKLinkLayerSource *> *)linkableLayersForManifest;
/// Display name for this plugin in the reference picker ("<name> @
/// <timecode>"). Defaults to the bundle name. Override to force a specific
/// label.
- (NSString *)linkManifestEffectName;
/// What the picker SHOWS for this instance, as "<name> @ <timecode>". Defaults
/// to -linkManifestEffectName. Override when an instance has a name of its own
/// (Mirage returns the running shader's name), so a project with several of the
/// same effect reads as its content rather than N identical rows. Distinct from
/// -linkManifestEffectName on purpose: that one is the bus's scoping key and
/// must stay constant per plugin.
- (NSString *)linkManifestDisplayName;
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

/// Override to return YES when the plugin registers motion blur params
/// via `addMotionBlurParametersWithAPI:`. Default NO. Used to auto-include
/// the Motion Blur section in the help window.
- (BOOL)usesMotionBlur;

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

/// The plugin's inspector custom-UI view, set by createViewForParameterID:.
/// Owned by the BASE class so shared kit hooks (maintain-timing, group-header
/// sync, param-changed pushes) can reach the inspector without every subclass
/// re-plumbing it. Subclasses redeclare it covariantly (their concrete
/// KKTimelineInspectorView subclass) with `@dynamic inspectorView;` so typed
/// access rides this one storage.
@property(nonatomic, weak, nullable) KKTimelineInspectorView *inspectorView;

/// Returns a copy of `timeline` with every lane's lastKnownClipDuration
/// stamped to the effect's CURRENT duration (via FxTimingAPI), so
/// locked-seconds rebalancing sees the real clip length. Passthrough when
/// `timeline` is nil or the duration is unavailable. Call sites must be in a
/// scope where FxTimingAPI resolves.
- (nullable KKTimeline *)timelineStampedWithClipDuration:
    (nullable KKTimeline *)timeline;

/// Registers the standard hidden-param spine every timeline plugin needs, in
/// canonical order: the logo banner, the full-width inspector custom UI
/// (`inspectorUIID`, disabled until the view exists), the UI-state blob, the
/// timeline blob (kKKParamTimelineData), the render-nudge blob, the
/// motion-blur blob (kKKParamMotionBlurData, seeded with
/// `motionBlurDefaultJSON` when non-nil), and the per-instance UUID string
/// (kKKParamInstanceID). Returns the creation API for the plugin's domain
/// params, or nil with `error` set. Visible domain params registered after
/// this call land after the inspector UI, matching the previous per-plugin
/// registration order.
- (nullable id<FxParameterCreationAPI_v5>)
    kkAddStandardParametersWithInspectorUI:(UInt32)inspectorUIID
                                   uiState:(UInt32)uiStateID
                               renderNudge:(UInt32)renderNudgeID
                     motionBlurDefaultJSON:(nullable NSString *)mbDefaultJSON
                                     error:(NSError **)error;

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

/// One undoable mutation: opens an FxCustomParameterActionAPI scope for
/// `principal` (the plugin instance, or an OSC principal with its own
/// apiManager), begins a host undo group named `name` (nil = scope-only, for
/// the per-tick OSC drag model that relies on FCP's implicit same-target
/// coalescing), resolves the get/set APIs, and runs `block`. Scope and group
/// close in @finally, so nothing `block` does can leak an open scope (which
/// wedges FCP's undo - its next beginWithUndoState aborts). Returns NO when
/// the action API is unavailable (block not run). Free function so
/// non-plugin classes (inspector views, layer lists) can use it too.
/// Bracket a MULTI-WRITE mutation in one host undo group where each write in
/// `block` manages its OWN action scope. The group begin/end each get a brief
/// scope; holding one scope across the block would nest the writes' scopes
/// (FFUIAction assert). Complement to KKPerformUndoable below.
extern void KKWithHostUndoGroup(id<PROAPIAccessing> _Nullable apiManager,
                                id _Nonnull principal, NSString *_Nonnull name,
                                void (^_Nonnull block)(void));

extern BOOL KKPerformUndoable(
    id<PROAPIAccessing> _Nullable apiManager, id _Nonnull principal,
    NSString *_Nullable name,
    void (^_Nonnull block)(id<FxParameterRetrievalAPI_v6> _Nullable getAPI,
                           id<FxParameterSettingAPI_v5> _Nullable setAPI,
                           CMTime actionTime));

/// Localized labels for host undo groups (FCP shows "Undo <label>" in the
/// Edit menu). The one table for undo wording: every label lives here and in
/// KKLocalizable.xcstrings - never pass an inline string literal as a group
/// name at a call site.
FOUNDATION_EXPORT NSString *KKUndoLabelAdjust(NSString *productName);
FOUNDATION_EXPORT NSString *KKUndoLabelEditGradient(void);
FOUNDATION_EXPORT NSString *KKUndoLabelDuplicateLayer(void);
FOUNDATION_EXPORT NSString *KKUndoLabelDeleteLayer(void);
FOUNDATION_EXPORT NSString *KKUndoLabelGroupLayers(void);
FOUNDATION_EXPORT NSString *KKUndoLabelMoveLayer(BOOL up);

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
