/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKMotionBlur.h>
#import <KeyframelessKit/KKTimelineInspectorButtons.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingStage.h>

@protocol PROAPIAccessing;
@protocol KKMiniViewerDelegate;

NS_ASSUME_NONNULL_BEGIN

/// Tab indices used by the inspector's tab bar. Plugins typically host both;
/// the Advanced view is wired in once `KKTimelineSequencerView` lands.
typedef NS_ENUM(NSInteger, KKTimelineTab) {
  KKTimelineTabBasic = 0,
  KKTimelineTabAdvanced = 1,
};

/// Plugin-agnostic timeline inspector. Composes the play / loop / reset
/// toolbar, the Basic↔Advanced tab bar, the detach + constants buttons and
/// the timeline content area into one reusable shell. Plugins drop in their
/// `KKMiniViewerRenderer` subclass + a few config properties; everything
/// else (layout, button wiring, live-push setters, detach-copy plumbing) is
/// shared.
///
/// Subclasses (e.g. a plugin's own tour-aware inspector) override
/// `applyTimeline:` and `beginDetachedCopy` calling `super` to add their
/// own per-instance work; the standard plumbing stays.
@interface KKTimelineInspectorView : NSView

#pragma mark - Configuration (plugin-specific, set after init)

/// Cross-process tmp-file path the `KKMiniViewerFeed` publishes to.
@property(nonatomic, copy, nullable) NSString *miniViewerDescriptorPath;
/// Reverse channel: the boundary-popover writes the requested clip
/// fraction here; the render side reads it in `-scheduleInputs:`.
@property(nonatomic, copy, nullable) NSString *miniViewerRequestPath;
/// Plugin's mini-viewer delegate (typically a `KKMiniViewerRenderer`
/// subclass) - supplies the effect render + point-handle vocabulary.
@property(nonatomic, strong, nullable) id<KKMiniViewerDelegate>
    miniViewerDelegate;
/// Forwarded to the lanes view (and on to the popover mini): when YES, clicking
/// the mini makes it the key window so bare keys (e.g. Delete) are handled in
/// the popover instead of reaching the host. Default NO.
@property(nonatomic) BOOL miniGrabsKeyFocusOnClick;
/// Lane label the "manage properties" popover highlights for the first-run
/// spotlight (e.g. @"Radius"). nil = no spotlight.
@property(nonatomic, copy, nullable) NSString *managePopoverSpotlightLabel;
/// Title drawn on the Constants button. Default @"Constants".
@property(nonatomic, copy) NSString *constantsButtonTitle;
/// Namespace the Presets row reads/writes under (the plugin's bundle id). Set
/// by the host during inspector wiring; nil disables built-ins lookup. Used
/// only when `showsPresetsRow` is YES.
@property(nonatomic, copy, nullable) NSString *presetPluginKey;

#pragma mark - Callbacks (host wires playback / loop param / FxRemoteWindow)

@property(nonatomic, copy, nullable) void (^onLoopToggled)(BOOL enabled);
/// "Maintain Timing" toggle flipped. The host persists the flag in its
/// UI-state blob and (when turning on) captures the absolute source-media
/// anchor so later trims/grows re-derive keypose fractions instead of
/// rescaling them.
@property(nonatomic, copy, nullable) void (^onMaintainTimingToggled)
    (BOOL enabled);
@property(nonatomic, copy, nullable) void (^onTabChanged)(NSInteger tab);
/// The "On-Screen Controls" master tick was toggled. The host persists the
/// flag (its UI-state blob) and updates its per-instance OSC-visibility cache.
/// Only fired when `showsOSCVisibilityRow` is YES.
@property(nonatomic, copy, nullable) void (^onOSCVisibleToggled)(BOOL visible);

/// The OSC elements shown as pills in the gear popover, grouped into compounds
/// rendered as `KKCompoundPillBar` capsules (e.g. @[ @[@"Position"],
/// @[@"Rotation", @"X", @"Y", @"Z"] ] - a plain Position pill plus a Rotation
/// master + per-ring capsule). Each label's last dot-separated component is
/// localized for display. Empty/nil hides the gear. Used only when
/// `showsOSCVisibilityRow` is YES.
@property(nonatomic, copy, nullable)
    NSArray<NSArray<NSString *> *> *oscVisibilityCompounds;
/// Returns the current on/off state per compound/segment (matching the shape of
/// `oscVisibilityCompounds`). Queried each time the popover opens so the pills
/// reflect the latest state.
@property(nonatomic, copy, nullable)
    NSArray<NSArray<NSNumber *> *> *_Nonnull (^oscVisibilityElementStates)(void)
        ;
/// A pill was toggled: compound + segment index into `oscVisibilityCompounds`
/// and its new state. The host updates its per-instance cache + persists.
@property(nonatomic, copy, nullable) void (^oscVisibilityElementToggled)
    (NSInteger compoundIndex, NSInteger segmentIndex, BOOL isOn);
/// Any motion-blur edit (enable toggle, a Shutter/Samples slider/field, or the
/// Quality pill in the settings popover). `shutterAngle` is degrees (0–360);
/// `samples` is the sample count (2–128, Accurate only); `technique` is how the
/// blur is computed (see `KKMotionBlurTechnique`). The host writes the full
/// `{enabled,shutterAngle,samples,technique}` blob. Only fired when
/// `showsMotionBlurRow` is YES. Wrap continuous slider drags with
/// `onDragBegin`/`onDragEnd` for undo coalescing (same chain the mini-viewer
/// handles use).
@property(nonatomic, copy, nullable) void (^onMotionBlurChanged)
    (BOOL enabled, double shutterAngle, NSInteger samples,
     KKMotionBlurTechnique technique);
@property(nonatomic, copy, nullable) void (^onTimelineMutated)
    (KKTimeline *updated);
/// A CONTENT preset was applied (one carrying a `payloadKind`): the plugin
/// inserts the decoded content rather than applying a timeline curve (e.g.
/// Canvas decodes a `"canvasLayers"` payload into a new layer). Only fired for
/// presets with a payload; timeline presets use the normal apply path. `atPlayhead`
/// mirrors the preset apply intent (the plugin decides what it means).
@property(nonatomic, copy, nullable) void (^onApplyPresetPayload)
    (NSString *payloadKind, NSString *payloadJSON, BOOL atPlayhead);
/// Fired right before the Constants popover opens (button tap), so a
/// multi-owner host can switch the selected owner to one that actually has
/// constants (the popover shows the selected owner's constants - landing on an
/// empty one would open nothing). Runs synchronously before the popover reads
/// the timeline.
@property(nonatomic, copy, nullable) void (^onConstantsWillShow)(void);
/// Start / end of a continuous mini-viewer handle drag - host wraps the
/// burst of `onTimelineMutated` writes in one undo group.
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
/// Playhead scrub. The plugin owns the FxCommandAPI move (action scope).
@property(nonatomic, copy, nullable) void (^onScrub)(double frac);
/// Spacebar pressed while inspector has key focus (host swallows it
/// otherwise). The plugin runs `kFxCommand_TogglePlayback`.
@property(nonatomic, copy, nullable) void (^onTogglePlayback)(void);
/// A boundary-value popover just opened; the render side needs to resolve
/// the requested frame. The plugin owns the FxCommandAPI call.
@property(nonatomic, copy, nullable) void (^onBoundaryPreviewNeedsRender)(void);
/// Detach button tapped. Host opens / closes its remote window; query
/// `hasDetachedWindow` to decide.
@property(nonatomic, copy, nullable) void (^onToggleDetached)(void);

#pragma mark - Plugin-extensible gap popover

/// Lets plugins inject extra rows (toggles, sliders, etc.) into the
/// curve/modulation gap popover. Return nil/empty for no extras. The
/// `representative` interval is the lane's own interval for Advanced; for
/// Basic it's the In or Out interval of the first participating lane (read
/// initial state from it, then call `mutate` to write to all targets). Type
/// definitions (`KKGapPopoverPhase`, `KKGapIntervalMutator`) live on
/// `KKTimelineLanesView.h`.
@property(nonatomic, copy, nullable) NSArray<NSView *> * (^gapPopoverExtraRows)
    (KKGapPopoverPhase phase, NSString *_Nullable laneLabel,
     KKInterval *_Nonnull representative, KKGapIntervalReader _Nonnull read,
     KKGapIntervalMutator _Nonnull mutate);

#pragma mark - Read-only state

@property(nonatomic, readonly) KKTimelineLanesView *basicLanesView;
@property(nonatomic, readonly) KKConstantsButton *constantsButton;
/// YES for the secondary copy living in a detached remote window - used to
/// suppress per-instance UI (joyride autostart, the detach button, etc.).
@property(nonatomic, readonly) BOOL isDetachedCopy;
/// YES while a detached copy exists (window open or opening).
@property(nonatomic, readonly) BOOL hasDetachedWindow;

#pragma mark - Lifecycle / live push

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                       loopEnabled:(BOOL)loopEnabled
             maintainTimingEnabled:(BOOL)maintainTimingEnabled
                         activeTab:(NSInteger)activeTab
                    availableLanes:(NSArray<KKLane *> *)availableLanes
                          timeline:(KKTimeline *)timeline
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

- (void)applyTimeline:(KKTimeline *)timeline;
- (void)setLoopEnabled:(BOOL)enabled;
- (void)setMaintainTimingEnabled:(BOOL)enabled;
- (void)setActiveTab:(NSInteger)tab;
/// Push the persisted mini-viewer render mode from the host's UI-state
/// blob. The 3-way pill lives in the keypose-value popover header (only
/// while open); this just mirrors the persisted enum. Defaults to Off.
- (void)setRenderMode:(KKMiniViewerRenderMode)mode;
@property(nonatomic, readonly) KKMiniViewerRenderMode renderMode;
/// Fired when the user picks a different render mode. Host writes back to
/// the UI-state blob via this callback.
@property(nonatomic, copy, nullable) void (^onRenderModeChanged)
    (KKMiniViewerRenderMode mode);
/// The currently selected tab. Lets guides snapshot the state at entry
/// and restore it on completion.
@property(nonatomic, readonly) NSInteger activeTab;
/// Live clip duration (seconds) for the Basic ruler, pushed from the
/// render tick (clip trims never fire `parameterChanged:`).
- (void)setClipDurationSeconds:(double)seconds;
/// The clip duration last set (seconds), 0 if never. Subclasses use it to stamp
/// `lastKnownClipDuration` onto a freshly-built per-layer timeline before
/// publishing it as the viewer-OSC snapshot, so keypose-proximity visibility
/// uses a one-frame epsilon instead of a blind fallback.
- (double)clipDurationSeconds;
/// Live frame duration (seconds) - bounds the scrubber to the last frame.
- (void)setFrameDurationSeconds:(double)seconds;
/// Live playhead position (clip fraction 0–1; < 0 hides) for the scrubber.
- (void)setPlayheadFraction:(double)frac;
/// Playback state - drives the play/pause button color.
- (void)setPlaying:(BOOL)playing;

#pragma mark - Detached copy

/// Build the secondary inspector to embed in the host's remote window and
/// retain it. Uses `[[self class] alloc] init…]` so subclasses produce
/// their own type; subclasses should override to propagate their extra
/// per-instance configuration to the copy (call `super` first).
- (instancetype)beginDetachedCopy;
/// Called when the remote window has closed; resets the button and frees
/// the copy.
- (void)handleDetachedWindowClosed;

#pragma mark - Subclass hooks

/// Whether to build the motion-blur parameter row below the box (and reserve
/// height for it). Default YES. Override to NO in a plugin whose effect has no
/// motion blur. Read once during init.
- (BOOL)showsMotionBlurRow;

/// Whether the host plugin can render the Fast (velocity-reconstruction)
/// technique. Default NO (only the universal Accurate accumulate path). Override
/// to YES in a plugin that emits a velocity buffer (per-object analytic motion,
/// e.g. Canvas / MagicMove); the settings popover then shows the Fast/Accurate
/// Quality pill. A NO host always runs Accurate and hides the pill.
- (BOOL)motionBlurSupportsFastTechnique;

/// The default Accurate-path sample count (2–128) for this plugin - the initial
/// value, the reset target, and what a fresh enable persists. Default 16.
/// Override to tune per plugin (e.g. fewer for heavy per-layer content). Only
/// relevant on the Accurate path (Fast hides the Samples row). Read at init and
/// when the settings popover opens.
- (NSInteger)motionBlurDefaultSamples;

/// Whether to build the "On-Screen Controls" visibility row below the box
/// (and reserve height for it). Default NO. Override to YES in a plugin whose
/// effect draws on-screen controls the user should be able to hide. Read once
/// during init.
- (BOOL)showsOSCVisibilityRow;

/// Whether to build the "Presets" row below the box (and reserve height for
/// it). Default YES - every timing plugin can save/load animation presets.
/// Override to NO to opt out. Read once during init.
- (BOOL)showsPresetsRow;

@end

/// Parameter rows below the inspector box. Declared as a category so the
/// primary @implementation isn't expected to provide them (silences
/// -Wincomplete-implementation while keeping the methods public). Implemented
/// in KKTimelineInspectorView+ParameterRows.m.
@interface KKTimelineInspectorView (ParameterRows)
/// Push the persisted motion-blur enable state from the host's MB blob.
/// No-op when `showsMotionBlurRow` is NO.
- (void)setMotionBlurEnabled:(BOOL)enabled;
/// Push the persisted motion-blur Shutter angle (degrees) + Samples (count)
/// from the host's MB blob. No-op when `showsMotionBlurRow` is NO.
- (void)setMotionBlurShutterAngle:(double)shutterAngle
                          samples:(NSInteger)samples;
/// Push the persisted motion-blur technique from the host's MB blob. No-op
/// when `showsMotionBlurRow` is NO.
- (void)setMotionBlurTechnique:(KKMotionBlurTechnique)technique;
/// Push the persisted "On-Screen Controls" master visibility into the tick.
/// No-op when `showsOSCVisibilityRow` is NO.
- (void)setOSCVisible:(BOOL)visible;
/// Re-read `oscVisibilityElementStates` into the OPEN OSC settings popover (if
/// shown). A multi-owner host (Canvas) calls this when the selected owner
/// changes so the checklist reflects the newly-selected layer's set without
/// reopening. No-op if the popover isn't open.
- (void)refreshOpenOSCChecklist;
@end

NS_ASSUME_NONNULL_END
