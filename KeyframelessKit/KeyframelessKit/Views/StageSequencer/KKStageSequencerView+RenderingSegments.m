/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../../Math/KKEasing.h"
#import "../../Style/NSColor+KKColors.h"
#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKStageSequencerView (RenderingSegments)

- (void)_renderSegmentFillsForLane:(KKTimingLane *)lane
                         laneIndex:(NSUInteger)laneIdx
                            trackX:(CGFloat)trackX
                        trackWidth:(CGFloat)trackWidth
                             laneY:(CGFloat)laneY {
  for (NSUInteger segIdx = 0; segIdx < lane.segments.count; segIdx++) {
    KKTimingSegment *seg = lane.segments[segIdx];
    CGFloat segX = [self _xForFrac:seg.start
                            trackX:trackX
                        trackWidth:trackWidth];
    CGFloat segW = (seg.end - seg.start) * trackWidth * _zoom;
    if (segW < 1)
      continue;

    NSRect segRect = NSMakeRect(segX, laneY + 2, segW, [self _laneHeight] - 4);
    BOOL isSelected =
        (lane.enabled && lane.selectedSegment == (NSInteger)segIdx);
    BOOL isHovered = (lane.enabled && _hoverSegLaneIdx == (NSInteger)laneIdx &&
                      _hoverSegSegIdx == (NSInteger)segIdx && !isSelected);

    NSColor *segColor = (seg.type == KKSegmentTypeHold)
                            ? [NSColor accentMatchingHost]
                            : [NSColor warning];
    NSBezierPath *segPath =
        [NSBezierPath bezierPathWithRoundedRect:segRect
                                        xRadius:kKSSSegmentCornerRadius
                                        yRadius:kKSSSegmentCornerRadius];
    if (isSelected) {
      [[segColor colorWithAlphaComponent:0.25] setFill];
      [segPath fill];
    } else if (isHovered) {
      [[segColor colorWithAlphaComponent:0.1] setFill];
      [segPath fill];
    } else if (!lane.enabled) {
      [[[NSColor inspectorLabel] colorWithAlphaComponent:0.06] setFill];
      [segPath fill];
    }

    if (seg.lockedDurationSeconds > 0 && lane.enabled) {
      NSBezierPath *lockPath = [NSBezierPath
          bezierPathWithRoundedRect:NSInsetRect(segRect, 0.75, 0.75)
                            xRadius:kKSSSegmentCornerRadius
                            yRadius:kKSSSegmentCornerRadius];
      CGFloat dashPattern[2] = {3.0, 2.0};
      [lockPath setLineDash:dashPattern count:2 phase:0];
      lockPath.lineWidth = 1.5;
      [[[NSColor inspectorLabel] colorWithAlphaComponent:0.7] setStroke];
      [lockPath stroke];
    }
  }
}

static double _segValueAt(KKTimingSegment *seg, NSUInteger component) {
  if (component >= seg.values.count)
    return 0;
  return seg.values[component].doubleValue;
}

static double _boundaryValueAt(NSArray<NSNumber *> *values,
                               NSUInteger component) {
  if (component >= values.count)
    return 0;
  return values[component].doubleValue;
}

static void _laneGraphFromTo(NSArray<KKTimingSegment *> *segments,
                             NSUInteger idx, NSUInteger component,
                             double *outFrom, double *outTo) {
  *outFrom = _boundaryValueAt(KKTimingBoundaryBefore(idx, segments), component);
  *outTo = _boundaryValueAt(KKTimingBoundaryAfter(idx, segments), component);
}

/// Per-component tint so each channel's curve is distinguishable on lanes
/// that plot multiple components simultaneously (e.g. Color plots R/G/B).
static NSColor *_componentTint(NSString *propertyLabel, NSUInteger component,
                               NSUInteger componentCount, BOOL isHold) {
  if ([propertyLabel isEqualToString:@"Color"] && componentCount == 3) {
    CGFloat rgb[3][3] = {
        {1.0, 0.35, 0.35},
        {0.35, 0.9, 0.35},
        {0.4, 0.55, 1.0},
    };
    return [NSColor colorWithSRGBRed:rgb[component][0]
                               green:rgb[component][1]
                                blue:rgb[component][2]
                               alpha:0.55];
  }

  NSColor *base = isHold ? [NSColor accentMatchingHost] : [NSColor warning];

  // Single-component lanes keep the original uniform alpha. Multi-component
  // lanes fan the alpha so overlapping/linked values still show as one line
  // while divergent values read as two (or four) distinct traces.
  if (componentCount <= 1)
    return [base colorWithAlphaComponent:0.55];

  CGFloat alphas2[2] = {0.75, 0.4};
  CGFloat alphas4[4] = {0.8, 0.6, 0.4, 0.25};
  CGFloat alpha;
  if (componentCount == 2) {
    alpha = alphas2[component];
  } else if (componentCount == 4) {
    alpha = alphas4[component];
  } else {
    CGFloat t = (componentCount > 1)
                    ? (CGFloat)component / (CGFloat)(componentCount - 1)
                    : 0;
    alpha = 0.8 - 0.5 * t;
  }
  return [base colorWithAlphaComponent:alpha];
}

- (void)_renderLaneGraph:(KKTimingLane *)lane
                  trackX:(CGFloat)trackX
              trackWidth:(CGFloat)trackWidth
                   laneY:(CGFloat)laneY {
  CGFloat pad = kKSSCurvePadding;
  CGFloat drawBottom = laneY + 2 + pad;
  CGFloat drawHeight = [self _laneHeight] - 4 - 2 * pad;
  if (drawHeight < 2)
    return;

  NSUInteger componentCount = 1;
  for (KKTimingSegment *seg in lane.segments)
    componentCount = MAX(componentCount, seg.values.count);

  // Compute dynamic value range across all components (including transition
  // overshoots from Elastic/Bounce) so every component shares the same Y scale.
  double minVal = 0, maxVal = 0;
  for (NSUInteger c = 0; c < componentCount; c++) {
    for (KKTimingSegment *seg in lane.segments) {
      double v = _segValueAt(seg, c);
      if (v < minVal)
        minVal = v;
      if (v > maxVal)
        maxVal = v;
    }
    for (NSUInteger i = 0; i < lane.segments.count; i++) {
      KKTimingSegment *s = lane.segments[i];
      if (s.type == KKSegmentTypeTransition) {
        double from = 0, to = 0;
        _laneGraphFromTo(lane.segments, i, c, &from, &to);
        BOOL mirror = (i == lane.segments.count - 1);
        for (NSInteger j = 0; j <= 10; j++) {
          double t = (double)j / 10.0;
          double ti = mirror ? (1.0 - t) : t;
          double eased = KKApplyEasing(ti, s.easing, s.intensity, s.frequency);
          if (mirror)
            eased = 1.0 - eased;
          double val = from + (to - from) * eased;
          if (val < minVal)
            minVal = val;
          if (val > maxVal)
            maxVal = val;
        }
      } else if (s.holdEffect != KKHoldEffectNone) {
        double base = _segValueAt(s, c);
        for (NSInteger j = 0; j <= 20; j++) {
          double t = (double)j / 20.0;
          double factor = KKApplyHoldEffect(t, s.holdEffect, s.intensity,
                                            s.frequency, (int)s.seed);
          double val = base * factor;
          if (val < minVal)
            minVal = val;
          if (val > maxVal)
            maxVal = val;
        }
      }
    }
  }
  double valRange = maxVal - minVal;
  if (valRange < 0.001) {
    maxVal = 1.0;
    minVal = 0.0;
    valRange = 1.0;
  }
  double (^normalize)(double) = ^(double v) {
    return (v - minVal) / valRange;
  };

  for (NSUInteger c = 0; c < componentCount; c++) {
    NSPoint lastPoint = NSZeroPoint;
    BOOL hasLast = NO;

    for (NSUInteger segIdx = 0; segIdx < lane.segments.count; segIdx++) {
      KKTimingSegment *seg = lane.segments[segIdx];
      CGFloat segLeft = [self _xForFrac:seg.start
                                 trackX:trackX
                             trackWidth:trackWidth];
      CGFloat segWidth = (seg.end - seg.start) * trackWidth * _zoom;
      if (segWidth < 1)
        continue;

      NSColor *lineColor = _componentTint(lane.propertyLabel, c, componentCount,
                                          seg.type == KKSegmentTypeHold);

      NSBezierPath *segPath = [NSBezierPath bezierPath];
      segPath.lineWidth = 1.5;

      if (seg.type == KKSegmentTypeHold) {
        CGFloat x0 = segLeft;
        CGFloat x1 = segLeft + segWidth;
        double base = _segValueAt(seg, c);
        if (seg.holdEffect == KKHoldEffectNone) {
          double normalized = normalize(base);
          CGFloat y = drawBottom + normalized * drawHeight;
          if (hasLast) {
            [segPath moveToPoint:lastPoint];
            [segPath lineToPoint:NSMakePoint(x0, y)];
          }
          [segPath moveToPoint:NSMakePoint(x0, y)];
          [segPath lineToPoint:NSMakePoint(x1, y)];
          lastPoint = NSMakePoint(x1, y);
        } else {
          NSPoint startPoint = NSZeroPoint;
          NSPoint endPoint = NSZeroPoint;
          for (NSInteger i = 0; i <= kKSSCurveSegments; i++) {
            double t = (double)i / (double)kKSSCurveSegments;
            double factor = KKApplyHoldEffect(t, seg.holdEffect, seg.intensity,
                                              seg.frequency, (int)seg.seed);
            double val = base * factor;
            CGFloat x = segLeft + t * segWidth;
            CGFloat y = drawBottom + normalize(val) * drawHeight;
            if (i == 0) {
              startPoint = NSMakePoint(x, y);
              [segPath moveToPoint:startPoint];
            } else {
              [segPath lineToPoint:NSMakePoint(x, y)];
            }
            if (i == kKSSCurveSegments)
              endPoint = NSMakePoint(x, y);
          }
          if (hasLast) {
            NSBezierPath *bridge = [NSBezierPath bezierPath];
            bridge.lineWidth = 1.5;
            [bridge moveToPoint:lastPoint];
            [bridge lineToPoint:startPoint];
            [lineColor setStroke];
            [bridge stroke];
          }
          lastPoint = endPoint;
        }
      } else {
        double fromVal = 0, toVal = 0;
        _laneGraphFromTo(lane.segments, segIdx, c, &fromVal, &toVal);
        BOOL isAnimateOut = (segIdx == lane.segments.count - 1);

        for (NSInteger i = 0; i <= kKSSCurveSegments; i++) {
          double t = (double)i / (double)kKSSCurveSegments;
          double ti = isAnimateOut ? (1.0 - t) : t;
          double eased =
              KKApplyEasing(ti, seg.easing, seg.intensity, seg.frequency);
          if (isAnimateOut)
            eased = 1.0 - eased;
          double val = fromVal + (toVal - fromVal) * eased;
          CGFloat x = segLeft + t * segWidth;
          CGFloat y = drawBottom + normalize(val) * drawHeight;
          if (i == 0)
            [segPath moveToPoint:NSMakePoint(x, y)];
          else
            [segPath lineToPoint:NSMakePoint(x, y)];
          if (i == kKSSCurveSegments)
            lastPoint = NSMakePoint(x, y);
        }
      }
      hasLast = YES;

      [lineColor setStroke];
      [segPath stroke];
    }
  }
}

@end
#pragma clang diagnostic pop
