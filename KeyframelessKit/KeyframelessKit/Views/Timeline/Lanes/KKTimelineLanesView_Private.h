/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKLaneRowView.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingStage.h>

#import "KKLaneChecklistView.h" // _KKLaneChecklistView base

@class KKSegmentEditView;
@protocol KKMiniViewerDelegate;

static const CGFloat kRowHeight = 28.0;
static const CGFloat kFooterH = 32.0;
static const CGFloat kCheckSize = 12.0;
static const CGFloat kCheckRadius = 3.0;
static const CGFloat kSearchH = 28.0;
static const CGFloat kPopoverW = 180.0;
// Static-values popover width when it hosts the mini-viewer, so the preview is
// legible before in-canvas zoom exists. Three sizes (sm/md/lg) the user toggles
// via a global preference: a wider popover scales the mini-viewer up
// aspect-correct (height = width/aspect) while the parameter rows keep their
// heights and just fill the extra width. `kCanvasPopoverW` is sm (the default,
// unchanged original width).
static const CGFloat kCanvasPopoverW = 540.0;       // sm (default)
static const CGFloat kCanvasPopoverWMedium = 760.0; // md
static const CGFloat kCanvasPopoverWLarge = 980.0;  // lg
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
/// Indent depth (0 = top level). Shifts the checkbox + label right so a child
/// row (e.g. a Rotation axis) reads as nested under its parent. Default 0.
@property(nonatomic) NSInteger indentLevel;
/// When non-nil, drawn verbatim as the row label instead of localizing
/// `rowLabel` (for callers whose labels are already localized, e.g. the lane
/// filter's compound display strings). Default nil.
@property(nonatomic, copy, nullable) NSString *displayOverride;
/// Draw the checkbox + label in the warning tint (the lane filter marks a
/// soloed row this way). Default NO.
@property(nonatomic) BOOL warning;
/// The row's category key, so the checklist can page it under the right
/// category pill even when its label is not unique (component sub-rows like
/// "X"/"Y" share labels across lanes). nil = uncategorised (shows on all
/// pages). Default nil.
@property(nonatomic, copy, nullable) NSString *categoryKey;
@property(nonatomic, copy, nullable) void (^onToggle)(void);
/// Fired on an option-click instead of `onToggle` (the lane filter solos the
/// row). When nil, an option-click falls through to `onToggle`.
@property(nonatomic, copy, nullable) void (^onOptionToggle)(void);
@end

// The Animated "manage" dropdown's checkable lane list. Shared chrome (search,
// category pill, filtering, sizing, `popover`, `rowViewForLabel:`) lives in the
// base; this only adds opt-in checkbox state.
@interface _KKManagePopoverView : _KKLaneChecklistView
- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                checkedLabels:(NSSet<NSString *> *)checked
                minimumHeight:(CGFloat)minimumHeight
                     onToggle:(void (^)(NSString *label))onToggle;
- (void)updateCheckedLabels:(NSSet<NSString *> *)checked;
@end

// Shared static-values UI helpers: defined in the value-row .m, used by the
// popover .m too (the two were split out of one +Helpers file).
FOUNDATION_EXPORT const CGFloat kFloatRowH;
FOUNDATION_EXPORT NSTextField *_KKMakeCaption(NSString *s);
FOUNDATION_EXPORT NSButton *_KKGutterGlyphButton(NSString *symbol, id target,
                                                 SEL action, NSColor *tint);

@interface _KKStaticValueRow : KKLaneRowView <NSTextFieldDelegate>
@property(nonatomic, copy) NSString *laneLabel;
/// New constant values for the lane (Float: [v]; Crop: [w,h,x,y]).
@property(nonatomic, copy, nullable) void (^onValue)
    (NSArray<NSNumber *> *values);
/// Bracket a continuous slider drag so the host coalesces it to one undo /
/// one persist (mirrors the mini viewer).
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
/// When `showsAddToAnimated` is YES the row carries a leading curve-glyph
/// gutter button (constants popover only) that fires this; the host flips
/// the lane to animatable, mirroring the lane-manager dropdown. The "back
/// to constant" direction has no shortcut by design - making a property
/// constant deletes its keyposes, so it stays behind the explicit dropdown.
@property(nonatomic, copy, nullable) void (^onAddToAnimated)(void);
/// When `showsSmooth` is YES the row carries a curve-glyph toggle just left of
/// the value fields that flips this keypose between corner (straight spatial
/// path) and smooth (cubic bezier). Fires with the new state; the host writes
/// `spatialSmooth` on the keypose at this fraction. Only built for
/// `spatialCurvable` lanes in the keypose popover.
@property(nonatomic, copy, nullable) void (^onSmoothToggled)(BOOL on);
/// When the lane is `aspectLinkable` the row carries a link/unlink glyph (same
/// slot as the smooth toggle) that flips the global aspect lock. Fires with the
/// new state; the host persists `aspectLinked` on the lane.
@property(nonatomic, copy, nullable) void (^onLinkToggled)(BOOL on);
/// A KKLaneValueTypeColor row carries a colour swatch that opens the shared
/// colour panel. Fires YES while that panel is open and NO when it closes, so
/// the hosting popover can suspend its transient auto-dismiss during the edit.
@property(nonatomic, copy, nullable) void (^onColorEditing)(BOOL editing);
/// A composite-gradient row's radial/linear type pill fires this with the new
/// type index. When set, the host applies it to ALL keyposes of the lane (type
/// is a single, non-animated property); when nil, the row commits it to the
/// open keypose like any other value (constants editor). Lets type stay
/// editable once the gradient is animated.
@property(nonatomic, copy, nullable) void (^onGradientTypeChanged)
    (NSInteger type);
/// A `paletteLockable` colour row carries a small lock toggle beside its
/// swatch. Fires with the new state; the host tracks which colour labels are
/// locked so a palette reroll can skip them. Transient UI state (not
/// persisted).
@property(nonatomic, copy, nullable) void (^onPaletteLockToggled)(BOOL locked);
/// A `paletteGeneratorBar` row fires this with the chosen mode index
/// (`KKPaletteMode`) when a mode button is tapped. The host regenerates the
/// visible palette colours, keeping the locked ones.
@property(nonatomic, copy, nullable) void (^onPaletteGenerate)(NSInteger mode);
/// A `paletteGeneratorBar` row's "vary" button fires this; the host nudges the
/// current colours slightly (see `KKPaletteGenerator refinedPaletteFrom:`).
@property(nonatomic, copy, nullable) void (^onPaletteRefine)(void);
- (instancetype)initWithLane:(KKLane *)lane
                 showsRemove:(BOOL)showsRemove
          showsAddToAnimated:(BOOL)showsAddToAnimated
                 showsSmooth:(BOOL)showsSmooth
              reservesGutter:(BOOL)reservesGutter
            labelColumnWidth:(CGFloat)labelColumnWidth
                contentWidth:(CGFloat)contentWidth;
/// Width to pin every row's label column to, so the value controls line up
/// regardless of label length (the widest localized param name). 0 = natural.
+ (CGFloat)labelColumnWidthForLanes:(NSArray<KKLane *> *)lanes;
/// Width-aware row height: a wrapping choice-pill lane (a `wrapsChoicePills`
/// marker type) grows per wrapped line for the popover content width; every
/// other lane is width-independent. The popover height calc and the row layout
/// both use this so they agree.
+ (CGFloat)heightForLane:(KKLane *)lane
            contentWidth:(CGFloat)contentWidth
        labelColumnWidth:(CGFloat)labelColumnWidth;
/// Re-derive a wrapping pill row's block width + height for a new popover
/// content width (the size pill resizes without rebuilding rows). No-op
/// otherwise.
- (void)updateContentWidth:(CGFloat)contentWidth;
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
/// Screen rect of the choice-pill segment at `index` (a radio enum row, e.g. an
/// end-marker type), or NSZeroRect if this row has no choice pill. Lets a guide
/// spotlight a specific choice.
- (NSRect)guideChoicePillScreenRectForIndex:(NSInteger)index;
/// Screen rect of this row's leading "add to animated" gutter button, or
/// NSZeroRect if the row doesn't show one. Spotlight target.
- (NSRect)guideAddToAnimatedButtonScreenRect;
/// Set the displayed values (skips a field currently being edited).
- (void)applyValues:(NSArray<NSNumber *> *)values;
/// Refresh the aspect-link glyph state without rebuilding.
- (void)applyLink:(BOOL)on;
/// Refresh the smooth-toggle glyph state (e.g. after cmd-Z) without rebuilding.
- (void)applySmooth:(BOOL)on;
/// Refresh the palette lock toggle (padlock open/closed + tint) without firing
/// the callback. Used to restore the row's lock state after a rebuild.
- (void)applyPaletteLock:(BOOL)locked;
- (void)applyLane:(KKLane *)lane;
/// Re-render fields/slider from the stored values (e.g. after the display
/// scale changes when the feed resolves its media size).
- (void)refreshDisplay;
+ (CGFloat)heightForLane:(KKLane *)lane;
@end

@interface _KKStaticValuesPopoverView : NSView
@property(nonatomic, weak, nullable) NSPopover *popover;
/// The inner mini-viewer. Exposed so callers (e.g. the boundary popover
/// path that wires onion-skin filmstrip clicks) can attach extra closures
/// without threading another init parameter.
@property(nonatomic, readonly, nullable) KKMiniViewerView *miniViewer;
/// Size the view's frame to its natural content height clamped to `view`'s
/// screen, before the popover is shown. On a small / low-resolution display the
/// overflow goes to the internal rows scroller (the rows below the sticky
/// mini-viewer + category pill); on a tall screen this is the natural height
/// (no clamp, no scroll). Later re-fits self-clamp the same way.
- (void)clampContentToScreenOfView:(NSView *)view;
- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
               descriptorPath:(nullable NSString *)descriptorPath
                   clipAspect:(CGFloat)clipAspect
                  headerTitle:(nullable NSString *)headerTitle
                 headerDetail:(nullable NSString *)headerDetail
                   headerIcon:(nullable NSImage *)headerIcon
               canvasDelegate:(nullable id<KKMiniViewerDelegate>)canvasDelegate
                   renderMode:(KKMiniViewerRenderMode)renderMode
                onModeChanged:(nullable void (^)(KKMiniViewerRenderMode mode))
                                  onModeChanged
                   onNavigate:(nullable void (^)(NSInteger direction))onNavigate
                onHandleValue:(nullable void (^)(NSString *label,
                                                 NSArray<NSNumber *> *values))
                                  onHandleValue
                  onDragBegin:(nullable void (^)(void))onDragBegin
                    onDragEnd:(nullable void (^)(void))onDragEnd
                 editsKeypose:(BOOL)editsKeypose
              initialCategory:(nullable NSString *)initialCategory;

/// Fired when the user picks a category pill (constants popover uses it to
/// remember the last tab). Not fired for the initial selection.
@property(nonatomic, copy, nullable) void (^onCategoryChanged)
    (NSString *category);

/// Persist several lane constants at once, as ONE undo entry. Used by the
/// palette generator (rerolling N colours) - the per-lane drag path can only
/// commit one label per bracket, so a multi-lane write needs this. The host
/// wraps the writes in a single undo group. `labels[i]` pairs with
/// `valuesList[i]`. nil = fall back to per-label discrete commits.
@property(nonatomic, copy, nullable) void (^onCommitBatch)
    (NSArray<NSString *> *labels, NSArray<NSArray<NSNumber *> *> *valuesList);

/// Wire the per-keypose smooth toggle (shown on `spatialCurvable` lane rows in
/// the keypose popover). Fired with the lane label + new state; the host
/// writes it to the keypose at the open fraction.
- (void)setOnSmoothToggled:(void (^)(NSString *label, BOOL on))handler;

/// Wire the aspect-link toggle (shown on `aspectLinkable` lane rows in both the
/// constants and keypose popovers). Fired with the lane label + new state; the
/// host writes `aspectLinked` on the lane (global, not per-keypose).
- (void)setOnLinkToggled:(void (^)(NSString *label, BOOL on))handler;

/// Wire the gradient radial/linear type pill (keypose editor only). Fired with
/// the lane label + new type index; the host applies it to every keypose of the
/// lane (type is a single, non-animated property).
- (void)setOnGradientTypeChanged:(void (^)(NSString *label,
                                           NSInteger type))handler;

/// Update the header title in place (e.g. the keypose time as you navigate
/// between keyposes). No-op if the popover has no header.
- (void)setHeaderTitle:(NSString *)title;
/// Update the smaller subscript detail (e.g. the keypose time) in place.
- (void)setHeaderDetail:(NSString *)detail;
/// Show/hide a "link" chain glyph in the header to flag a linked keypose.
- (void)setHeaderLinked:(BOOL)linked;

/// Guide-only: screen rect of the render-mode pill's segment for `mode`
/// (Off/Filmstrip/Onion), or NSZeroRect if the pill isn't shown. Used by the
/// mini-viewer guide to spotlight the mode the user should tap.
- (NSRect)guideRenderModePillScreenRectForMode:(KKMiniViewerRenderMode)mode;

/// Fired when the user picks a size pill segment (0 = sm, 1 = md, 2 = lg). The
/// popover has already persisted the global preference and resized itself; the
/// host uses this only to advance the mini-viewer guide's size step.
@property(nonatomic, copy, nullable) void (^onSizeChanged)(NSInteger sizeIndex);

/// Guide-only: screen rect of the size pill's segment `index` (0/1/2), or
/// NSZeroRect if there's no mini-viewer (so no size pill).
- (NSRect)guideSizePillScreenRectForIndex:(NSInteger)index;

/// The global mini-viewer size preference (0 = sm/default, 1 = md, 2 = lg).
/// Exposed so a guide can reset it to the default for the run and restore the
/// user's value afterwards.
+ (NSInteger)popoverSizeIndex;
+ (void)setPopoverSizeIndex:(NSInteger)sizeIndex;

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
/// Rebuild the row stack in place (mini-viewer/header untouched) from a fresh
/// lane set + excluded labels, reusing the stored defaults provider / excluded
/// message / onAnimate. Used by the in-place update path so add/remove/navigate
/// re-render rows without reopening (which blinks the MTKView).
- (void)rebuildRowsWithLanes:(NSArray<KKLane *> *)lanes
              excludedLabels:(NSArray<NSString *> *)excluded;
/// Set (Advanced only) to give editable rows a leading "−" remove button that
/// fires `handler(label)`. Must be set before rows are (re)built; the present
/// path rebuilds once after setting it. nil = no remove gutter.
- (void)setRowRemoveHandler:(void (^)(NSString *label))handler;
/// Constants popover: give each row a leading curve-glyph button that fires
/// `handler(label)` to flip the lane to animatable. Same lifecycle as
/// `setRowRemoveHandler:` - must be set before rows are (re)built.
- (void)setRowAddToAnimatedHandler:(void (^)(NSString *label))handler;
/// YES while a colour-swatch row's shared NSColorPanel is open. The present
/// path's outside-click / scroll dismissal monitors read this and skip closing,
/// so interacting with the panel (a separate window) doesn't dismiss the
/// popover before the colour commits.
- (BOOL)suppressesPopoverDismiss;
/// The value-editor row (slider/fields) for `label`, or nil. Lets a guide
/// spotlight a specific constant's control.
- (nullable NSView *)rowViewForLabel:(NSString *)label;
/// Guide-driven constant edit through the *same* coalesced channel a real
/// slider/handle drag uses: begin → per-tick apply (live preview, knob +
/// mini-viewer track, persist stashed) → end (one persist + undo entry).
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
/// Screen rect of the choice-pill segment at `index` in `label`'s row (a radio
/// enum, e.g. an end-marker type), NSZeroRect if none. Spotlight target.
- (NSRect)guideChoicePillScreenRectForLabel:(NSString *)label
                                    atIndex:(NSInteger)index;
/// Screen rect of `label`'s row's "add to animated" gutter button, NSZeroRect
/// if none. Spotlight target.
- (NSRect)guideAddToAnimatedButtonScreenRectForLabel:(NSString *)label;
/// Screen rect of the category-nav pill segment for `key` (e.g. @"Stroke"),
/// NSZeroRect if there's no nav or no such category. Spotlight target.
- (NSRect)guideCategoryPillScreenRectForKey:(NSString *)key;
/// Scroll `label`'s row into the visible area of the row scroller (no-op if the
/// row is missing or hidden by the current category tab).
- (void)guideScrollRowIntoViewForLabel:(NSString *)label;
/// Switch the open popover to category `key` (nav pill + filter + height),
/// without firing onCategoryChanged. No-op if `key` isn't a present category.
- (void)guideSelectCategory:(NSString *)key;
+ (CGFloat)heightForLanes:(NSArray<KKLane *> *)lanes
           descriptorPath:(nullable NSString *)descriptorPath
               clipAspect:(CGFloat)clipAspect
            reserveHeader:(BOOL)reserveHeader;
+ (CGFloat)heightForLanes:(NSArray<KKLane *> *)lanes
           descriptorPath:(nullable NSString *)descriptorPath
               clipAspect:(CGFloat)clipAspect
            reserveHeader:(BOOL)reserveHeader
         selectedCategory:(nullable NSString *)selectedCategory;
@end

@interface _KKDropdownTrigger : NSView
@property(nonatomic, copy, nullable) NSArray<NSString *> *selectedLabels;
/// Optional owner (layer) names (multi-owner hosts): when non-empty the trigger
/// lists every animated layer's name with +N truncation ("layer 1, layer 2 +1")
/// instead of the property summary.
@property(nonatomic, copy, nullable) NSArray<NSString *> *layerTitles;
/// Pre-computed hierarchical summary string (see KKHierarchicalLaneSummary), or
/// the localized "All" sentinel. When non-nil it replaces the derived label
/// list as the field's text. The host owns the empty/placeholder decision by
/// leaving this nil (then `selectedLabels` drives the placeholder).
@property(nonatomic, copy, nullable) NSString *summaryOverride;
@property(nonatomic, copy, nullable) void (^onTapped)(void);
@end

/// Hosts the mini viewer as its documentView so magnify/scroll events flow.
/// Blocks at-boundary overscroll from reaching FCP's inspector root scroll
/// view.
@interface _KKMiniViewerScrollView : NSScrollView
@end

/// A non-editable row for a property excluded from the clicked boundary's
/// phase: its name, a muted message, and an Animate button that opts it back
/// in.
@interface _KKExcludedRow : NSView
@property(nonatomic, copy, nullable) void (^onAnimate)(void);
- (instancetype)initWithLabel:(NSString *)label
                      message:(NSString *)message
                       gutter:(BOOL)gutter;
@end

NS_ASSUME_NONNULL_END
