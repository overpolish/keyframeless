/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "../../Math/KKTimingStage.h"
#import "../../Style/KKTokens.h"
#import "KKStageSequencerView.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KKSequencerRowKind) {
  KKSequencerRowKindLane = 0,
  KKSequencerRowKindHeader = 1,
};

/// Row-plan entry used internally by `KKStageSequencerView`. Lane rows
/// reference an index into `_lanes`; header rows carry the group's display
/// state read from the first lane of the group.
@interface KKSequencerRow : NSObject
@property(nonatomic) KKSequencerRowKind kind;
@property(nonatomic) NSInteger laneIndex;
@property(nonatomic, copy, nullable) NSString *groupKey;
@property(nonatomic, copy, nullable) NSString *groupLabel;
@property(nonatomic) BOOL groupCollapsed;
@end

static const CGFloat kKSSGroupHeaderHeight __attribute__((unused)) = 22.0;
static const CGFloat kKSSRulerHeight __attribute__((unused)) = 10.0;
static const CGFloat kKSSPlayheadSnapPx __attribute__((unused)) = 10.0;
static const CGFloat kKSSBoundaryLabelHeight __attribute__((unused)) = 10.0;
static const CGFloat kKSSEditButtonSize __attribute__((unused)) = 16.0;
static const CGFloat kKSSEditMinSegmentPx __attribute__((unused)) = 30.0;
static const CGFloat kKSSMinLaneHeight __attribute__((unused)) = 30.0;
static const CGFloat kKSSLaneSpacing __attribute__((unused)) = KKSpacingXS;
static const CGFloat kKSSLabelWidth __attribute__((unused)) = 110.0;
static const CGFloat kKSSLabelPadding __attribute__((unused)) = KKSpacingLG;
static const CGFloat kKSSOSCIconSize __attribute__((unused)) = 12.0;
static const CGFloat kKSSOSCIconGap __attribute__((unused)) = KKSpacingLG;
static const CGFloat kKSSSegmentCornerRadius __attribute__((unused)) =
    KKRadiusSM;
static const CGFloat kKSSCurvePadding __attribute__((unused)) = 3.0;
static const CGFloat kKSSBorderInset __attribute__((unused)) = KKPaddingSM;
static const CGFloat kKSSEdgeHitZone __attribute__((unused)) = 5.0;
static const CGFloat kKSSMinSegmentSec __attribute__((unused)) = 0.1;
static const CGFloat kKSSMinSegmentPx __attribute__((unused)) = 12.0;
static const CGFloat kKSSSnapPx __attribute__((unused)) = 6.0;
static const CGFloat kKSSDragThresholdPx __attribute__((unused)) = 4.0;
static const NSInteger kKSSCurveSegments __attribute__((unused)) = 160;

@interface KKStageSequencerView () {
@package
  NSImage *_lanesImage;
  // Drag state (edge resize).
  BOOL _dragging;
  NSInteger _dragLaneIdx;
  NSInteger _dragSegIdx;
  BOOL _dragLeadingEdge;
  CGFloat _dragTrackX;
  CGFloat _dragTrackWidth;
  // Drag state (segment move).
  BOOL _dragMoving;
  CGFloat _dragMoveStartFrac;
  double _dragMoveOrigStart;
  double _dragMoveOrigEnd;
  // Drag state (lane move — Control+drag).
  BOOL _dragLaneMoving;
  CGFloat _dragLaneMoveStartFrac;
  NSArray<KKTimingSegment *> *_dragLaneMoveOrigSegs;
  // Drag state (bulk edge drag — Shift+edge-drag for offset, Opt+Shift for
  // align). Each entry in `_bulkEdgeTargets` wraps {laneIdx, boundaryIdx,
  // origFrac} via NSValue/CGRect: x=laneIdx, y=boundaryIdx, width=origFrac.
  BOOL _bulkEdgeDrag;
  BOOL _bulkEdgeAlign;
  double _bulkEdgeOrigFrac;
  NSArray<NSValue *> *_bulkEdgeTargets;
  // Pending Control+click — promotes to lane-move once the cursor moves
  // past `kKSSDragThresholdPx`; otherwise resolves to a lock toggle on
  // mouseUp.
  BOOL _pendingCtrlClick;
  NSInteger _pendingCtrlLaneIdx;
  NSInteger _pendingCtrlSegIdx;
  NSPoint _pendingCtrlStartLoc;
  // Drag state (value copy — Option+drag).
  BOOL _dragValueCopying;
  NSInteger _dragCopyLaneIdx;
  NSInteger _dragCopySrcSegIdx;
  NSInteger _dragCopyDstSegIdx;
  // Hover state.
  NSInteger _hoverLaneIdx;
  NSInteger _hoverSegIdx;
  BOOL _hoverLeading;
  BOOL _hoveringEdge;
  // Segment hover (for highlight).
  NSInteger _hoverSegLaneIdx;
  NSInteger _hoverSegSegIdx;
  // Zoom/pan state.
  CGFloat _zoom;      // 1.0 = fit all, higher = zoomed in.
  CGFloat _panOffset; // Visible start as fraction 0–1.
  // Snap guide state (set during an active drag when a boundary snaps).
  BOOL _snapActive;
  double _snapFrac;
  // Row plan — one entry per visible row (header or lane). Rebuilt by
  // `_rebuildRowPlan` whenever `_lanes` changes. When no lane carries a
  // `groupKey`, this collapses to one lane row per lane and Y math matches
  // the pre-group implementation.
  NSArray<KKSequencerRow *> *_rowPlan;
  // Maps each lane index in `_lanes` to its row index in `_rowPlan`, or
  // -1 when the lane is hidden under a collapsed group.
  NSArray<NSNumber *> *_planRowForLane;
  // Per-groupKey chevron rotation (0/40/90 degrees) and animation token.
  // Mirrors KKChevronView's two-frame snap so the inspector and sequencer
  // group headers feel identical.
  NSMutableDictionary<NSString *, NSNumber *> *_groupChevronRotation;
  NSMutableDictionary<NSString *, NSNumber *> *_groupChevronAnimToken;
}

- (void)_trackGeometryForWidth:(CGFloat)viewWidth
                        trackX:(CGFloat *)outTrackX
                    trackWidth:(CGFloat *)outTrackWidth;
- (CGFloat)_xForFrac:(double)frac
              trackX:(CGFloat)trackX
          trackWidth:(CGFloat)trackWidth;
- (double)_fracForX:(CGFloat)x
             trackX:(CGFloat)trackX
         trackWidth:(CGFloat)trackWidth;
- (void)_clampPanOffset;
- (CGFloat)_laneYForIndex:(NSUInteger)laneIdx totalHeight:(CGFloat)totalHeight;
- (CGFloat)_rowYForPlanIndex:(NSUInteger)rowIdx
                 totalHeight:(CGFloat)totalHeight;
- (CGFloat)_laneHeight;
- (CGFloat)_totalHeight;
/// Returns the per-scalar kind array for `lane`, preferring the lane's own
/// `valueComponentKinds` and falling back to the deprecated
/// `laneComponentKindsByLabel` dict. May return nil when neither source
/// has data.
- (nullable NSArray<NSNumber *> *)_componentKindsForLane:(KKTimingLane *)lane;
/// Returns the slot-level kind for `lane`, used for color/gradient
/// detection. Prefers `lane.valueComponentKinds.firstObject`, falls back
/// to `laneKindsByLabel[propertyLabel]`. May return nil.
- (nullable NSNumber *)_slotKindForLane:(KKTimingLane *)lane;
- (NSRect)_editButtonRectForLaneIndex:(NSUInteger)laneIdx
                         segmentIndex:(NSUInteger)segIdx
                               trackX:(CGFloat)trackX
                           trackWidth:(CGFloat)trackWidth
                          totalHeight:(CGFloat)totalHeight;

// Per-lane rendering. Defined across +RenderingLabels, +RenderingSegments,
// +RenderingColorLanes, +RenderingOverlays. The orchestration entry point
// `renderLanes` in +Rendering.m calls these on a per-lane basis.
- (void)_renderLaneLabel:(KKTimingLane *)lane laneY:(CGFloat)laneY;
- (void)_renderGroupHeaderRow:(KKSequencerRow *)row
                         rowY:(CGFloat)rowY
                       trackX:(CGFloat)trackX
                   trackWidth:(CGFloat)trackWidth;
- (void)_animateGroupChevronForKey:(NSString *)groupKey
                         collapsed:(BOOL)collapsed;
- (NSRect)_groupHeaderRectForRowY:(CGFloat)rowY;
- (void)_renderBoundaryLabelsForLane:(KKTimingLane *)lane
                           laneIndex:(NSUInteger)laneIdx
                              trackX:(CGFloat)trackX
                          trackWidth:(CGFloat)trackWidth
                               laneY:(CGFloat)laneY;
- (void)_renderSegmentFillsForLane:(KKTimingLane *)lane
                         laneIndex:(NSUInteger)laneIdx
                            trackX:(CGFloat)trackX
                        trackWidth:(CGFloat)trackWidth
                             laneY:(CGFloat)laneY;
- (void)_renderLaneGraph:(KKTimingLane *)lane
                  trackX:(CGFloat)trackX
              trackWidth:(CGFloat)trackWidth
                   laneY:(CGFloat)laneY;
- (void)_renderColorLaneForLane:(KKTimingLane *)lane
                           kind:(KKAnimatableParamKind)kind
                         trackX:(CGFloat)trackX
                     trackWidth:(CGFloat)trackWidth
                          laneY:(CGFloat)laneY;
- (void)_renderNormalizedCurveForLane:(KKTimingLane *)lane
                               trackX:(CGFloat)trackX
                           trackWidth:(CGFloat)trackWidth
                                laneY:(CGFloat)laneY;
- (void)_renderEdgeHoverForLane:(KKTimingLane *)lane
                      laneIndex:(NSUInteger)laneIdx
                         trackX:(CGFloat)trackX
                     trackWidth:(CGFloat)trackWidth
                          laneY:(CGFloat)laneY;
- (void)_renderEditButtonForHoveredSegment;
- (void)_renderValueCopyDropTargetWithTrackX:(CGFloat)trackX
                                  trackWidth:(CGFloat)trackWidth
                                 totalHeight:(CGFloat)totalHeight;
- (void)_renderSnapGuideWithTrackX:(CGFloat)trackX
                        trackWidth:(CGFloat)trackWidth
                       totalHeight:(CGFloat)totalHeight;

// Hit-test helpers. Defined in +InteractionHitTest.
- (BOOL)_hitTestEdgeAtPoint:(NSPoint)loc
                    laneIdx:(NSInteger *)outLane
                     segIdx:(NSInteger *)outSeg
                    leading:(BOOL *)outLeading;
- (BOOL)_canDeleteAtPoint:(NSPoint)loc;
- (BOOL)_editButtonUnderPoint:(NSPoint)loc
                      outLane:(nullable NSInteger *)outLane
                       outSeg:(nullable NSInteger *)outSeg
                outAnchorRect:(nullable NSRect *)outRect;
- (void)_segmentUnderPoint:(NSPoint)loc
                   outLane:(NSInteger *)outLane
                    outSeg:(NSInteger *)outSeg;

// Drag mechanics. Defined in +InteractionDrag.
- (double)_snappedFrac:(double)frac
               enabled:(BOOL)enabled
           excludeLane:(NSInteger)excludeLaneIdx
                trackX:(CGFloat)trackX
            trackWidth:(CGFloat)trackWidth
            outSnapped:(BOOL *)outSnapped
               outFrac:(double *)outFrac;
- (BOOL)_tryBeginEdgeDragForLane:(KKTimingLane *)lane
                       laneIndex:(NSUInteger)laneIdx
                             loc:(NSPoint)loc
                          trackX:(CGFloat)trackX
                      trackWidth:(CGFloat)trackWidth;
- (BOOL)_tryBeginSegmentInteractionForLane:(KKTimingLane *)lane
                                 laneIndex:(NSUInteger)laneIdx
                                     event:(NSEvent *)event
                                       loc:(NSPoint)loc
                                    trackX:(CGFloat)trackX
                                trackWidth:(CGFloat)trackWidth;
- (void)_dragValueCopyToEvent:(NSEvent *)event;
- (void)_dragLaneMoveToEvent:(NSEvent *)event;
- (void)_applySegmentMoveWithFrac:(double)newFrac
                      snapEnabled:(BOOL)snapEnabled
                            lanes:(NSMutableArray<KKTimingLane *> *)lanes;
- (void)_applyEdgeDragWithFrac:(double)newFrac
                   snapEnabled:(BOOL)snapEnabled
                         lanes:(NSMutableArray<KKTimingLane *> *)lanes;
- (void)_applyBulkEdgeDragWithFrac:(double)newFrac
                             lanes:(NSMutableArray<KKTimingLane *> *)lanes;

@end

NS_ASSUME_NONNULL_END
