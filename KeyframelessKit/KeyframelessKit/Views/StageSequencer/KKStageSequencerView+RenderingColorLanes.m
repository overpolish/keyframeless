/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../Math/KKEasing.h"
#import "../../Math/KKGradientSampling.h"
#import "../../Style/NSColor+KKColors.h"
#import "../KKGradientBarView.h"
#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKStageSequencerView (RenderingColorLanes)

/// Build stops for a flat gradient array. For Color kind (3 floats = R,G,B)
/// synthesize a two-stop single-color gradient so the strip renders solid.
static NSArray<KKGradientStop *> *_stopsFromValues(NSArray<NSNumber *> *values,
                                                   KKAnimatableParamKind kind) {
  if (kind == KKAnimatableParamKindGradient)
    return KKGradientStopsFromFlat(values);
  if (kind == KKAnimatableParamKindColor && values.count >= 3) {
    NSColor *c = [NSColor colorWithSRGBRed:values[0].doubleValue
                                     green:values[1].doubleValue
                                      blue:values[2].doubleValue
                                     alpha:1.0];
    return @[
      [KKGradientStop stopWithPosition:0 color:c],
      [KKGradientStop stopWithPosition:1 color:c],
    ];
  }
  return nil;
}

/// Render the color-strip + single easing curve for a Color or Gradient
/// lane. Replaces the generic multi-component line graph, which treats
/// stop positions/colors/midpoints as separate scalar traces and ends up
/// plotting a confusing wall of lines.
- (void)_renderColorLaneForLane:(KKTimingLane *)lane
                           kind:(KKAnimatableParamKind)kind
                         trackX:(CGFloat)trackX
                     trackWidth:(CGFloat)trackWidth
                          laneY:(CGFloat)laneY {
  CGFloat laneH = [self _laneHeight];
  CGFloat inset = 2.0;
  CGFloat stripH = MIN(10.0, MAX(4.0, floor(laneH * 0.20)));
  CGFloat stripY = laneY + laneH - inset - stripH;
  CGFloat curveBottom = laneY + inset + kKSSCurvePadding;
  CGFloat curveTop = stripY - kKSSCurvePadding;
  if (curveTop < curveBottom)
    curveTop = curveBottom; // degenerate — lane too short for curve.

  NSArray<KKTimingSegment *> *segments = lane.segments;

  // Precompute the abstract value range across every segment so transition
  // overshoots (Elastic/Bounce) and hold-effect oscillations get headroom —
  // same approach scalar lanes use in `_renderLaneGraph`. Baseline includes
  // 0 (transition starts) and 1 (rest / transition ends) so the curve area
  // never collapses when the lane is all-no-effect holds.
  double minVal = 0.0, maxVal = 1.0;
  static const NSInteger kSampleCount = 32;
  for (NSUInteger sIdx = 0; sIdx < segments.count; sIdx++) {
    KKTimingSegment *s = segments[sIdx];
    BOOL animateOut = (sIdx == segments.count - 1);
    if (s.type == KKSegmentTypeHold && s.holdEffect == KKHoldEffectNone)
      continue;
    for (NSInteger i = 0; i <= kSampleCount; i++) {
      double t = (double)i / (double)kSampleCount;
      double v;
      if (s.type == KKSegmentTypeHold) {
        v = KKApplyHoldEffect(t, s.holdEffect, s.intensity, s.frequency,
                              (int)s.seed);
      } else if (KKIsHTHTransition(lane, (NSInteger)sIdx)) {
        // HTH curve plots `1 + (e(t) - t)` so endpoints meet the rest line
        // (v=1) and the deviation lifts/dips into the lane interior.
        double e = KKApplyEasing(t, s.easing, s.intensity, s.frequency);
        v = 1.0 + (e - t);
      } else {
        double ti = animateOut ? (1.0 - t) : t;
        double e = KKApplyEasing(ti, s.easing, s.intensity, s.frequency);
        v = animateOut ? (1.0 - e) : e;
      }
      if (v < minVal)
        minVal = v;
      if (v > maxVal)
        maxVal = v;
    }
  }
  double valRange = maxVal - minVal;
  if (valRange < 0.001)
    valRange = 1.0;

  for (NSUInteger segIdx = 0; segIdx < segments.count; segIdx++) {
    KKTimingSegment *seg = segments[segIdx];
    CGFloat segX = [self _xForFrac:seg.start
                            trackX:trackX
                        trackWidth:trackWidth];
    CGFloat segW = (seg.end - seg.start) * trackWidth * _zoom;
    if (segW < 1)
      continue;
    CGFloat innerW = MAX(0, segW - 2 * inset);
    CGFloat stripX = segX + inset;

    // HTH transitions don't represent any morph (both surrounding holds
    // share the same value), so suppress the color strip entirely. The curve
    // band still occupies its space below, keeping vertical alignment with
    // adjacent segments.
    BOOL isHTH = KKIsHTHTransition(lane, (NSInteger)segIdx);

    // Both hold and transition draw the segment's own stored values, so a
    // transition shows the *target* color/gradient assigned to it (what the
    // segment represents) rather than the morph between its boundaries.
    NSArray<KKGradientStop *> *stops =
        isHTH ? nil : _stopsFromValues(seg.values, kind);
    if (stops.count >= 2) {
      int lutN = 64;
      simd_float3 *lut =
          (simd_float3 *)malloc(sizeof(simd_float3) * (size_t)lutN);
      KKGradientSampleStopsToLUT(stops, lut, lutN);
      // Snap stripe edges to integer pixels so adjacent rects share exact
      // boundaries — otherwise subpixel NSRectFills leave faint vertical
      // seams that read as "sampling lines".
      for (int i = 0; i < lutN; i++) {
        CGFloat x0 = round(stripX + (CGFloat)i / (CGFloat)lutN * innerW);
        CGFloat x1 = round(stripX + (CGFloat)(i + 1) / (CGFloat)lutN * innerW);
        if (x1 <= x0)
          continue;
        simd_float3 c = lut[i];
        [[NSColor colorWithSRGBRed:c.x green:c.y blue:c.z alpha:1.0] setFill];
        NSRectFill(NSMakeRect(x0, stripY, x1 - x0, stripH));
      }
      free(lut);
    }

    if (curveTop > curveBottom) {
      NSColor *lineColor =
          (seg.type == KKSegmentTypeHold)
              ? [[NSColor accentMatchingHost] colorWithAlphaComponent:0.55]
              : [[NSColor warning] colorWithAlphaComponent:0.55];
      [lineColor setStroke];
      NSBezierPath *path = [NSBezierPath bezierPath];
      path.lineWidth = 1.5;
      NSInteger steps = MAX(8, (NSInteger)floor(segW / 3.0));
      BOOL isAnimateOut = (segIdx == segments.count - 1);
      for (NSInteger i = 0; i <= steps; i++) {
        double t = (double)i / (double)steps;
        CGFloat x = stripX + (CGFloat)t * innerW;
        CGFloat y;
        double v;
        if (isHTH) {
          // HTH transitions morph between equal boundaries (rest value 1).
          // Plot the easing deviation from linear lifted to the rest line so
          // endpoints meet the adjacent hold lines and the interior shape
          // reads as the curve's personality. Range scan above includes
          // these samples so the lane scales to fit any overshoot.
          double e = KKApplyEasing(t, seg.easing, seg.intensity, seg.frequency);
          v = 1.0 + (e - t);
        } else if (seg.type == KKSegmentTypeHold) {
          if (seg.holdEffect == KKHoldEffectNone) {
            v = 1.0; // rest
          } else {
            v = KKApplyHoldEffect(t, seg.holdEffect, seg.intensity,
                                  seg.frequency, (int)seg.seed);
          }
        } else {
          double e = KKApplyEasing(t, seg.easing, seg.intensity, seg.frequency);
          // Animate-out descends, animate-in/mid rises — distinct silhouette
          // for the last-segment case instead of mirroring the same shape.
          v = isAnimateOut ? (1.0 - e) : e;
        }
        double y01 = (v - minVal) / valRange;
        y = curveBottom + (CGFloat)y01 * (curveTop - curveBottom);
        if (i == 0)
          [path moveToPoint:NSMakePoint(x, y)];
        else
          [path lineToPoint:NSMakePoint(x, y)];
      }
      [path stroke];
    }
  }
}

/// Render the easing curve at full lane height with no value strip — used
/// by Morph lanes, which have no scalar per-segment payload to display.
/// Same normalized 0–1 baseline as the color/gradient renderer's curve
/// portion, scaled to occupy the entire lane.
- (void)_renderNormalizedCurveForLane:(KKTimingLane *)lane
                               trackX:(CGFloat)trackX
                           trackWidth:(CGFloat)trackWidth
                                laneY:(CGFloat)laneY {
  CGFloat laneH = [self _laneHeight];
  CGFloat curveBottom = laneY + 2 + kKSSCurvePadding;
  CGFloat curveTop = laneY + laneH - 2 - kKSSCurvePadding;
  if (curveTop <= curveBottom)
    return;

  NSArray<KKTimingSegment *> *segments = lane.segments;

  double minVal = 0.0, maxVal = 1.0;
  static const NSInteger kSampleCount = 32;
  for (NSUInteger sIdx = 0; sIdx < segments.count; sIdx++) {
    KKTimingSegment *s = segments[sIdx];
    BOOL animateOut = (sIdx == segments.count - 1);
    if (s.type == KKSegmentTypeHold && s.holdEffect == KKHoldEffectNone)
      continue;
    for (NSInteger i = 0; i <= kSampleCount; i++) {
      double t = (double)i / (double)kSampleCount;
      double v;
      if (s.type == KKSegmentTypeHold) {
        v = KKApplyHoldEffect(t, s.holdEffect, s.intensity, s.frequency,
                              (int)s.seed);
      } else if (KKIsHTHTransition(lane, (NSInteger)sIdx)) {
        double e = KKApplyEasing(t, s.easing, s.intensity, s.frequency);
        v = 1.0 + (e - t);
      } else {
        double ti = animateOut ? (1.0 - t) : t;
        double e = KKApplyEasing(ti, s.easing, s.intensity, s.frequency);
        v = animateOut ? (1.0 - e) : e;
      }
      if (v < minVal)
        minVal = v;
      if (v > maxVal)
        maxVal = v;
    }
  }
  double valRange = maxVal - minVal;
  if (valRange < 0.001)
    valRange = 1.0;

  for (NSUInteger segIdx = 0; segIdx < segments.count; segIdx++) {
    KKTimingSegment *seg = segments[segIdx];
    CGFloat segX = [self _xForFrac:seg.start
                            trackX:trackX
                        trackWidth:trackWidth];
    CGFloat segW = (seg.end - seg.start) * trackWidth * _zoom;
    if (segW < 1)
      continue;
    CGFloat innerW = MAX(0, segW - 4);
    CGFloat curveX = segX + 2;

    BOOL isHTH = KKIsHTHTransition(lane, (NSInteger)segIdx);
    NSColor *lineColor =
        (seg.type == KKSegmentTypeHold)
            ? [[NSColor accentMatchingHost] colorWithAlphaComponent:0.55]
            : [[NSColor warning] colorWithAlphaComponent:0.55];
    [lineColor setStroke];
    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = 1.5;
    NSInteger steps = MAX(8, (NSInteger)floor(segW / 3.0));
    BOOL isAnimateOut = (segIdx == segments.count - 1);
    for (NSInteger i = 0; i <= steps; i++) {
      double t = (double)i / (double)steps;
      CGFloat x = curveX + (CGFloat)t * innerW;
      double v;
      if (isHTH) {
        double e = KKApplyEasing(t, seg.easing, seg.intensity, seg.frequency);
        v = 1.0 + (e - t);
      } else if (seg.type == KKSegmentTypeHold) {
        if (seg.holdEffect == KKHoldEffectNone) {
          v = 1.0;
        } else {
          v = KKApplyHoldEffect(t, seg.holdEffect, seg.intensity, seg.frequency,
                                (int)seg.seed);
        }
      } else {
        double e = KKApplyEasing(t, seg.easing, seg.intensity, seg.frequency);
        v = isAnimateOut ? (1.0 - e) : e;
      }
      double y01 = (v - minVal) / valRange;
      CGFloat y = curveBottom + (CGFloat)y01 * (curveTop - curveBottom);
      if (i == 0)
        [path moveToPoint:NSMakePoint(x, y)];
      else
        [path lineToPoint:NSMakePoint(x, y)];
    }
    [path stroke];
  }
}

@end
#pragma clang diagnostic pop
