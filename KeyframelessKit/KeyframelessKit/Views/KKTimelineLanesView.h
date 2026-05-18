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
