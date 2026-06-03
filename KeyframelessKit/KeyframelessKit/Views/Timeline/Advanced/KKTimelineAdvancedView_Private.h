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
  BOOL _scrubbing;
  double _snappedScrubFrac;
  NSView *_popoverAnchor;

  NSString *_pressLaneLabel;
  NSInteger _pressKPIdx;
  NSPoint _pressPoint;
  BOOL _dragActive;
  double _dragSnapFrac;

  NSString *_topLaneLabel;
  NSInteger _topKPIdx;

  double _currentPopoverFrac;

  NSMutableSet<NSString *> *_selection;
  NSMutableSet<NSString *> *_selectedGaps;

  BOOL _gapPressActive;
  NSString *_gapPressLabel;
  NSInteger _gapPressAIdx;

  BOOL _marqueeActive;
  NSPoint _marqueeAnchor;
  NSPoint _marqueeCurrent;
  BOOL _marqueeShift;

  NSMutableDictionary<NSString *, NSNumber *> *_dragOriginTimes;
  double _dragOriginFrac;

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

  // Backing ivars for public properties - declared here so categories can
  // read/write them directly (auto-synthesized ivars aren't visible to
  // categories). Property synthesis in the core .m picks these up.
  double _clipDurationSeconds;
  double _frameDurationSeconds;
  double _playheadFraction;
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
- (CGFloat)_rowHeightForCount:(NSInteger)n;
- (NSRect)_rowRectForIndex:(NSInteger)i count:(NSInteger)n;
// Largest valid _scrollY: total row height minus the visible tracks height
// (0 when every row fits, i.e. no scrolling needed).
- (CGFloat)_maxScrollY;
// Re-clamp _scrollY into [0, _maxScrollY] after a layout / timeline change.
- (void)_clampScroll;
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
