/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Math/KKEasing.h"
#import "../Style/NSColor+KKColors.h"
#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKStageSequencerView (Rendering)

- (void)renderLanes {
  CGFloat totalWidth = NSWidth(self.bounds);
  if (totalWidth < 1 || !self.lanes.count)
    return;

  CGFloat totalHeight = [self _totalHeight];
  CGFloat imageWidth = totalWidth;
  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:totalWidth
                        trackX:&trackX
                    trackWidth:&trackWidth];

  NSImage *image =
      [[NSImage alloc] initWithSize:NSMakeSize(imageWidth, totalHeight)];
  [image lockFocus];

  for (NSUInteger laneIdx = 0; laneIdx < self.lanes.count; laneIdx++) {
    KKTimingLane *lane = self.lanes[laneIdx];
    CGFloat laneY = [self _laneYForIndex:laneIdx totalHeight:totalHeight];

    [self _renderLaneBackground:lane laneY:laneY imageWidth:imageWidth];
    [self _renderLaneLabel:lane laneY:laneY];

    if (trackWidth < 1)
      continue;

    [self _renderSegmentFillsForLane:lane
                           laneIndex:laneIdx
                              trackX:trackX
                          trackWidth:trackWidth
                               laneY:laneY];

    if (lane.enabled && trackWidth > 10) {
      [self _renderLaneGraph:lane
                      trackX:trackX
                  trackWidth:trackWidth
                       laneY:laneY];
      [self _renderBoundaryLabelsForLane:lane
                               laneIndex:laneIdx
                                  trackX:trackX
                              trackWidth:trackWidth
                                   laneY:laneY];
    }

    [self _renderEdgeHoverForLane:lane
                        laneIndex:laneIdx
                           trackX:trackX
                       trackWidth:trackWidth
                            laneY:laneY];
  }

  [self _renderRulerWithTrackX:trackX
                    trackWidth:trackWidth
                   totalHeight:totalHeight];
  [self _renderSnapGuideWithTrackX:trackX
                        trackWidth:trackWidth
                       totalHeight:totalHeight];
  [self _renderPlayheadWithTrackX:trackX
                       trackWidth:trackWidth
                      totalHeight:totalHeight];

  [image unlockFocus];
  _lanesImage = image;
  NSRect proposedRect = NSMakeRect(0, 0, image.size.width, image.size.height);
  CGImageRef cgImage = [image CGImageForProposedRect:&proposedRect
                                             context:nil
                                               hints:nil];
  self.layer.contents = (__bridge id)cgImage;
}

- (void)_renderLaneBackground:(KKTimingLane *)lane
                        laneY:(CGFloat)laneY
                   imageWidth:(CGFloat)imageWidth {
  NSRect laneRect = NSMakeRect(
      kKSSBorderInset, laneY, imageWidth - 2 * kKSSBorderInset, kKSSLaneHeight);
  [[NSColor inspectorBackground] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:laneRect
                                   xRadius:KKRadiusMD
                                   yRadius:KKRadiusMD] fill];
}

- (void)_renderLaneLabel:(KKTimingLane *)lane laneY:(CGFloat)laneY {
  NSColor *labelColor =
      lane.enabled ? [NSColor inspectorLabel]
                   : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  NSDictionary *labelAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName : labelColor,
  };
  NSSize labelSize = [lane.propertyLabel sizeWithAttributes:labelAttrs];
  NSPoint labelPoint =
      NSMakePoint(kKSSBorderInset + kKSSLabelPadding,
                  laneY + (kKSSLaneHeight - labelSize.height) / 2.0);
  [lane.propertyLabel drawAtPoint:labelPoint withAttributes:labelAttrs];
}

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

    NSRect segRect = NSMakeRect(segX, laneY + 2, segW, kKSSLaneHeight - 4);
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
  }
}

- (void)_renderEdgeHoverForLane:(KKTimingLane *)lane
                      laneIndex:(NSUInteger)laneIdx
                         trackX:(CGFloat)trackX
                     trackWidth:(CGFloat)trackWidth
                          laneY:(CGFloat)laneY {
  if (!(_hoveringEdge && _hoverLaneIdx == (NSInteger)laneIdx && lane.enabled))
    return;

  CGFloat edgeX = -1;
  if (_hoverSegIdx >= 0 && (NSUInteger)_hoverSegIdx < lane.segments.count) {
    KKTimingSegment *seg = lane.segments[_hoverSegIdx];
    double frac = _hoverLeading ? seg.start : seg.end;
    edgeX = [self _xForFrac:frac trackX:trackX trackWidth:trackWidth];
  }
  if (edgeX < 0)
    return;

  [[NSColor accentMatchingHost] setStroke];
  NSBezierPath *line = [NSBezierPath bezierPath];
  [line moveToPoint:NSMakePoint(edgeX, laneY + 2)];
  [line lineToPoint:NSMakePoint(edgeX, laneY + kKSSLaneHeight - 2)];
  line.lineWidth = 2.0;
  [line stroke];
}

static double _segAvgValue(KKTimingSegment *seg) {
  if (!seg.values.count)
    return 0;
  double sum = 0;
  for (NSNumber *v in seg.values)
    sum += v.doubleValue;
  return sum / seg.values.count;
}

- (void)_renderLaneGraph:(KKTimingLane *)lane
                  trackX:(CGFloat)trackX
              trackWidth:(CGFloat)trackWidth
                   laneY:(CGFloat)laneY {
  CGFloat pad = kKSSCurvePadding;
  CGFloat drawBottom = laneY + 2 + pad;
  CGFloat drawHeight = kKSSLaneHeight - 4 - 2 * pad;
  if (drawHeight < 2)
    return;

  double maxVal = 0;
  for (KKTimingSegment *seg in lane.segments) {
    double v = fabs(_segAvgValue(seg));
    if (v > maxVal)
      maxVal = v;
  }
  if (maxVal < 0.001)
    maxVal = 1.0;

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

    NSColor *lineColor =
        (seg.type == KKSegmentTypeHold)
            ? [[NSColor accentMatchingHost] colorWithAlphaComponent:0.5]
            : [[NSColor warning] colorWithAlphaComponent:0.5];

    NSBezierPath *segPath = [NSBezierPath bezierPath];
    segPath.lineWidth = 1.5;

    if (seg.type == KKSegmentTypeHold) {
      double normalized = _segAvgValue(seg) / maxVal;
      CGFloat y = drawBottom + normalized * drawHeight;
      CGFloat x0 = segLeft;
      CGFloat x1 = segLeft + segWidth;
      if (hasLast) {
        [segPath moveToPoint:lastPoint];
        [segPath lineToPoint:NSMakePoint(x0, y)];
      }
      [segPath moveToPoint:NSMakePoint(x0, y)];
      [segPath lineToPoint:NSMakePoint(x1, y)];
      lastPoint = NSMakePoint(x1, y);
    } else {
      double fromVal = _segAvgValue(seg);
      double toVal = _segAvgValue(seg);
      if (segIdx > 0)
        fromVal = _segAvgValue(lane.segments[segIdx - 1]);
      if (segIdx + 1 < lane.segments.count)
        toVal = _segAvgValue(lane.segments[segIdx + 1]);

      double fromNorm = fromVal / maxVal;
      double toNorm = toVal / maxVal;

      for (NSInteger i = 0; i <= kKSSCurveSegments; i++) {
        double t = (double)i / (double)kKSSCurveSegments;
        double eased =
            KKApplyEasing(t, seg.easing, seg.intensity, seg.frequency);
        eased = MAX(0.0, MIN(1.0, eased));
        double val = fromNorm + (toNorm - fromNorm) * eased;
        CGFloat x = segLeft + t * segWidth;
        CGFloat y = drawBottom + val * drawHeight;
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

static NSString *_boundaryTimeLabel(double fraction, double duration) {
  double sec = fraction * duration;
  if (sec < 0.01)
    return @"0s";
  if (sec < 10.0)
    return [NSString stringWithFormat:@"%.1fs", sec];
  int totalSec = (int)sec;
  int m = totalSec / 60;
  int s = totalSec % 60;
  if (m > 0)
    return [NSString stringWithFormat:@"%d:%02d", m, s];
  return [NSString stringWithFormat:@"%ds", s];
}

- (void)_renderBoundaryLabelsForLane:(KKTimingLane *)lane
                           laneIndex:(NSUInteger)laneIdx
                              trackX:(CGFloat)trackX
                          trackWidth:(CGFloat)trackWidth
                               laneY:(CGFloat)laneY {
  if (self.effectDuration <= 0)
    return;

  CGFloat labelRowY = laneY - kKSSBoundaryLabelHeight;

  NSDictionary *dimAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:8.0
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName :
        [[NSColor inspectorLabel] colorWithAlphaComponent:0.35],
  };

  CGFloat durLabelLeft = -999, durLabelRight = -999;
  BOOL isHovered =
      (_hoverSegLaneIdx == (NSInteger)laneIdx && _hoverSegSegIdx >= 0 &&
       (NSUInteger)_hoverSegSegIdx < lane.segments.count);
  NSString *durLabel = nil;
  NSDictionary *durAttrs = nil;
  CGFloat durX = 0, durY = 0;

  if (isHovered) {
    KKTimingSegment *hSeg = lane.segments[_hoverSegSegIdx];
    double durSec = (hSeg.end - hSeg.start) * self.effectDuration;
    if (durSec < 10.0)
      durLabel = [NSString stringWithFormat:@"%.1fs", durSec];
    else
      durLabel = [NSString stringWithFormat:@"%.0fs", durSec];

    durAttrs = @{
      NSFontAttributeName : [NSFont systemFontOfSize:8.0
                                              weight:NSFontWeightMedium],
      NSForegroundColorAttributeName : (hSeg.type == KKSegmentTypeHold)
          ? [NSColor accentMatchingHost]
          : [NSColor warning],
    };
    NSSize durSize = [durLabel sizeWithAttributes:durAttrs];
    CGFloat segMidX = [self _xForFrac:(hSeg.start + hSeg.end) / 2.0
                               trackX:trackX
                           trackWidth:trackWidth];
    durX = segMidX - durSize.width / 2.0;
    durX = MAX(trackX, MIN(trackX + trackWidth - durSize.width, durX));
    durY = labelRowY + (kKSSBoundaryLabelHeight - durSize.height) / 2.0;
    durLabelLeft = durX;
    durLabelRight = durX + durSize.width;
  }

  NSMutableArray<NSNumber *> *boundaries = [NSMutableArray array];
  for (KKTimingSegment *seg in lane.segments) {
    [boundaries addObject:@(seg.start)];
  }
  KKTimingSegment *last = lane.segments.lastObject;
  if (last)
    [boundaries addObject:@(last.end)];

  CGFloat lastLabelRight = -999;
  static const CGFloat kLabelGap = 4.0;

  for (NSNumber *bNum in boundaries) {
    double frac = bNum.doubleValue;
    CGFloat bx = [self _xForFrac:frac trackX:trackX trackWidth:trackWidth];
    NSString *label = _boundaryTimeLabel(frac, self.effectDuration);
    NSSize labelSize = [label sizeWithAttributes:dimAttrs];
    CGFloat labelX = bx - labelSize.width / 2.0;
    labelX = MAX(trackX, MIN(trackX + trackWidth - labelSize.width, labelX));

    if (labelX < lastLabelRight + kLabelGap)
      continue;

    if (isHovered && labelX + labelSize.width + kLabelGap > durLabelLeft &&
        labelX < durLabelRight + kLabelGap)
      continue;

    CGFloat labelY =
        labelRowY + (kKSSBoundaryLabelHeight - labelSize.height) / 2.0;
    [label drawAtPoint:NSMakePoint(labelX, labelY) withAttributes:dimAttrs];
    lastLabelRight = labelX + labelSize.width;
  }

  if (isHovered && durLabel)
    [durLabel drawAtPoint:NSMakePoint(durX, durY) withAttributes:durAttrs];
}

static double _tickIntervalForPixelsPerSecond(CGFloat pps) {
  static const double candidates[] = {0.1,  0.25, 0.5,  1.0,  2.0,   5.0,
                                      10.0, 15.0, 30.0, 60.0, 120.0, 300.0};
  static const int count = sizeof(candidates) / sizeof(candidates[0]);
  CGFloat minSpacing = 50.0;
  for (int i = 0; i < count; i++) {
    if (candidates[i] * pps >= minSpacing)
      return candidates[i];
  }
  return candidates[count - 1];
}

static NSString *_timecodeLabel(double seconds) {
  int totalSec = (int)seconds;
  int m = totalSec / 60;
  int s = totalSec % 60;
  double frac = seconds - totalSec;
  if (frac > 0.001 && seconds < 60)
    return [NSString stringWithFormat:@"%d.%ds", s, (int)(frac * 10)];
  if (m > 0)
    return [NSString stringWithFormat:@"%d:%02d", m, s];
  return [NSString stringWithFormat:@"%ds", s];
}

- (void)_renderRulerWithTrackX:(CGFloat)trackX
                    trackWidth:(CGFloat)trackWidth
                   totalHeight:(CGFloat)totalHeight {
  if (self.effectDuration <= 0 || trackWidth < 10)
    return;

  CGFloat rulerY = totalHeight - kKSSBorderInset - kKSSRulerHeight;

  CGFloat pps = trackWidth * _zoom / self.effectDuration;
  double interval = _tickIntervalForPixelsPerSecond(pps);

  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName : [NSColor timelineLabel],
  };

  [[NSColor colorWithWhite:0.8 alpha:0.15] setStroke];
  NSBezierPath *ticks = [NSBezierPath bezierPath];
  ticks.lineWidth = 1.0;

  double visStart = _panOffset * self.effectDuration;
  double tStart = floor(visStart / interval) * interval;
  double visEnd = (_panOffset + 1.0 / _zoom) * self.effectDuration;

  for (double t = tStart; t <= visEnd + 0.001; t += interval) {
    if (t < 0)
      continue;
    double frac = (self.effectDuration > 0) ? t / self.effectDuration : 0;
    CGFloat x = [self _xForFrac:frac trackX:trackX trackWidth:trackWidth];
    if (x < trackX || x > trackX + trackWidth)
      continue;

    [ticks moveToPoint:NSMakePoint(x, rulerY)];
    [ticks lineToPoint:NSMakePoint(x, rulerY + kKSSRulerHeight)];

    NSString *label = _timecodeLabel(t);
    NSSize labelSize = [label sizeWithAttributes:attrs];
    CGFloat labelX = x + 3;
    if (labelX + labelSize.width <= trackX + trackWidth) {
      CGFloat labelY = rulerY + (kKSSRulerHeight - labelSize.height) / 2.0;
      [label drawAtPoint:NSMakePoint(labelX, labelY) withAttributes:attrs];
    }
  }

  [ticks stroke];
}

/// Draws the slider-style knob (point down) at a given center-x and top-y.
/// Flat edge at topY, point extends downward (lower Y = visually down in
/// unflipped NSImage coords where Y=0 is bottom).
static void _drawPlayheadKnob(CGFloat cx, CGFloat topY, NSColor *color) {
  static const CGFloat w = 9.5;
  static const CGFloat h = 10.0;
  static const CGFloat cr = 1.5;
  static const CGFloat pointRatio = 0.5;
  static const CGFloat curveOff = 0.5;
  static const CGFloat curveCtl = 1.0;
  static const CGFloat sideRatio = 0.3;

  CGFloat left = cx - w / 2.0;
  CGFloat right = cx + w / 2.0;
  CGFloat top = topY;
  CGFloat bottom = topY - h;
  CGFloat midX = cx;
  CGFloat pointH = h * pointRatio;
  CGFloat pointBaseY = top - (h - pointH);

  NSBezierPath *path = [NSBezierPath bezierPath];

  [path moveToPoint:NSMakePoint(left + cr, top)];
  [path lineToPoint:NSMakePoint(right - cr, top)];
  [path appendBezierPathWithArcFromPoint:NSMakePoint(right, top)
                                 toPoint:NSMakePoint(right, top - cr)
                                  radius:cr];
  [path lineToPoint:NSMakePoint(right, pointBaseY)];
  [path curveToPoint:NSMakePoint(midX, bottom)
       controlPoint1:NSMakePoint(right - curveOff,
                                 pointBaseY - pointH * sideRatio)
       controlPoint2:NSMakePoint(midX + curveCtl, bottom + curveOff)];
  [path curveToPoint:NSMakePoint(left, pointBaseY)
       controlPoint1:NSMakePoint(midX - curveCtl, bottom + curveOff)
       controlPoint2:NSMakePoint(left + curveOff,
                                 pointBaseY - pointH * sideRatio)];
  [path lineToPoint:NSMakePoint(left, top - cr)];
  [path appendBezierPathWithArcFromPoint:NSMakePoint(left, top)
                                 toPoint:NSMakePoint(left + cr, top)
                                  radius:cr];
  [path closePath];

  [color setFill];
  [path fill];
  [[NSColor colorWithWhite:0.08 alpha:1.0] setStroke];
  path.lineWidth = 0.5;
  [path stroke];
}

- (void)_renderSnapGuideWithTrackX:(CGFloat)trackX
                        trackWidth:(CGFloat)trackWidth
                       totalHeight:(CGFloat)totalHeight {
  if (!_snapActive || trackWidth < 1)
    return;
  CGFloat x = [self _xForFrac:_snapFrac trackX:trackX trackWidth:trackWidth];
  if (x < trackX - 0.5 || x > trackX + trackWidth + 0.5)
    return;
  CGFloat cx = floor(x) + 0.5;
  CGFloat top = totalHeight - kKSSBorderInset - kKSSRulerHeight;
  CGFloat bottom = kKSSBorderInset;

  [[NSColor colorWithRed:1.0 green:1.0 blue:0.0 alpha:1.0] setStroke];
  NSBezierPath *line = [NSBezierPath bezierPath];
  line.lineWidth = 1.0;
  [line moveToPoint:NSMakePoint(cx, bottom)];
  [line lineToPoint:NSMakePoint(cx, top)];
  [line stroke];
}

- (void)_renderPlayheadWithTrackX:(CGFloat)trackX
                       trackWidth:(CGFloat)trackWidth
                      totalHeight:(CGFloat)totalHeight {
  if (self.playheadFraction < 0 || self.playheadFraction > 1 || trackWidth < 1)
    return;

  NSColor *playheadColor = [NSColor colorWithWhite:0.8 alpha:1.0];
  CGFloat x = [self _xForFrac:self.playheadFraction
                       trackX:trackX
                   trackWidth:trackWidth];
  CGFloat lanesBottom = kKSSBorderInset;
  CGFloat rulerTop = totalHeight - kKSSBorderInset;

  [playheadColor setStroke];
  NSBezierPath *line = [NSBezierPath bezierPath];
  line.lineWidth = 1.0;
  [line moveToPoint:NSMakePoint(x, lanesBottom)];
  [line lineToPoint:NSMakePoint(x, rulerTop)];
  [line stroke];

  _drawPlayheadKnob(x, rulerTop, playheadColor);
}

@end
#pragma clang diagnostic pop
