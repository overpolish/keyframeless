/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimingStage.h>

@protocol KKMiniCanvasDelegate;
@class KKMiniCanvasView;

NS_ASSUME_NONNULL_BEGIN

/// Mini-canvas render mode for keypose-value popovers. Off = single frame
/// at the active KP; Filmstrip = one rendered frame per KP, side-by-side in
/// the pannable canvas; Onion = all KP frames stacked on the active cell
/// with prev/next tinting. Persisted in the host UI-state blob.
typedef NS_ENUM(NSInteger, KKMiniCanvasRenderMode) {
  KKMiniCanvasRenderModeOff = 0,
  KKMiniCanvasRenderModeFilmstrip = 1,
  KKMiniCanvasRenderModeOnion = 2,
};

/// Plugin-agnostic timeline lane editor. Plugin provides available lane
/// templates (KKLane with valueType/ranges, no keyposes); view handles opt-in
/// pills, hold value editors, and the static-values popover. Used as shared
/// content for both Basic and Advanced inspector tabs.
@interface KKTimelineLanesView : NSView

- (instancetype)initWithAvailableLanes:(NSArray<KKLane *> *)availableLanes
                              timeline:(KKTimeline *)timeline
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Push an updated timeline from outside (e.g. parameterChanged:).
/// Does not fire onTimelineMutated.
- (void)applyTimeline:(KKTimeline *)timeline;

/// Live clip duration (seconds) for the Basic motion-graph ruler, pushed
/// from the render tick (a clip trim never fires parameterChanged:).
- (void)setClipDurationSeconds:(double)seconds;

/// Live frame duration (seconds) for the Basic motion-graph scrubber clamp.
/// The playhead can't reach the clip end (it stops one frame before), so the
/// scrubber's upper bound is `(clipDur - frameDur) / clipDur`. Forwarded to
/// the Basic motion graph.
- (void)setFrameDurationSeconds:(double)seconds;

/// Live playhead position (clip fraction 0–1; < 0 hides), pushed from the
/// render tick. Forwarded to the Basic motion graph.
- (void)setPlayheadFraction:(double)frac;

/// The current timeline state. KVO-unsafe; read only from the main queue.
@property(nonatomic, readonly) KKTimeline *currentTimeline;

/// YES when at least one available lane is not yet opted in.
@property(nonatomic, readonly) BOOL hasUnoptedLanes;

/// Fired on every timeline mutation triggered by user interaction.
@property(nonatomic, copy, nullable) void (^onTimelineMutated)
    (KKTimeline *updated);

/// Fired once around a continuous mini-canvas handle drag (start / end), so
/// the host can wrap the burst of `onTimelineMutated` writes in a single
/// undo group.
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);

/// Fired while the user drags the Basic playhead handle to scrub; the host
/// moves the host playhead to that clip fraction.
@property(nonatomic, copy, nullable) void (^onScrub)(double frac);

/// Fired when the Basic graph zoom/pan changes (YES = zoomed in, not fit).
@property(nonatomic, copy, nullable) void (^onZoomChanged)(BOOL zoomed);

/// Reset the Basic graph's pinch-zoom/pan back to fit.
- (void)resetZoom;

/// Swap the visible motion graph between Basic (0) and Advanced (1). Defaults
/// to Basic. Only changes which child is visible; the timeline blob and lane
/// opt-in state are shared.
- (void)setActiveTab:(NSInteger)tab;

/// Advanced-tab selection mirror plumbing. The inspector wires its detached
/// copy to forward selection both ways so both views stay in sync. Selection
/// state is per-view (not in the timeline blob), so the bridge lives here.
/// `applyAdvancedSelectionPillKeys:gapKeys:` is a no-op when sets match,
/// breaking the ping-pong loop. Fires `onAdvancedSelectionChanged` only on
/// genuine local user-driven changes (clicks, marquee, delete, clear, esc).
@property(nonatomic, copy, nullable) void (^onAdvancedSelectionChanged)
    (NSSet<NSString *> *pillKeys, NSSet<NSString *> *gapKeys);
- (void)applyAdvancedSelectionPillKeys:(NSSet<NSString *> *)pillKeys
                               gapKeys:(NSSet<NSString *> *)gapKeys;

/// Block all user interaction on the timeline graphs while an overlay
/// (e.g. the Basic-compat banner) is up — stops the Advanced row hover
/// highlight and any click-through on either tab.
- (void)setOverlayBlockingInteractions:(BOOL)blocked;

/// Optional accessory buttons for the inspector toolbar that depend on the
/// active tab (e.g. Advanced's clear-selection). Owned by this view, slotted
/// in by the inspector next to the reset-zoom button. Recomputed on tab
/// change; `onAccessoryButtonsChanged` fires so the inspector can re-mount.
/// May be empty.
@property(nonatomic, readonly) NSArray<NSView *> *accessoryButtons;
@property(nonatomic, copy, nullable) void (^onAccessoryButtonsChanged)(void);

/// Mini-canvas render mode (see typedef above). The 3-way pill lives in the
/// popover's header bar (only visible while a boundary popover is open).
/// Setter is the host pushing the persisted value; `onRenderModeChanged`
/// relays user picks back.
@property(nonatomic) KKMiniCanvasRenderMode renderMode;
@property(nonatomic, copy, nullable) void (^onRenderModeChanged)
    (KKMiniCanvasRenderMode mode);

/// The footer row view that contains the "Add properties…" dropdown trigger.
/// Useful as a joyride spotlight target.
@property(nonatomic, readonly) NSView *footerView;

/// Returns the lane row view for the given label, or nil if not opted in.
- (nullable NSView *)laneRowViewForLabel:(NSString *)label;

/// When set, fired (with a short delay for popover-entrance animation) after
/// the manage popover appears. Receives the row view for
/// managePopoverSpotlightLabel (or the first available lane if nil).
@property(nonatomic, copy, nullable) void (^onManagePopoverWillOpen)
    (NSView *spotlightTargetRow);

/// Fired when the manage popover closes for any reason.
@property(nonatomic, copy, nullable) void (^onManagePopoverClosed)(void);

/// Fired when the user opts in a lane via the manage popover toggle.
/// Not fired by external applyTimeline: calls.
@property(nonatomic, copy, nullable) void (^onLaneOptedIn)(NSString *label);

/// Label to spotlight inside the manage popover when onManagePopoverWillOpen
/// fires. Defaults to nil — first available lane alphabetically is used.
@property(nonatomic, copy, nullable) NSString *managePopoverSpotlightLabel;

/// Guide hooks for the static-values (constants) popover, mirroring the
/// manage-popover ones. `willOpen` fires after the popover appears (short
/// delay for the entrance animation) with its content view and the live
/// mini-canvas (or nil if this plugin has no preview) so a guide can
/// spotlight the handle and observe zoom/pan/reset. `changed` reports every
/// constant edit (mini-canvas handle or slider); `dragEnded` fires once when
/// a continuous edit finishes; `closed` fires on dismiss.
@property(nonatomic, copy, nullable) void (^onStaticValuesPopoverWillOpen)
    (NSView *contentView, KKMiniCanvasView *_Nullable canvas);
@property(nonatomic, copy, nullable) void (^onStaticValuesPopoverClosed)(void);
@property(nonatomic, copy, nullable) void (^onStaticValueChanged)
    (NSString *label, NSArray<NSNumber *> *values);
@property(nonatomic, copy, nullable) void (^onStaticValueDragEnded)
    (NSString *label, NSArray<NSNumber *> *values);

/// Path to the mini-canvas source descriptor JSON the render side publishes.
/// Threaded into the static-values popover so spatial lanes (Crop) can show a
/// live preview. nil = no preview (label-only rows).
@property(nonatomic, copy, nullable) NSString *miniCanvasDescriptorPath;

/// Reverse channel: when a boundary-value popover opens, the requested clip
/// fraction is written here so the render side can pull that frame for the
/// preview. Cleared on close. nil = no source-at-time (current frame only).
@property(nonatomic, copy, nullable) NSString *miniCanvasRequestPath;

/// Fired right after the boundary request file is written (popover open).
/// FCP only re-runs -scheduleInputs: on a render, so with a static playhead
/// the freshly-written request is never picked up until the user scrubs. The
/// host wires this to a one-shot render nudge (jog a frame and back) so the
/// boundary preview resolves without manual scrubbing.
@property(nonatomic, copy, nullable) void (^onBoundaryPreviewNeedsRender)(void);

/// Cold-start clip aspect (w/h) for the mini canvas before a source resolves.
/// Defaults to 16:9.
@property(nonatomic) CGFloat miniCanvasClipAspect;

/// Plugin delegate that runs its effect on the mini canvas source. Threaded
/// into the static-values popover's canvas.
@property(nonatomic, weak, nullable) id<KKMiniCanvasDelegate>
    miniCanvasDelegate;

@end

/// Popover presentation (manage + static-values). Split out of
/// KKTimelineLanesView.m for file size; implemented in
/// KKTimelineLanesView+Popovers.m.
@interface KKTimelineLanesView (Popovers)

/// Open the static-values popover anchored to the given view.
- (void)showStaticValuesPopoverFromView:(NSView *)anchor;

/// The value-editor row (slider/fields) for `label` in the currently open
/// static-values popover, or nil if it isn't open / no such lane. Lets a
/// guide spotlight a specific constant's control.
- (nullable NSView *)staticValueRowViewForLabel:(NSString *)label;

/// Guide-driven constant edit on the open static-values popover, through the
/// same coalesced channel a real slider/handle drag uses (begin → per-tick
/// apply → end). Lets a guide drive the slider step the way the OSC guide
/// drives the in-viewer handle. No-ops if the popover isn't open.
- (void)beginGuideConstantDrag;
- (void)applyGuideConstantValues:(NSArray<NSNumber *> *)values
                        forLabel:(NSString *)label;
- (void)endGuideConstantDrag;

/// Screen geometry of `label`'s slider in the open static-values popover, so
/// a guide's target marker and drag map line up with the rendered knob.
/// NSZeroRect / 0 when the popover isn't open or `label` has no slider.
- (NSRect)guideConstantSliderTrackScreenRectForLabel:(NSString *)label;
- (CGFloat)guideConstantSliderScreenXForValue:(double)value
                                     forLabel:(NSString *)label;
- (double)guideConstantSliderValueForScreenX:(CGFloat)screenX
                                    forLabel:(NSString *)label;

/// Guide hooks for a numeric field of `label`'s row in the open static-values
/// popover (Crop component 0..3 = W,H,X,Y): the field's screen rect, a live
/// keystroke handler (parsed display value), and a programmatic Return. No-op
/// if the popover isn't open.
- (NSRect)guideConstantFieldScreenRectForLabel:(NSString *)label
                                     component:(NSInteger)component;
- (void)setGuideConstantFieldEditHandlerForLabel:(NSString *)label
                                         handler:
                                             (nullable void (^)(
                                                 NSInteger component,
                                                 double displayValue))handler;
- (void)commitGuideConstantFieldForLabel:(NSString *)label
                               component:(NSInteger)component;

/// Close the manage popover if it is currently open.
- (void)closeManagePopover;

@end

NS_ASSUME_NONNULL_END
