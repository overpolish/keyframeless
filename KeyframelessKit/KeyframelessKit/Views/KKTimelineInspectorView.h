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
@protocol KKMiniCanvasDelegate;

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
/// `KKMiniCanvasRenderer` subclass + a few config properties; everything
/// else (layout, button wiring, live-push setters, detach-copy plumbing) is
/// shared.
///
/// Subclasses (e.g. a plugin's own tour-aware inspector) override
/// `applyTimeline:` and `beginDetachedCopy` calling `super` to add their
/// own per-instance work; the standard plumbing stays.
@interface KKTimelineInspectorView : NSView

#pragma mark - Configuration (plugin-specific, set after init)

/// Cross-process tmp-file path the `KKMiniCanvasFeed` publishes to.
@property(nonatomic, copy, nullable) NSString *miniCanvasDescriptorPath;
/// Reverse channel: the boundary-popover writes the requested clip
/// fraction here; the render side reads it in `-scheduleInputs:`.
@property(nonatomic, copy, nullable) NSString *miniCanvasRequestPath;
/// Plugin's mini-canvas delegate (typically a `KKMiniCanvasRenderer`
/// subclass) — supplies the effect render + point-handle vocabulary.
@property(nonatomic, strong, nullable) id<KKMiniCanvasDelegate>
    miniCanvasDelegate;
/// Lane label the "manage properties" popover highlights for the first-run
/// spotlight (e.g. @"Radius"). nil = no spotlight.
@property(nonatomic, copy, nullable) NSString *managePopoverSpotlightLabel;
/// Title drawn on the Constants button. Default @"Constants".
@property(nonatomic, copy) NSString *constantsButtonTitle;

#pragma mark - Callbacks (host wires playback / loop param / FxRemoteWindow)

@property(nonatomic, copy, nullable) void (^onLoopToggled)(BOOL enabled);
@property(nonatomic, copy, nullable) void (^onTabChanged)(NSInteger tab);
/// Any motion-blur edit (enable toggle, a Shutter/Samples slider/field, or the
/// When dropdown in the settings popover). `shutterAngle` is degrees (0–360);
/// `samples` is the sample count (2–128); `mode` is when blur fires (see
/// `KKMotionBlurMode`). The host writes the full
/// `{enabled,shutterAngle,samples,mode}` blob. Only fired when
/// `showsMotionBlurRow` is YES. Wrap continuous slider drags with
/// `onDragBegin`/`onDragEnd` for undo coalescing (same chain the mini-canvas
/// handles use).
@property(nonatomic, copy, nullable) void (^onMotionBlurChanged)
    (BOOL enabled, double shutterAngle, NSInteger samples,
     KKMotionBlurMode mode);
@property(nonatomic, copy, nullable) void (^onTimelineMutated)
    (KKTimeline *updated);
/// Start / end of a continuous mini-canvas handle drag — host wraps the
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

#pragma mark - Read-only state

@property(nonatomic, readonly) KKTimelineLanesView *basicLanesView;
@property(nonatomic, readonly) KKConstantsButton *constantsButton;
/// YES for the secondary copy living in a detached remote window — used to
/// suppress per-instance UI (joyride autostart, the detach button, etc.).
@property(nonatomic, readonly) BOOL isDetachedCopy;
/// YES while a detached copy exists (window open or opening).
@property(nonatomic, readonly) BOOL hasDetachedWindow;

#pragma mark - Lifecycle / live push

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                       loopEnabled:(BOOL)loopEnabled
                         activeTab:(NSInteger)activeTab
                    availableLanes:(NSArray<KKLane *> *)availableLanes
                          timeline:(KKTimeline *)timeline
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

- (void)applyTimeline:(KKTimeline *)timeline;
- (void)setLoopEnabled:(BOOL)enabled;
/// Push the persisted motion-blur enable state from the host's MB blob.
/// No-op when `showsMotionBlurRow` is NO.
- (void)setMotionBlurEnabled:(BOOL)enabled;
/// Push the persisted motion-blur Shutter angle (degrees) + Samples (count)
/// from the host's MB blob. No-op when `showsMotionBlurRow` is NO.
- (void)setMotionBlurShutterAngle:(double)shutterAngle
                          samples:(NSInteger)samples;
/// Push the persisted motion-blur fire mode from the host's MB blob. No-op
/// when `showsMotionBlurRow` is NO.
- (void)setMotionBlurMode:(KKMotionBlurMode)mode;
- (void)setActiveTab:(NSInteger)tab;
/// Push the persisted mini-canvas render mode from the host's UI-state
/// blob. The 3-way pill lives in the keypose-value popover header (only
/// while open); this just mirrors the persisted enum. Defaults to Off.
- (void)setRenderMode:(KKMiniCanvasRenderMode)mode;
@property(nonatomic, readonly) KKMiniCanvasRenderMode renderMode;
/// Fired when the user picks a different render mode. Host writes back to
/// the UI-state blob via this callback.
@property(nonatomic, copy, nullable) void (^onRenderModeChanged)
    (KKMiniCanvasRenderMode mode);
/// The currently selected tab. Lets guides snapshot the state at entry
/// and restore it on completion.
@property(nonatomic, readonly) NSInteger activeTab;
/// Live clip duration (seconds) for the Basic ruler, pushed from the
/// render tick (clip trims never fire `parameterChanged:`).
- (void)setClipDurationSeconds:(double)seconds;
/// Live frame duration (seconds) — bounds the scrubber to the last frame.
- (void)setFrameDurationSeconds:(double)seconds;
/// Live playhead position (clip fraction 0–1; < 0 hides) for the scrubber.
- (void)setPlayheadFraction:(double)frac;
/// Playback state — drives the play/pause button color.
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

@end

NS_ASSUME_NONNULL_END
