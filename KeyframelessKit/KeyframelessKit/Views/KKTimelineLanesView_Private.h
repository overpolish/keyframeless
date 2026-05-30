/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKLaneRowView.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingStage.h>

@class KKSegmentEditView;
@protocol KKMiniCanvasDelegate;

static const CGFloat kRowHeight = 28.0;
static const CGFloat kFooterH = 32.0;
static const CGFloat kCheckSize = 12.0;
static const CGFloat kCheckRadius = 3.0;
static const CGFloat kSearchH = 28.0;
static const CGFloat kPopoverW = 180.0;
// Wider variant for the static-values popover when it hosts the mini canvas,
// so the preview is legible before in-canvas zoom exists.
static const CGFloat kCanvasPopoverW = 420.0;
static const NSInteger kMaxSummaryLabels = 2;

NS_ASSUME_NONNULL_BEGIN

@interface _KKLVPopoverContentView : NSView
@end

@interface _KKSearchFieldCell : NSSearchFieldCell
@end

@interface _KKSearchField : NSSearchField
@end

@interface _KKManageRow : NSView
@property(nonatomic, copy) NSString *rowLabel;
@property(nonatomic) BOOL checked;
@property(nonatomic, copy, nullable) void (^onToggle)(void);
@end

@interface _KKManagePopoverView : NSView <NSSearchFieldDelegate>
- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                checkedLabels:(NSSet<NSString *> *)checked
                     onToggle:(void (^)(NSString *label))onToggle;
- (void)updateCheckedLabels:(NSSet<NSString *> *)checked;
- (nullable NSView *)rowViewForLabel:(NSString *)label;
+ (CGFloat)heightForLaneCount:(NSInteger)count;
@end

@interface _KKStaticValueRow : KKLaneRowView <NSTextFieldDelegate>
@property(nonatomic, copy) NSString *laneLabel;
/// New constant values for the lane (Float: [v]; Crop: [w,h,x,y]).
@property(nonatomic, copy, nullable) void (^onValue)
    (NSArray<NSNumber *> *values);
/// Bracket a continuous slider drag so the host coalesces it to one undo /
/// one persist (mirrors the mini canvas).
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
/// Per-component display scale (display = stored × scale). Used so crop
/// fields show pixels while the model stays normalized. nil/≤0 == raw.
@property(nonatomic, copy, nullable) double (^componentScale)(NSInteger idx);
/// Plugin template default for this lane. When set, a small reset button
/// right of the label restores the value to it (commits like a field edit).
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *defaultValues;
/// When `showsRemove` is YES the row carries a leading "−" gutter button that
/// fires this; the host removes the keypose at this time (Advanced only).
@property(nonatomic, copy, nullable) void (^onRemove)(void);
- (instancetype)initWithLane:(KKLane *)lane showsRemove:(BOOL)showsRemove;
/// The KKSliderView (Float rows), for a guide that drives the slider.
- (nullable NSView *)guideSliderView;
/// The number field for component `i` (Float: 0; Crop: 0..3 = W,H,X,Y), for
/// a guide to spotlight / drive it.
- (nullable NSView *)guideFieldViewForComponent:(NSInteger)i;
/// Fired on every live keystroke in any field with the parsed *display*
/// value (pixels for crop). Lets a guide watch the user type toward a value.
@property(nonatomic, copy, nullable) void (^onGuideFieldEdit)
    (NSInteger component, double displayValue);
/// Commit component `i`'s field as if the user pressed Return.
- (void)guideCommitFieldForComponent:(NSInteger)i;
/// Set the displayed values (skips a field currently being edited).
- (void)applyValues:(NSArray<NSNumber *> *)values;
- (void)applyLane:(KKLane *)lane;
/// Re-render fields/slider from the stored values (e.g. after the display
/// scale changes when the feed resolves its media size).
- (void)refreshDisplay;
+ (CGFloat)heightForLane:(KKLane *)lane;
@end

@interface _KKStaticValuesPopoverView : NSView
@property(nonatomic, weak, nullable) NSPopover *popover;
/// The inner mini-canvas. Exposed so callers (e.g. the boundary popover
/// path that wires onion-skin filmstrip clicks) can attach extra closures
/// without threading another init parameter.
@property(nonatomic, readonly, nullable) KKMiniCanvasView *miniCanvas;
- (instancetype)
     initWithLanes:(NSArray<KKLane *> *)lanes
    descriptorPath:(nullable NSString *)descriptorPath
        clipAspect:(CGFloat)clipAspect
       headerTitle:(nullable NSString *)headerTitle
      headerDetail:(nullable NSString *)headerDetail
        headerIcon:(nullable NSImage *)headerIcon
    canvasDelegate:(nullable id<KKMiniCanvasDelegate>)canvasDelegate
        renderMode:(KKMiniCanvasRenderMode)renderMode
     onModeChanged:(nullable void (^)(KKMiniCanvasRenderMode mode))onModeChanged
        onNavigate:(nullable void (^)(NSInteger direction))onNavigate
     onHandleValue:(nullable void (^)(NSString *label,
                                      NSArray<NSNumber *> *values))onHandleValue
       onDragBegin:(nullable void (^)(void))onDragBegin
         onDragEnd:(nullable void (^)(void))onDragEnd;

/// Update the header title in place (e.g. the keypose time as you navigate
/// between keyposes). No-op if the popover has no header.
- (void)setHeaderTitle:(NSString *)title;
/// Update the smaller subscript detail (e.g. the keypose time) in place.
- (void)setHeaderDetail:(NSString *)detail;
/// Show/hide a "link" chain glyph in the header to flag a linked keypose.
- (void)setHeaderLinked:(BOOL)linked;

/// Enable/disable the popover header's prev/next KP buttons (only meaningful
/// when `onNavigate` was passed at init). The lanes view calls this on open
/// and on every in-place rebind so the chevrons reflect the active KP's
/// position in the time-sorted KP list.
- (void)setNavPrevEnabled:(BOOL)prev nextEnabled:(BOOL)next;
- (void)updateUnoptedLanes:(NSArray<KKLane *> *)lanes;
/// Set each row's reset-to-default value (called right after construction;
/// rows are built during init so this can't be an init arg without churn).
- (void)applyDefaultsProvider:
    (NSArray<NSNumber *> * (^)(NSString *label))provider;
/// In-place value swap - push the latest values from `lanes` into the
/// matching `_KKStaticValueRow`s without tearing down the popover. Used by
/// the onion-skin filmstrip (Advanced) when the user clicks an inactive
/// cell so the popover stays open but rebinds to a different KP. Pairs
/// with the graph keeping its onValue/onAnimate closures reading a
/// mutable `_currentPopoverFrac` ivar so writes target the new KP.
- (void)rebindLanes:(NSArray<KKLane *> *)lanes;
/// Swap the listed labels' rows for non-editable "addable" rows (label +
/// `message` + an Animate button → onAnimate(label)), in place so property
/// order is preserved. `message` is context-specific: Basic uses phase
/// wording, Advanced "No keypose here". Called before the popover is shown.
- (void)applyExcludedLabels:(NSArray<NSString *> *)labels
                    message:(NSString *)message
                  onAnimate:(void (^)(NSString *label))onAnimate;
/// Rebuild the row stack in place (mini-canvas/header untouched) from a fresh
/// lane set + excluded labels, reusing the stored defaults provider / excluded
/// message / onAnimate. Used by the in-place update path so add/remove/navigate
/// re-render rows without reopening (which blinks the MTKView).
- (void)rebuildRowsWithLanes:(NSArray<KKLane *> *)lanes
              excludedLabels:(NSArray<NSString *> *)excluded;
/// Set (Advanced only) to give editable rows a leading "−" remove button that
/// fires `handler(label)`. Must be set before rows are (re)built; the present
/// path rebuilds once after setting it. nil = no remove gutter.
- (void)setRowRemoveHandler:(void (^)(NSString *label))handler;
/// The value-editor row (slider/fields) for `label`, or nil. Lets a guide
/// spotlight a specific constant's control.
- (nullable NSView *)rowViewForLabel:(NSString *)label;
/// Guide-driven constant edit through the *same* coalesced channel a real
/// slider/handle drag uses: begin → per-tick apply (live preview, knob +
/// mini-canvas track, persist stashed) → end (one persist + undo entry).
- (void)guideBeginConstantDrag;
- (void)guideApplyConstantValues:(NSArray<NSNumber *> *)values
                        forLabel:(NSString *)label;
- (void)guideEndConstantDrag;
/// Screen geometry of `label`'s slider (NSZeroRect / 0 if none), for a guide
/// to place its target marker and map the drag onto the real track.
- (NSRect)guideSliderTrackScreenRectForLabel:(NSString *)label;
/// Screen rect of `label`'s knob at its current value - the grab point a guide
/// spotlights so the cutout sits on the thumb, not the track centre.
- (NSRect)guideSliderKnobScreenRectForLabel:(NSString *)label;
- (CGFloat)guideSliderScreenXForValue:(double)value forLabel:(NSString *)label;
- (double)guideSliderValueForScreenX:(CGFloat)screenX
                            forLabel:(NSString *)label;
/// Guide hooks for a numeric field of `label`'s row (Crop component 0..3 =
/// W,H,X,Y): the field's screen rect (spotlight), a live-keystroke handler,
/// and a programmatic Return.
- (NSRect)guideFieldScreenRectForLabel:(NSString *)label
                             component:(NSInteger)component;
- (void)setGuideFieldEditHandlerForLabel:(NSString *)label
                                 handler:(nullable void (^)(
                                             NSInteger component,
                                             double displayValue))handler;
- (void)guideCommitFieldForLabel:(NSString *)label
                       component:(NSInteger)component;
+ (CGFloat)heightForLanes:(NSArray<KKLane *> *)lanes
           descriptorPath:(nullable NSString *)descriptorPath
               clipAspect:(CGFloat)clipAspect
            reserveHeader:(BOOL)reserveHeader;
@end

@interface _KKDropdownTrigger : NSView
@property(nonatomic, copy, nullable) NSArray<NSString *> *selectedLabels;
@property(nonatomic, copy, nullable) void (^onTapped)(void);
@end

NS_ASSUME_NONNULL_END
