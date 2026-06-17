/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKTimelineAdvancedView.h"
#import "KKTimelineZoomPan.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKTimingStage.h>

NS_ASSUME_NONNULL_BEGIN

// Geometry constants mirror KKTimelineBasicView so the two motion-graph
// children look identical when stacked into KKTimelineLanesView.
static const CGFloat kGraphPadX = 20.0;
static const CGFloat kGraphPadTop = 8.0;
static const CGFloat kGraphPadBottom = 8.0;
static const CGFloat kRulerH = 13.0;
static const CGFloat kRulerGap = 3.0;
static const CGFloat kTickMinSpacing = 50.0;

// Label gutter inside the left edge of the track for per-lane labels.
static const CGFloat kRowLabelW = 56.0;
static const CGFloat kRowLabelInset = 8.0;

// Lane rows split the tracks rect equally with a min floor; extra vertical
// space (e.g. the detached remote window) goes into taller rows.
static const CGFloat kRowMin = 30.0;
static const CGFloat kRowGap = 2.0;

// Thin "icon Name" strip drawn above the first row of each categorised group,
// so the timeline mirrors the inspector's category grouping and a group's name
// is always present (even when only that group is shown). Consumes its own
// height; lanes share the remainder. Zero when no lanes are categorised.
static const CGFloat kGroupDividerH = 24.0;
// Divider icon + label point size, matched to the duration-overlay text.
static const CGFloat kGroupDividerFontSize = 9.0;
// Layer (owner) header rows hug their content at this fixed height rather than
// sharing the lane rows' equal split - so a collapsed layer is just a slim
// header, not a wasted full-height lane row.
static const CGFloat kLayerHeaderRowH = 22.0;

// Boundary pill - vertical capsule spanning the row, same width as Basic.
static const CGFloat kPillW = 6.0;
static const CGFloat kPillInsetY = 3.0;
static const CGFloat kIntervalWidth = 2.0;
// Value range occupies the middle fraction of each row; outer headroom
// absorbs easing overshoot (Elastic/Bounce can exceed [0,1] by ~20%).
static const CGFloat kRowValueFrac = 0.60;
static const CGFloat kRowVPadMin = 4.0;
static const NSInteger kCurveSamples = 64;

// Playhead scrub + pill drag snap: closest candidate within this many px.
static const CGFloat kSnapInPx = 4.0;
// A press initiates either a pill drag or a popover open - disambiguated by
// the pointer travelling further than this from the press point.
static const CGFloat kDragThresholdPx = 3.0;

// Cross-category value math. Defined in the +Drawing .m (where they were
// originally static helpers); declared here so +Interaction / +Popovers can
// reuse the same equality + normalisation logic. KKAdvValuesEqual now forwards
// to the shared KKValuesEqual (Basic+Model) - same tolerance, one impl.
FOUNDATION_EXPORT BOOL KKValuesEqual(NSArray<NSNumber *> *a,
                                     NSArray<NSNumber *> *b);
FOUNDATION_EXPORT BOOL KKAdvValuesEqual(NSArray<NSNumber *> *a,
                                        NSArray<NSNumber *> *b);
FOUNDATION_EXPORT double KKAdvNormComponent(double v, NSArray<NSNumber *> *cMin,
                                            NSArray<NSNumber *> *cMax,
                                            NSUInteger i);

// Class extension: ivars only. Mirrors KKTimelineBasicView_Private.h's
// pattern - ivars are @package so categories in the same module can read /
// write them, and cross-category method decls live in the (Internal)
// category below to avoid duplicate-implementation warnings.
@interface KKTimelineAdvancedView () {
@package
  NSArray<KKLane *> *_availableLanes;
  KKTimeline *_timeline;
  // Labels of opted-in lanes the user hid via the lane-filter bar. Filtered out
  // of -_animatableLanes so the whole view (rows, hit-testing, heights) skips
  // them. View state only - never serialized.
  NSSet<NSString *> *_hiddenLaneLabels;
  BOOL _scrubbing;
  double _snappedScrubFrac;
  // Non-nil while a cmd+opt "scrub to here" gesture is active: the lane the
  // press landed in, so the drag keeps inverting the cursor through that lane's
  // warp (free, unsnapped) instead of the linear ruler mapping.
  NSString *_scrubLaneLabel;
  NSView *_popoverAnchor;

  NSString *_pressLaneLabel;
  NSInteger _pressKPIdx;
  NSPoint _pressPoint;
  BOOL _dragActive;
  BOOL _pressLocked; // press is on a locked lane: opens read-only, never drags
  double _dragSnapFrac;

  NSString *_topLaneLabel;
  NSInteger _topKPIdx;

  double _currentPopoverFrac;

  NSMutableSet<NSString *> *_selection;
  NSMutableSet<NSString *> *_selectedGaps;
  // layerKeys whose lanes are collapsed (hidden) in the graph; the layer's
  // header row stays, with a filled glyph. Display-only, per view instance.
  NSMutableSet<NSString *> *_collapsedLayerKeys;
  // The layer the keypose popover currently scopes to (multi-owner timelines).
  // Set on pill click + by the host's layer-list selection.
  NSString *_activeLayerKey;

  BOOL _gapPressActive;
  NSString *_gapPressLabel;
  NSInteger _gapPressAIdx;

  BOOL _marqueeActive;
  NSPoint _marqueeAnchor;
  NSPoint _marqueeCurrent;
  BOOL _marqueeShift;

  NSMutableDictionary<NSString *, NSNumber *> *_dragOriginTimes;
  double _dragOriginFrac;

  // Snapshot of the pressed lane's keypose times, captured at the start of a
  // multi-selection drag so the cursor->frac mapping stays stable under the
  // Dynamic warp while the whole group moves (see -_frozenDragFracForX:).
  NSArray<NSNumber *> *_dragFrozenLaneTimes;

  NSInteger _lastEmittedSelectionCount;

  BOOL _optPressOnPill;
  BOOL _optPressOnEmpty;
  BOOL _eraserActive;
  NSInteger _eraserLaneRow;
  BOOL _wasDuplicateDrag;

  NSString *_menuPillLabel;
  NSInteger _menuPillKPIdx;
  NSString *_menuGapLabel;
  NSInteger _menuGapAIdx;
  NSInteger _menuGapLaneRow;
  double _menuGapFrac;

  NSInteger _hoverLaneRow;
  NSTrackingArea *_hoverTrackingArea;

  KKTimelineZoomPan *_zp;
  BOOL _zoomedNotified;

  // Vertical scroll offset (points) for the lane rows when they don't all fit
  // at kRowMin. The ruler is drawn above the graph rect and is unaffected, so
  // it stays pinned while the rows scroll beneath it. 0 == top.
  CGFloat _scrollY;

  NSString *_hoverGapLabel;
  NSInteger _hoverGapAIdx;

  // Hover over a non-editable leading (before first pill) / trailing (after
  // last pill) hold: label of that lane (nil = not hovering an edge hold) and
  // which end. Drives the gray informational duration readout.
  NSString *_hoverEdgeLabel;
  BOOL _hoverEdgeLeading;

  // Backing ivars for public properties - declared here so categories can
  // read/write them directly (auto-synthesized ivars aren't visible to
  // categories). Property synthesis in the core .m picks these up.
  double _clipDurationSeconds;
  double _frameDurationSeconds;
  double _playheadFraction;
  BOOL _dynamicDisplay;
  BOOL _interactionsBlocked;
  void (^_onSelectionChanged)(void);
}
@end

// Cross-category private methods. Each is defined in exactly one category
// .m file; declaring them here lets the other categories call them without
// triggering "category implementing method also implemented by primary
// class" warnings.
@interface KKTimelineAdvancedView (Internal)

// Model - pure helpers (no mutations, no UI side effects).
- (NSArray<KKLane *> *)_animatableLanes;
- (double)_clipDuration;
- (NSRect)_graphRect;
- (CGFloat)_trackLeftOffset;
- (NSRect)_tracksRect;
- (CGFloat)_xForFrac:(double)frac inTracks:(NSRect)t;
- (double)_fracForX:(CGFloat)x inTracks:(NSRect)t;
// Fraction of the last renderable frame; the warp + linear projections map the
// data domain [0, lastFrameFrac] onto the full track width.
- (double)_lastFrameFrac;
// Lane-aware projection (KKTimelineAdvancedView+Warp.m): when dynamicDisplay is
// ON each lane's intervals are warped so short transitions stay grabbable;
// falls back to the linear -_xForFrac:inTracks: when OFF / lane has < 2
// keyposes. The ruler + scrub keep using the linear variant.
- (CGFloat)_xForFrac:(double)frac inLane:(KKLane *)lane inTracks:(NSRect)t;
- (double)_fracForX:(CGFloat)x inLane:(KKLane *)lane inTracks:(NSRect)t;
// Cursor->frac while dragging the single keypose `kpIdx` in `lane`: bisects
// the warp so the dragged pill tracks the cursor without ping. Linear fallback
// when dynamicDisplay is OFF.
- (double)_dragFracForX:(CGFloat)x
                 inLane:(KKLane *)lane
          draggingKPIdx:(NSInteger)kpIdx
               inTracks:(NSRect)t;
// Cursor->frac during a multi-selection drag, via the frozen pressed-lane warp
// snapshot (_dragFrozenLaneTimes). Linear fallback when OFF / no snapshot.
- (double)_frozenDragFracForX:(CGFloat)x inTracks:(NSRect)t;
// Pressed-lane keypose times as NSNumbers (for the frozen-warp snapshot).
- (NSArray<NSNumber *> *)_laneKeyposeTimes:(KKLane *)lane;
- (CGFloat)_rowHeightForCount:(NSInteger)n;
- (NSRect)_rowRectForIndex:(NSInteger)i count:(NSInteger)n;
// Per-animatable-lane flags marking the first lane of each categorised run (a
// group-header strip is drawn above those rows). All-NO when no lane is
// categorised, so the layout collapses to the flat row model.
- (NSArray<NSNumber *> *)_groupDividerFlags;
// Largest valid _scrollY: total row height minus the visible tracks height
// (0 when every row fits, i.e. no scrolling needed).
- (CGFloat)_maxScrollY;
// Re-clamp _scrollY into [0, _maxScrollY] after a layout / timeline change.
- (void)_clampScroll;
// Scroll the minimum amount so lane row `i` (of `n`) sits fully inside the
// visible tracks region (so a popover anchored to it isn't clipped/off-screen).
- (void)_ensureLaneRowVisible:(NSInteger)i count:(NSInteger)n;
- (NSArray<NSNumber *> *)_snapCandidates;
- (NSInteger)_intervalStartKPIdxInLane:(KKLane *)lane atFrac:(double)frac;
- (NSInteger)_animatableIndexForLabel:(NSString *)label;
- (NSInteger)_animatableCount;
- (nullable KKLane *)_animatableLaneForLabel:(NSString *)label;
- (NSArray<NSNumber *> *)_templateDefaultValuesForLabel:(NSString *)label;
- (NSString *)_selectionKeyForLabel:(NSString *)label kpIdx:(NSInteger)idx;
- (BOOL)_decodeSelectionKey:(NSString *)key
                      label:(NSString *_Nullable *_Nullable)outLabel
                      kpIdx:(NSInteger *_Nullable)outKP;
- (BOOL)_pillSelected:(KKLane *)lane atIdx:(NSInteger)idx;
- (NSString *)_gapKeyForLabel:(NSString *)label aIdx:(NSInteger)aIdx;
- (BOOL)_gapSelected:(KKLane *)lane aIdx:(NSInteger)aIdx;
- (BOOL)_pillAtPoint:(NSPoint)pt
                lane:(NSInteger *)outLaneIdx
                  kp:(NSInteger *)outKPIdx;
- (NSInteger)_laneRowAtPoint:(NSPoint)pt;

// Drawing - drawRect helpers (see +Drawing.m).
- (void)_drawDurationPillInRect:(NSRect)g
                         tracks:(NSRect)tracks
                           lane:(KKLane *)lane
                          fracA:(double)fracA
                          fracB:(double)fracB
                           tint:(NSColor *)tint
                         rulerY:(CGFloat)rulerY;
- (void)_drawDurationOverlayInRect:(NSRect)g tracks:(NSRect)tracks;
- (void)_drawMarqueeRect;
- (void)_drawDragSnapGuideInRect:(NSRect)g tracks:(NSRect)tracks;
- (void)_drawLane:(KKLane *)lane inRow:(NSRect)row tracks:(NSRect)tracks;
- (void)_drawGapSelectionForLane:(KKLane *)lane
                           inRow:(NSRect)row
                          tracks:(NSRect)tracks;
- (void)_drawTieBarsForLane:(KKLane *)lane
                      inRow:(NSRect)row
                    pillTop:(CGFloat)pillTop
                     tracks:(NSRect)tracks
                    neutral:(NSColor *)neutral;
- (void)_drawPillForKPInLane:(KKLane *)lane
                     atIndex:(NSInteger)i
                     pillBot:(CGFloat)pillBot
                     pillTop:(CGFloat)pillTop
                      tracks:(NSRect)tracks
                     neutral:(NSColor *)neutral
                        warn:(NSColor *)warn;
- (void)_drawRulerInRect:(NSRect)g tracks:(NSRect)tracks;
- (void)_drawPlayheadInRect:(NSRect)g tracks:(NSRect)tracks;
// Top/bottom fade shadows over the scrolling rows (mirrors KKPaddedScrollView)
// - top fade shown while scrolled down, bottom fade while more rows lie below.
- (void)_drawScrollFadesInRect:(NSRect)g;
// Draw a "── icon Name ──" category header in `strip` (above a group's first
// row), using `lane`'s categoryKey (localized) + categorySymbol.
- (void)_drawGroupDividerForLane:(KKLane *)lane inStrip:(NSRect)strip;
// Draws a layer HEADER row (name + symbol + collapse glyph) for a placeholder
// lane; `collapsed` picks the filled vs outline symbol.
- (void)_drawLayerHeaderRowForLane:(KKLane *)lane
                             inRow:(NSRect)row
                         collapsed:(BOOL)collapsed;

// Interaction - scrub + drag + edits + keyboard + menu.
- (BOOL)_isInScrubBand:(NSPoint)pt;
- (double)_snappedDragFracForX:(CGFloat)x
                          frac:(double)rawFrac
                      inTracks:(NSRect)tracks
                      skipLane:(nullable NSString *)skipLane
                        skipKP:(NSInteger)skipKP;
- (double)_snappedScrubFracForX:(CGFloat)x inTracks:(NSRect)tracks;
- (double)_deliveredScrubFracFromVisual:(double)visualFrac;
- (void)_eraserTickAtPoint:(NSPoint)pt;
- (void)_writeValueForLabel:(NSString *)label
                     atFrac:(double)frac
                     values:(NSArray<NSNumber *> *)values;
- (void)_removeKPInLaneIdx:(NSInteger)laneIdx kpIdx:(NSInteger)kpIdx;
- (void)_addAndOpenKPForLaneIdx:(NSInteger)laneIdx atFrac:(double)frac;
- (void)_addKeyposeAtFrac:(double)frac forLabel:(NSString *)label;
- (void)_removeKeyposeAtFrac:(double)frac forLabel:(NSString *)label;
- (BOOL)_anySameGroupKeyposeAtFrac:(double)frac
                             group:(nullable NSString *)group;
- (NSInteger)_insertDuplicateOfKPInLaneLabel:(NSString *)label
                                       kpIdx:(NSInteger)kpIdx;
- (BOOL)_replaceOnDropForLabel:(NSString *)label dupIdx:(NSInteger)dupIdx;
- (void)_moveSelectionByDelta:(double)delta;
- (void)_addPillsInRect:(NSRect)rect
            toSelection:(NSMutableSet<NSString *> *)sel;
- (void)_addGapsInRect:(NSRect)rect toSelection:(NSMutableSet<NSString *> *)sel;
- (void)_deleteSelectedKPs;
- (NSInteger)_moveKPInLaneLabel:(NSString *)label
                          kpIdx:(NSInteger)kpIdx
                         toFrac:(double)frac;

// Popovers - value / gap / link.
- (void)_openValuePopoverForLane:(NSInteger)laneIdx kp:(NSInteger)kpIdx;
- (void)_openGapPopoverForLabel:(NSString *)label kpIdx:(NSInteger)aIdx;
- (void)_toggleLinkForLabel:(NSString *)label kpIdx:(NSInteger)aIdx;
- (void)_mutateIntervalInLaneLabel:(NSString *)label
                              aIdx:(NSInteger)aIdx
                              with:(void (^)(KKInterval *iv))mut;

// Zoom notification used by the magnify/scroll handlers in the core .m.
- (void)_notifyZoomChanged;
- (void)_updateHoverFromPoint:(NSPoint)pt;

@end

NS_ASSUME_NONNULL_END
