/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKGapPopoverTypes.h>
#import <KeyframelessKit/KKTimingStage.h>

@protocol KKMiniViewerDelegate;
@class KKMiniViewerView;

NS_ASSUME_NONNULL_BEGIN

/// Mini-viewer render mode for keypose-value popovers. Off = single frame
/// at the active KP; Filmstrip = one rendered frame per KP, side-by-side in
/// the pannable canvas; Onion = all KP frames stacked on the active cell
/// with prev/next tinting. Persisted in the host UI-state blob.
typedef NS_ENUM(NSInteger, KKMiniViewerRenderMode) {
  KKMiniViewerRenderModeOff = 0,
  KKMiniViewerRenderModeFilmstrip = 1,
  KKMiniViewerRenderModeOnion = 2,
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

/// Optional all-owners (all-layers) timeline. When set, BOTH graphs (Basic +
/// Advanced) render and edit this instead of the single-owner `timeline`: every
/// animated lane across every layer shows, all editable, independent of which
/// layer is selected. Lanes must carry unique labels + layerKey/layerLabel for
/// the per-layer headers. The single-owner `timeline` still drives the Animated
/// dropdown + Constants (the layer list picks which owner those target). nil
/// (single-owner plugins) => the graphs use `timeline` as before.
@property(nonatomic, copy, nullable) KKTimeline *graphTimeline;
/// Owner (layer) keys in display order, so the graph lanes group in the layer
/// list's stack order. nil = no ordering.
@property(nonatomic, copy, nullable) NSArray<NSString *> *layerOrder;
/// Fired when an edit in a graph mutates the `graphTimeline` (all layers). The
/// host splits it back per owner. Only used when `graphTimeline` is set;
/// otherwise edits flow through `onTimelineMutated` as usual.
@property(nonatomic, copy, nullable) void (^onGraphTimelineMutated)
    (KKTimeline *updated);
/// Fired when a keypose popover opens scoped to one layer (multi-owner graph),
/// so the host can highlight that layer in its layer list.
@property(nonatomic, copy, nullable) void (^onKeyposeLayerActivated)
    (NSString *layerKey);
/// Re-point an OPEN keypose popover at a different layer's keypose at the same
/// time (driven by the host's layer-list selection). No-op if no keypose
/// popover is open.
- (void)retargetKeyposePopoverToLayerKey:(NSString *)layerKey;
/// Host's selected layer (multi-owner), so a freshly-opened keypose popover
/// scopes its params to that layer (nil => the first animated layer).
@property(nonatomic, copy, nullable) NSString *activeLayerKey;
/// Host hint (multi-owner): YES if SOME layer still has a constant param, so
/// the Constants button stays available even when the selected layer is fully
/// animated (open it, then pick the layer with constants in the panel).
@property(nonatomic) BOOL ownerConstantsAvailable;
/// Multi-owner: names of every animated layer, listed in the Animated dropdown
/// trigger with +N truncation ("layer 1, layer 2 +1"). nil/empty for
/// single-owner plugins (the trigger shows the property summary instead).
@property(nonatomic, copy, nullable) NSArray<NSString *> *dropdownLayerTitles;

/// Optional minimum content height (points) for the Animated (manage) popover,
/// so a sparse property list - and the layer panel beside it, which matches the
/// popover height - isn't uncomfortably short. 0 (default) keeps the popover
/// hugging its rows.
@property(nonatomic) CGFloat minimumManagePopoverHeight;

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

/// Current playhead position as a clip fraction (0–1), or < 0 when hidden /
/// unknown. Read from the Basic motion graph; used by "apply preset at
/// playhead".
@property(nonatomic, readonly) double playheadFraction;

/// The current timeline state. KVO-unsafe; read only from the main queue.
@property(nonatomic, readonly) KKTimeline *currentTimeline;

/// All reorderable property labels in their current display order (the
/// drag-to-reorder list's source). Backs the property-order popover.
- (NSArray<NSString *> *)orderedParamLabels;

/// Apply a user-defined property display order (persists via onTimelineMutated
/// and re-sorts every view + popover through the display chokepoint).
- (void)applyParamOrder:(NSArray<NSString *> *)labels;

/// YES when at least one available lane is not yet opted in.
@property(nonatomic, readonly) BOOL hasUnoptedLanes;

/// Fired on every timeline mutation triggered by user interaction.
@property(nonatomic, copy, nullable) void (^onTimelineMutated)
    (KKTimeline *updated);

/// Fired once around a continuous mini-viewer handle drag (start / end), so
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
/// (e.g. the Basic-compat banner) is up - stops the Advanced row hover
/// highlight and any click-through on either tab.
- (void)setOverlayBlockingInteractions:(BOOL)blocked;

/// Optional accessory buttons for the inspector toolbar that depend on the
/// active tab (e.g. Advanced's clear-selection). Owned by this view, slotted
/// in by the inspector next to the reset-zoom button. Recomputed on tab
/// change; `onAccessoryButtonsChanged` fires so the inspector can re-mount.
/// May be empty.
@property(nonatomic, readonly) NSArray<NSView *> *accessoryButtons;
@property(nonatomic, copy, nullable) void (^onAccessoryButtonsChanged)(void);

/// Mini-viewer render mode (see typedef above). The 3-way pill lives in the
/// popover's header bar (only visible while a boundary popover is open).
/// Setter is the host pushing the persisted value; `onRenderModeChanged`
/// relays user picks back.
@property(nonatomic) KKMiniViewerRenderMode renderMode;
@property(nonatomic, copy, nullable) void (^onRenderModeChanged)
    (KKMiniViewerRenderMode mode);

/// Mirror of `KKTimelineInspectorView.gapPopoverExtraRows`. Inspector view
/// sets this on its lanes views; the popover-construction code (Advanced +
/// Basic) calls it and appends the returned rows to the gap popover.
/// Signature documented on the inspector view's property.
@property(nonatomic, copy, nullable) NSArray<NSView *> * (^gapPopoverExtraRows)
    (KKGapPopoverPhase phase, NSString *_Nullable laneLabel,
     KKInterval *_Nonnull representative, KKGapIntervalReader _Nonnull read,
     KKGapIntervalMutator _Nonnull mutate);

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
/// fires. Defaults to nil - first available lane alphabetically is used.
@property(nonatomic, copy, nullable) NSString *managePopoverSpotlightLabel;

/// Guide hooks for the static-values (constants) popover, mirroring the
/// manage-popover ones. `willOpen` fires after the popover appears (short
/// delay for the entrance animation) with its content view and the live
/// mini-viewer (or nil if this plugin has no preview) so a guide can
/// spotlight the handle and observe zoom/pan/reset. `changed` reports every
/// constant edit (mini-viewer handle or slider); `dragEnded` fires once when
/// a continuous edit finishes; `closed` fires on dismiss.
@property(nonatomic, copy, nullable) void (^onStaticValuesPopoverWillOpen)
    (NSView *contentView, KKMiniViewerView *_Nullable canvas);
@property(nonatomic, copy, nullable) void (^onStaticValuesPopoverClosed)(void);
@property(nonatomic, copy, nullable) void (^onStaticValueChanged)
    (NSString *label, NSArray<NSNumber *> *values);
@property(nonatomic, copy, nullable) void (^onStaticValueDragEnded)
    (NSString *label, NSArray<NSNumber *> *values);

/// Guide-only observation hooks, fired ALONGSIDE the functional callbacks (so
/// they never clobber persistence / navigation). `renderModeChanged` fires when
/// the boundary popover's render-mode pill switches mode;
/// `filmstripCellActivated` fires when the user clicks an inactive filmstrip
/// cell. The mini-viewer guide wires these via the lanes binder.
@property(nonatomic, copy, nullable) void (^onGuideRenderModeChanged)
    (KKMiniViewerRenderMode mode);
@property(nonatomic, copy, nullable) void (^onGuideFilmstripCellActivated)
    (double fraction);
/// Fires when the Advanced toolbar's Dynamic toggle is clicked (`on` = its new
/// state). The Advanced-timing guide wires this via the lanes binder to advance
/// its Dynamic step.
@property(nonatomic, copy, nullable) void (^onGuideDynamicToggled)(BOOL on);
/// Fires when the user toggles a pill in the lane-filter bar (any direction).
/// The Advanced-timing guide wires this via the lanes binder to advance its
/// "try the filter" step. Programmatic show-all/restore does not fire it.
@property(nonatomic, copy, nullable) void (^onGuideLaneFilterToggled)(void);

/// Screen rect of the Dynamic accessory button (for the guide's spotlight), or
/// `NSZeroRect` if it isn't on screen yet. Only meaningful on the Advanced tab.
- (NSRect)guideDynamicButtonScreenRect;

/// Force the Dynamic display state, keeping the timeline and the toolbar glyph
/// in lockstep (the guide forces it off at start and restores it on completion,
/// so both must visibly track the value, not just the model).
- (void)guideSetDynamicDisplay:(BOOL)on;

/// Path to the mini-viewer source descriptor JSON the render side publishes.
/// Threaded into the static-values popover so spatial lanes (Crop) can show a
/// live preview. nil = no preview (label-only rows).
@property(nonatomic, copy, nullable) NSString *miniViewerDescriptorPath;

/// Reverse channel: when a boundary-value popover opens, the requested clip
/// fraction is written here so the render side can pull that frame for the
/// preview. Cleared on close. nil = no source-at-time (current frame only).
@property(nonatomic, copy, nullable) NSString *miniViewerRequestPath;

/// Fired right after the boundary request file is written (popover open).
/// FCP only re-runs -scheduleInputs: on a render, so with a static playhead
/// the freshly-written request is never picked up until the user scrubs. The
/// host wires this to a one-shot render nudge (jog a frame and back) so the
/// boundary preview resolves without manual scrubbing.
@property(nonatomic, copy, nullable) void (^onBoundaryPreviewNeedsRender)(void);

/// Cold-start clip aspect (w/h) for the mini viewer before a source resolves.
/// Defaults to 16:9.
@property(nonatomic) CGFloat miniViewerClipAspect;

/// Plugin delegate that runs its effect on the mini viewer source. Threaded
/// into the static-values popover's canvas.
@property(nonatomic, weak, nullable) id<KKMiniViewerDelegate>
    miniViewerDelegate;

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
/// Screen rect of `label`'s knob at its current value - the grab point, so a
/// guide's spotlight sits on the thumb rather than the track centre.
- (NSRect)guideConstantSliderKnobScreenRectForLabel:(NSString *)label;
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
