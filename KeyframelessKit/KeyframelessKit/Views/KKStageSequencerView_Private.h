/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "../Math/KKTimingStage.h"
#import "../Style/KKTokens.h"
#import "KKStageSequencerView.h"

NS_ASSUME_NONNULL_BEGIN

static const CGFloat kKSSRulerHeight __attribute__((unused)) = 10.0;
static const CGFloat kKSSPlayheadSnapPx __attribute__((unused)) = 10.0;
static const CGFloat kKSSBoundaryLabelHeight __attribute__((unused)) = 10.0;
static const CGFloat kKSSLaneHeight __attribute__((unused)) = 30.0;
static const CGFloat kKSSLaneSpacing __attribute__((unused)) = KKSpacingXS;
static const CGFloat kKSSLabelWidth __attribute__((unused)) = 50.0;
static const CGFloat kKSSLabelPadding __attribute__((unused)) = KKSpacingSM;
static const CGFloat kKSSSegmentCornerRadius __attribute__((unused)) =
    KKRadiusSM;
static const CGFloat kKSSCurvePadding __attribute__((unused)) = 3.0;
static const CGFloat kKSSBorderInset __attribute__((unused)) = KKPaddingSM;
static const CGFloat kKSSEdgeHitZone __attribute__((unused)) = 5.0;
static const CGFloat kKSSMinSegmentFrac __attribute__((unused)) = 0.04;
static const CGFloat kKSSMinSegmentPx __attribute__((unused)) = 12.0;
static const CGFloat kKSSSnapPx __attribute__((unused)) = 6.0;
static const NSInteger kKSSCurveSegments __attribute__((unused)) = 40;

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
  // Drag state (lane move — Option+drag).
  BOOL _dragLaneMoving;
  CGFloat _dragLaneMoveStartFrac;
  NSArray<KKTimingSegment *> *_dragLaneMoveOrigSegs;
  // Hover state.
  NSInteger _hoverLaneIdx;
  NSInteger _hoverSegIdx;
  BOOL _hoverLeading;
  BOOL _hoveringEdge;
  // Segment hover (for highlight).
  NSInteger _hoverSegLaneIdx;
  NSInteger _hoverSegSegIdx;
  // Ruler scrub state.
  BOOL _scrubbingRuler;
  // Zoom/pan state.
  CGFloat _zoom;      // 1.0 = fit all, higher = zoomed in.
  CGFloat _panOffset; // Visible start as fraction 0–1.
  // Snap guide state (set during an active drag when a boundary snaps).
  BOOL _snapActive;
  double _snapFrac;
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
- (CGFloat)_totalHeight;

@end

NS_ASSUME_NONNULL_END
