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

  [self _renderEditButtonForHoveredSegment];

  [self _renderSnapGuideWithTrackX:trackX
                        trackWidth:trackWidth
                       totalHeight:totalHeight];
  // Playhead (line + knob) is rendered by KKStagePlayheadView overlay.

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

/// Returns average of a boundary's values (so the lane graph collapses
/// multi-value properties to a single plotted series).
static double _boundaryAvg(NSArray<NSNumber *> *values) {
  if (!values.count)
    return 0;
  double sum = 0;
  for (NSNumber *v in values)
    sum += v.doubleValue;
  return sum / values.count;
}

static void _laneGraphFromTo(NSArray<KKTimingSegment *> *segments,
                             NSUInteger idx, double *outFrom, double *outTo) {
  *outFrom = _boundaryAvg(KKTimingBoundaryBefore(idx, segments));
  *outTo = _boundaryAvg(KKTimingBoundaryAfter(idx, segments));
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

  // Compute dynamic value range including transition overshoots (Elastic,
  // Bounce etc. exceed [from, to]).
  double minVal = 0, maxVal = 0;
  for (KKTimingSegment *seg in lane.segments) {
    double v = _segAvgValue(seg);
    if (v < minVal)
      minVal = v;
    if (v > maxVal)
      maxVal = v;
  }
  for (NSUInteger i = 0; i < lane.segments.count; i++) {
    KKTimingSegment *s = lane.segments[i];
    if (s.type == KKSegmentTypeTransition) {
      double from = 0, to = 0;
      _laneGraphFromTo(lane.segments, i, &from, &to);
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
      double base = _segAvgValue(s);
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
  double valRange = maxVal - minVal;
  if (valRange < 0.001) {
    maxVal = 1.0;
    minVal = 0.0;
    valRange = 1.0;
  }
  double (^normalize)(double) = ^(double v) {
    return (v - minVal) / valRange;
  };

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
      CGFloat x0 = segLeft;
      CGFloat x1 = segLeft + segWidth;
      double base = _segAvgValue(seg);
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
      _laneGraphFromTo(lane.segments, segIdx, &fromVal, &toVal);
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
    if (bx < trackX - 0.5 || bx > trackX + trackWidth + 0.5)
      continue;
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

- (NSRect)_editButtonRectForLaneIndex:(NSUInteger)laneIdx
                         segmentIndex:(NSUInteger)segIdx
                               trackX:(CGFloat)trackX
                           trackWidth:(CGFloat)trackWidth
                          totalHeight:(CGFloat)totalHeight {
  if (laneIdx >= self.lanes.count)
    return NSZeroRect;
  KKTimingLane *lane = self.lanes[laneIdx];
  if (segIdx >= lane.segments.count)
    return NSZeroRect;
  KKTimingSegment *seg = lane.segments[segIdx];
  CGFloat segX = [self _xForFrac:seg.start trackX:trackX trackWidth:trackWidth];
  CGFloat segW = (seg.end - seg.start) * trackWidth * _zoom;
  if (segW < kKSSEditMinSegmentPx)
    return NSZeroRect;
  CGFloat laneY = [self _laneYForIndex:laneIdx totalHeight:totalHeight];
  // Center on the segment but clamp the button's X so it stays visible when
  // the segment extends past the visible track (same pattern as the duration
  // label below).
  CGFloat btnLeft = segX + segW / 2.0 - kKSSEditButtonSize / 2.0;
  btnLeft = MAX(trackX, MIN(trackX + trackWidth - kKSSEditButtonSize, btnLeft));
  // Keep the button inside the segment's visible span so it doesn't stick
  // past segment edges (otherwise a partially-visible segment could push
  // the button into an adjacent segment).
  CGFloat segVisLeft = MAX(segX, trackX);
  CGFloat segVisRight = MIN(segX + segW, trackX + trackWidth);
  btnLeft = MAX(segVisLeft, MIN(segVisRight - kKSSEditButtonSize, btnLeft));
  CGFloat cy = laneY + kKSSLaneHeight / 2.0;
  return NSMakeRect(btnLeft, cy - kKSSEditButtonSize / 2.0, kKSSEditButtonSize,
                    kKSSEditButtonSize);
}

- (void)_renderEditButtonForHoveredSegment {
  if (_hoverSegLaneIdx < 0 || _hoverSegSegIdx < 0)
    return;
  if ((NSUInteger)_hoverSegLaneIdx >= self.lanes.count)
    return;
  KKTimingLane *lane = self.lanes[_hoverSegLaneIdx];
  if (!lane.enabled)
    return;
  if ((NSUInteger)_hoverSegSegIdx >= lane.segments.count)
    return;
  KKTimingSegment *seg = lane.segments[_hoverSegSegIdx];

  CGFloat totalWidth = NSWidth(self.bounds);
  CGFloat totalHeight = [self _totalHeight];
  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:totalWidth
                        trackX:&trackX
                    trackWidth:&trackWidth];
  NSRect btn = [self _editButtonRectForLaneIndex:_hoverSegLaneIdx
                                    segmentIndex:_hoverSegSegIdx
                                          trackX:trackX
                                      trackWidth:trackWidth
                                     totalHeight:totalHeight];
  if (NSIsEmptyRect(btn))
    return;

  NSColor *segColor = (seg.type == KKSegmentTypeHold)
                          ? [NSColor accentMatchingHost]
                          : [NSColor warning];

  [[segColor colorWithAlphaComponent:0.25] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:btn
                                   xRadius:KKRadiusSM
                                   yRadius:KKRadiusSM] fill];

  NSImage *icon = [NSImage imageWithSystemSymbolName:@"graph.2d"
                            accessibilityDescription:@"Edit curve"];
  if (!icon)
    return;
  NSImageSymbolConfiguration *size = [NSImageSymbolConfiguration
      configurationWithPointSize:11.0
                          weight:NSFontWeightSemibold];
  NSImageSymbolConfiguration *tinted =
      [NSImageSymbolConfiguration configurationWithPaletteColors:@[ segColor ]];
  icon = [icon imageWithSymbolConfiguration:
                   [size configurationByApplyingConfiguration:tinted]];

  NSRect iconRect = NSInsetRect(btn, 2.0, 2.0);
  [icon drawInRect:iconRect
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
               hints:nil];
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
  CGFloat top = totalHeight;
  CGFloat bottom = kKSSBorderInset;

  [[NSColor colorWithRed:1.0 green:1.0 blue:0.0 alpha:1.0] setStroke];
  NSBezierPath *line = [NSBezierPath bezierPath];
  line.lineWidth = 1.0;
  [line moveToPoint:NSMakePoint(cx, bottom)];
  [line lineToPoint:NSMakePoint(cx, top)];
  [line stroke];
}

@end
#pragma clang diagnostic pop
