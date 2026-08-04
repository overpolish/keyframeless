/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Shared internals for _KKStaticValuesPopoverView and its category splits
// (+Expression / +Palette / ...). The ivars are @package so the categories -
// which cannot see the primary class's backing store - reach the same state the
// main .m builds. The primary @interface lives in
// KKTimelineLanesView_Private.h.

#import "KKTimelineLanesView_Private.h"
#import <QuartzCore/QuartzCore.h>

@class KKCodeEditorView;
@class KKLinkManifest;
@class KKMiniViewerView;
@class KKPaddedScrollView;
@class KKPillToggleRowView;
@class KKPopoverHeaderView;
@class KKPopoverPeekButton;

NS_ASSUME_NONNULL_BEGIN

// Shared with +Expression (defined in the main .m, used from both): whether a
// lane carries an inline expression editor, and the editor-row heights.
FOUNDATION_EXPORT BOOL KKLaneHasExpressionEditor(KKLane *lane);
FOUNDATION_EXPORT const CGFloat kKKExprEditorTextH;
FOUNDATION_EXPORT const CGFloat kKKExprEditorRowH;
FOUNDATION_EXPORT const CGFloat kKKExprEditorExpandedH;

@class KKPillBar;

@interface _KKStaticValuesPopoverView () {
@package
  NSMutableDictionary<NSString *, _KKStaticValueRow *> *_rowsByLabel;
  NSStackView *_stack;
  // Hard ceiling at the popover's own (hardcoded, per-size) content width.
  // Without it a single wide row - e.g. a 4-component lane whose auto-sized
  // component labels are long - propagates its required width up through
  // `row.width == stack.width` and NSPopover grows the whole popover past its
  // size, leaving the centred category pill bar hanging over the edge.
  NSLayoutConstraint *_maxWidthConstraint;
  // Vertical scroller (top/bottom fade shadows) hosting only the param-row
  // stack, so the mini-viewer + header + category pill stay sticky above and a
  // small / low-resolution display can scroll the rows instead of clipping
  // them.
  KKPaddedScrollView *_rowsScroll;
  KKMiniViewerView *_miniViewer;
  // Header-band 3-segment pill (sm/md/lg) that sets the global mini-viewer
  // size; the mini-viewer's height constraint is updated in place so the
  // preview grows/shrinks without reopening the popover. Both nil with no
  // mini-viewer.
  KKPillToggleRowView *_sizePill;
  NSLayoutConstraint *_miniViewerHeightConstraint;
  KKPillToggleRowView *_renderModePill; // guide anchor; nil when no pill shown
  // Host-supplied strip between the mini-viewer band and the category nav /
  // rows (Mirage's shader rack). Always in the constraint chain, zero-height
  // and empty until a host installs one - so a popover without an accessory
  // lays out exactly as it did before the seam existed.
  NSView *_accessoryHost;
  NSLayoutConstraint *_accessoryHeightConstraint;
  CGFloat _accessoryHeight;
  // The gap the host would sit below the mini-viewer band by if it were just
  // another stacked element. An installed strip pads ITSELF (its own top/bottom
  // inset), so the constraint goes to zero and this is what
  // -_naturalContentSize has to give back - the class-level height calc counts
  // the gap unconditionally.
  NSLayoutConstraint *_accessoryTopConstraint;
  CGFloat _accessoryTopInset;
  // Category nav: an icon pill row under the mini-viewer that filters which
  // param rows show. nil/empty when <2 distinct lane categories (no pill).
  KKPillToggleRowView *_categoryPill;
  KKPillBar *_categoryPillBar; // the pill's scrolling wrapper (see the rebuild)
  NSArray<NSString *> *_categoryKeys; // ordered, first-seen
  NSString *_selectedCategory;        // currently shown category key
  NSDictionary<NSString *, NSString *> *_rowCategoryByLabel;
  // Live component values per lane (seeded from open-time keyposes, updated on
  // every edit) so conditional `visibleWhen` rules + the page-resize see the
  // current Mode/Type selections, not the stale open-time snapshot.
  NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *_currentValuesByLabel;
  // YES when any lane carries a `visibleWhen` rule - gates the (cheap but not
  // free) per-edit visibility recompute to plugins that actually use it.
  BOOL _laneGatesVisibility;
  // YES while a colour swatch's shared panel is open. The presenter's outside-
  // click monitors read this (via -suppressesPopoverDismiss) and skip
  // dismissal, so clicking into the panel (a separate window) doesn't close the
  // popover.
  BOOL _colorPanelOpen;
  BOOL _exprMenuOpen; // reference-insert menu is tracking (see
                      // -suppressesPopoverDismiss)
  // Debounced persist for the async colour panel: while it's open, a continuous
  // drag fires a value callback every frame. Persisting each one stacks an undo
  // step per frame, and we can't hold a synchronous drag undo group open across
  // the panel's own event loop (that corrupts FCP's FFUIAction nesting). So we
  // preview live but defer the persist, coalescing a burst into ONE undoable
  // write when the drag settles (timer) or the panel closes.
  NSTimer *_colorPersistTimer;
  NSString *_colorPendingLabel;
  NSArray<NSNumber *> *_colorPendingValues;
  // Excluded ("Animate" placeholder) rows aren't in _rowsByLabel; track them so
  // the category filter can hide/show them too.
  NSMutableDictionary<NSString *, NSView *> *_excludedRowsByLabel;
  // Inline parameter-link expression editor ROWS, keyed by lane label. Each is
  // a full-width container (the arranged stack subview) holding an inset
  // KKCodeEditorView, sitting directly under the lane's value row; the category
  // filter hides it with its row.
  NSMutableDictionary<NSString *, NSView *> *_exprRowsByLabel;
  // Labels whose expression editor is EXPANDED (taller); survives row rebuilds
  // so the user's expand choice sticks. The row owns its height
  // (-setEditorRowHeight:), so the chevron just re-reads this set.
  NSMutableSet<NSString *> *_exprExpandedLabels;
  // The KKCodeEditorView inside each expression row, keyed by lane label, so
  // the reference-insert menu can drop a token into the right editor. Torn down
  // wherever `_exprRowsByLabel` is (they are created and removed together).
  NSMutableDictionary<NSString *, KKCodeEditorView *> *_exprEditorByLabel;
  // Repeating timer that refreshes the inline result strips (live value->result
  // readout) so time-based expressions update as the playhead / playback moves.
  NSTimer *_exprResultTimer;
  // Playhead-motion tracking for the keypose sparkline marker: last tick's
  // linkTimelineSec + whether it changed. Moving (scrub/playback) -> the dot
  // follows the playhead; settled -> it pings back to the keypose
  // (editFraction).
  double _lastMarkerLinkSec;
  BOOL _playheadMoving;
  // Discovered link sources (other clips' manifests), cached so the display<->
  // stored token transforms don't hit disk on every keystroke. Refreshed when
  // an editor is installed and each time the insert menu opens.
  NSArray<KKLinkManifest *> *_linkManifests;
  // Colour labels the user has pinned via the per-swatch lock toggle. Transient
  // (never persisted): a palette reroll skips these. Survives row rebuilds
  // because it lives on the long-lived popover, keyed by lane label.
  NSMutableSet<NSString *> *_lockedColorLabels;
  CGFloat _labelColumnWidth; // uniform across rows (widest localized name)
  NSArray<KKLane *> *_lanes; // last lanes laid out (for per-category resize)
  // The anchor the category pill (and, when there's no pill, the row stack)
  // pins below - the mini-viewer / header bottom. Captured in init so the pill
  // can be rebuilt in place when the lane set changes (a category empties out).
  NSLayoutYAxisAnchor *_categoryNavTopAnchor;
  CGFloat _categoryNavTopInset;
  NSLayoutConstraint *_stackTopConstraint;
  NSString *_descriptorPath;
  CGFloat _clipAspect;
  void (^_onHandleValue)(NSString *, NSArray<NSNumber *> *);
  void (^_onSmoothToggled)(NSString *, BOOL);
  void (^_onLinkToggled)(NSString *, BOOL);
  void (^_onSetLinkExpression)(NSString *, NSString *);
  void (^_onGradientTypeChanged)(NSString *, NSInteger);
  BOOL _editsKeypose;
  void (^_onDragBegin)(void);
  void (^_onDragEnd)(void);
  NSButton *_navPrevButton;
  NSButton *_navNextButton;
  NSButton *_closeButton;
  KKPopoverPeekButton *_compositionPeekButton;
  void (^_onNavigate)(NSInteger);
  KKPopoverHeaderView *_header;
  BOOL _hasHeader;
  // Stored so the in-place row rebuild (add/remove/navigate) can re-derive
  // rows without the popover reopening: provider feeds reset defaults,
  // message/onAnimate drive the "Animate" (addable) rows.
  NSArray<NSNumber *> * (^_defaultsProvider)(NSString *);
  NSString *_excludedMessage;
  void (^_onAnimate)(NSString *);
  // Set (Advanced only) → editable rows gain a leading "−" remove button
  // that calls this with the row's label; nil → no remove gutter (Basic /
  // constants). Stored so the in-place rebuild keeps the gutter.
  void (^_rowRemoveHandler)(NSString *);
  // Constants popover only → rows gain a leading curve-glyph button that
  // calls this with the row's label to flip the lane to animatable.
  void (^_rowAddToAnimatedHandler)(NSString *);
}
+ (CGFloat)_heightForLanes:(NSArray<KKLane *> *)lanes
            descriptorPath:(nullable NSString *)descriptorPath
                clipAspect:(CGFloat)clipAspect
             reserveHeader:(BOOL)reserveHeader
          selectedCategory:(nullable NSString *)selectedCategory
             valuesByLabel:
                 (nullable NSDictionary<NSString *, NSArray<NSNumber *> *> *)
                     valuesByLabel;
@end

// Private methods shared across the category splits (called from the main .m or
// another category).
@interface _KKStaticValuesPopoverView (Private)
// +Palette - triggered from the generator bar in the row area.
- (void)_generatePaletteWithMode:(NSInteger)mode;
- (void)_refinePalette;
// +Expression - installed / synced / refreshed from the row builder + timers.
- (void)_installExprEditorForLane:(KKLane *)lane;
- (void)_updateAllExprResults;
- (void)_updateCachedLaneExpression:(NSString *)expr forLabel:(NSString *)label;
- (BOOL)_syncExprEditorForLabel:(NSString *)label
                     expression:(NSString *)expr
                       afterRow:(_KKStaticValueRow *)valueRow;
- (BOOL)_syncExprEditorForLane:(KKLane *)lane
                      afterRow:(_KKStaticValueRow *)valueRow;
- (void)_resyncExprEditorTextForLane:(KKLane *)lane;
- (void)_retranslateExprEditors;
// Core (main .m) - re-fit the popover after an editor row grows / shrinks.
- (void)_applyContentSize;
@end

NS_ASSUME_NONNULL_END
