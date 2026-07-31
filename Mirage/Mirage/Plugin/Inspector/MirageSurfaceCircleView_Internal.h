/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "MirageSurfaceCircleView.h"

static const CGFloat kRingThickness = 7.0;
/// The clear space between the ring and a label sitting outside it, on every side.
static const CGFloat kLabelGap = 5.0;
/// The circle stops shrinking here however long the labels are. A well too narrow
/// for its own labels used to eat the wheel; past this point the LABELS give way
/// instead, truncated by the drawing, because a wheel too small to aim at is worse
/// than a shortened word.
static const CGFloat kMinCircleDiameter = 140.0;
/// Breathing room between the circle and the view's own edge, on every side, that
/// exists whether or not there are labels. The label inset used to double as this
/// margin, so the hue-ring wells - whose templates declare no `xaxis=`/`yaxis=` -
/// came out flush against the top and bottom edges the moment the labels went away.
static const CGFloat kCircleMargin = 8.0;
static const CGFloat kPuckRadius = 6.0;
/// A handle carrying an icon, which needs room for the glyph to read at all.
static const CGFloat kPuckIconRadius = 9.0;
/// Segments around the ring. Enough that the ramp reads as continuous at the
/// sizes the panel uses, few enough to redraw at frame rate.
static const NSUInteger kRingSegments = 180;
/// How much of its own strength the whole-frame cloud keeps when it is drawn as a
/// ghost under the visible region's. Low enough that the bright layer is
/// unambiguously the reading, high enough that the ghost's SHAPE still resolves -
/// which is the whole reason it is drawn rather than dropped.
static const double kGhostCloudAlpha = 0.3;

// Defined in the core file and exported rather than static because the drawing
// category reads it too.
FOUNDATION_EXPORT NSDictionary *_Nonnull MirageAxisLabelAttributes(void);

NS_ASSUME_NONNULL_BEGIN

@interface MirageSurfaceCircleView () {
@package
  NSArray<NSNumber *> *_chromaBins;
  NSUInteger _chromaAngleBins;
  NSUInteger _chromaRadiusBins;
  double _chromaPeak;
  NSArray<NSNumber *> *_toneBins;
  double _tonePeak;
  /// The visible-region layer of each cloud, nil when the preview is showing the
  /// whole frame. Their peaks are normalised here, alongside the full-frame ones,
  /// for the same reason those are: this is per-measurement work, and a redraw
  /// runs far more often than a measurement does.
  NSArray<NSNumber *> *_chromaRegionBins;
  double _chromaRegionPeak;
  NSArray<NSNumber *> *_toneRegionBins;
  double _toneRegionPeak;
  BOOL _dragging;
  /// Which puck the current drag is moving.
  NSUInteger _dragIndex;
  /// Cursor minus puck at mousedown, so grabbing the puck off-centre does not
  /// teleport it under the pointer.
  NSPoint _grabOffset;
  /// The same idea for a tracked puck, where the offset that has to be preserved is
  /// an ANGLE: it has no distance to hold onto, so a cartesian offset would push it
  /// off the track and then be projected back, sliding the handle under the finger.
  double _grabBearing;
  id _dragLocalMonitor;
  id _dragGlobalMonitor;
  /// One NSColor per ring segment and per cloud cell, because neither depends on
  /// the frame - only a cell's ALPHA does. Deriving them per redraw meant ~1000
  /// hue inversions, each a bisection with three cube roots an iteration, on the
  /// main thread at the sampler's 20Hz: that is what made the scope lag.
  NSArray<NSColor *> *_ringColors;
  NSArray<NSColor *> *_cloudColors;
  NSUInteger _cloudColorsAngleBins;
  NSUInteger _cloudColorsRadiusBins;
}

- (NSEdgeInsets)_axisLabelInsets;
- (NSRect)_circleRect;
- (NSPoint)_normalisedFromViewPoint:(NSPoint)p;
- (NSPoint)_drawnPositionForPuck:(MirageSurfacePuck *)puck
                          pinned:(nullable BOOL *)outPinned;

@end

// Every pixel the circle puts on screen: the ring, the two clouds, the cast cross,
// the axis labels and the handles. Implemented in MirageSurfaceCircleView+Drawing.m.
@interface MirageSurfaceCircleView (Drawing)
- (NSArray<NSColor *> *)_cloudCellColors;
- (void)_drawChromaCloudInRect:(NSRect)circle;
- (void)_drawChromaCloudInRect:(NSRect)circle
                          bins:(NSArray<NSNumber *> *)bins
                          peak:(double)peak
                    alphaScale:(double)alphaScale;
- (void)_drawToneCloudInRect:(NSRect)circle;
- (void)_drawToneCloudInRect:(NSRect)circle
                        bins:(NSArray<NSNumber *> *)bins
                        peak:(double)peak
                  alphaScale:(double)alphaScale;
- (NSColor *)_ringColorForSegment:(NSUInteger)index;
- (void)_drawRingInRect:(NSRect)circle;
- (void)_drawCentroidInRect:(NSRect)circle;
- (void)_drawAxisLabelsInRect:(NSRect)circle;
- (void)_drawPuck:(MirageSurfacePuck *)puck
           active:(BOOL)active
           centre:(NSPoint)centre
           travel:(CGFloat)travel;
@end

// The drag: which puck a press means, the monitors that carry it, and the
// double-click reset. Implemented in MirageSurfaceCircleView+Interaction.m.
@interface MirageSurfaceCircleView (Interaction)
- (NSUInteger)_puckIndexForPress:(NSPoint)down grabbed:(nullable BOOL *)outGrabbed;
- (void)_dragTickWithEvent:(NSEvent *)event;
- (void)_endDrag;
- (void)_installDragMonitors;
- (void)_removeDragMonitors;
@end

NS_ASSUME_NONNULL_END
