/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Math/KKEasing.h"
#import "../Math/KKGradientSampling.h"
#import "../Style/NSColor+KKColors.h"
#import "KKAnimatableProperty.h"
#import "KKGradientBarView.h"
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

    [self _renderLaneLabel:lane laneY:laneY];

    if (trackWidth < 1)
      continue;

    [self _renderSegmentFillsForLane:lane
                           laneIndex:laneIdx
                              trackX:trackX
                          trackWidth:trackWidth
                               laneY:laneY];

    if (lane.enabled && trackWidth > 10) {
      NSNumber *kindNum = self.laneKindsByLabel[lane.propertyLabel];
      BOOL isColorLike =
          (kindNum.integerValue == KKAnimatableParamKindColor ||
           kindNum.integerValue == KKAnimatableParamKindGradient);
      if (isColorLike) {
        [self
            _renderColorLaneForLane:lane
                               kind:(KKAnimatableParamKind)kindNum.integerValue
                             trackX:trackX
                         trackWidth:trackWidth
                              laneY:laneY];
      } else {
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
    }

    [self _renderEdgeHoverForLane:lane
                        laneIndex:laneIdx
                           trackX:trackX
                       trackWidth:trackWidth
                            laneY:laneY];
  }

  [self _renderEditButtonForHoveredSegment];

  [self _renderValueCopyDropTargetWithTrackX:trackX
                                  trackWidth:trackWidth
                                 totalHeight:totalHeight];

  [self _renderSnapGuideWithTrackX:trackX
                        trackWidth:trackWidth
                       totalHeight:totalHeight];
  // Playhead (line + knob) is rendered by KKStagePlayheadView overlay.

  [image unlockFocus];
  _lanesImage = image;
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  if (_lanesImage)
    [_lanesImage drawInRect:self.bounds
                   fromRect:NSZeroRect
                  operation:NSCompositingOperationSourceOver
                   fraction:1.0];
}

- (void)_renderLaneLabel:(KKTimingLane *)lane laneY:(CGFloat)laneY {
  NSColor *contentColor =
      lane.enabled ? [NSColor inspectorLabel]
                   : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  CGFloat laneH = [self _laneHeight];
  CGFloat iconSlotLeft = kKSSBorderInset + kKSSLabelPadding;

  if (lane.hasOSC) {
    NSString *name = lane.oscVisible ? @"arcade.stick.console.fill"
                                     : @"arcade.stick.console";
    NSImage *symbol = [NSImage imageWithSystemSymbolName:name
                                accessibilityDescription:nil];
    if (symbol) {
      NSImageSymbolConfiguration *sizeCfg = [NSImageSymbolConfiguration
          configurationWithPointSize:kKSSOSCIconSize
                              weight:NSFontWeightRegular];
      NSImageSymbolConfiguration *colorCfg = [NSImageSymbolConfiguration
          configurationWithPaletteColors:@[ contentColor ]];
      NSImage *icon =
          [symbol imageWithSymbolConfiguration:
                      [sizeCfg configurationByApplyingConfiguration:colorCfg]];
      NSRect iconRect =
          NSMakeRect(iconSlotLeft + (kKSSOSCIconSize - icon.size.width) / 2.0,
                     laneY + (laneH - icon.size.height) / 2.0, icon.size.width,
                     icon.size.height);
      [icon drawInRect:iconRect];
    }
  }

  CGFloat labelLeft = iconSlotLeft + kKSSOSCIconSize + kKSSOSCIconGap;
  NSDictionary *labelAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName : contentColor,
  };
  NSSize labelSize = [lane.propertyLabel sizeWithAttributes:labelAttrs];
  NSPoint labelPoint =
      NSMakePoint(labelLeft, laneY + (laneH - labelSize.height) / 2.0);
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
  [line lineToPoint:NSMakePoint(edgeX, laneY + [self _laneHeight] - 2)];
  line.lineWidth = 2.0;
  [line stroke];
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
    // Generic N-component fallback: linear ramp 0.8 → 0.3.
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
  CGFloat cy = laneY + [self _laneHeight] / 2.0;
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

- (void)_renderValueCopyDropTargetWithTrackX:(CGFloat)trackX
                                  trackWidth:(CGFloat)trackWidth
                                 totalHeight:(CGFloat)totalHeight {
  if (!_dragValueCopying || _dragCopyDstSegIdx < 0 ||
      (NSUInteger)_dragCopyLaneIdx >= self.lanes.count)
    return;
  KKTimingLane *lane = self.lanes[_dragCopyLaneIdx];
  if ((NSUInteger)_dragCopyDstSegIdx >= lane.segments.count)
    return;
  KKTimingSegment *dst = lane.segments[_dragCopyDstSegIdx];
  CGFloat laneY = [self _laneYForIndex:(NSUInteger)_dragCopyLaneIdx
                           totalHeight:totalHeight];
  CGFloat xL = [self _xForFrac:dst.start trackX:trackX trackWidth:trackWidth];
  CGFloat xR = [self _xForFrac:dst.end trackX:trackX trackWidth:trackWidth];
  NSRect r =
      NSInsetRect(NSMakeRect(xL, laneY, xR - xL, [self _laneHeight]), 1.5, 1.5);
  NSBezierPath *p =
      [NSBezierPath bezierPathWithRoundedRect:r
                                      xRadius:kKSSSegmentCornerRadius
                                      yRadius:kKSSSegmentCornerRadius];
  [[NSColor whiteColor] setStroke];
  p.lineWidth = 2.0;
  [p stroke];
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

/// Build stops for a flat gradient array. For Color kind (3 floats = R,G,B)
/// synthesize a two-stop single-color gradient so the strip renders solid.
static NSArray<KKGradientStop *> *_stopsFromValues(NSArray<NSNumber *> *values,
                                                   KKAnimatableParamKind kind) {
  if (kind == KKAnimatableParamKindGradient)
    return KKGradientStopsFromFlat(values);
  if (kind == KKAnimatableParamKindColor && values.count >= 3) {
    NSColor *c = [NSColor colorWithRed:values[0].doubleValue
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

    // --- Color strip at top of the segment rect ---
    // Both hold and transition draw the segment's own stored values, so a
    // transition shows the *target* color/gradient assigned to it (what
    // the segment represents) rather than the morph between its boundaries.
    NSArray<KKGradientStop *> *stops = _stopsFromValues(seg.values, kind);
    if (stops.count >= 2) {
      int lutN = 64;
      simd_float3 *lut =
          (simd_float3 *)malloc(sizeof(simd_float3) * (size_t)lutN);
      KKGradientSampleStopsToLUT(stops, lut, lutN);
      // Snap stripe edges to the integer pixel grid so adjacent rects share
      // exact boundaries — otherwise subpixel-positioned NSRectFills leave
      // faint vertical seams that read as "sampling lines".
      for (int i = 0; i < lutN; i++) {
        CGFloat x0 = round(stripX + (CGFloat)i / (CGFloat)lutN * innerW);
        CGFloat x1 = round(stripX + (CGFloat)(i + 1) / (CGFloat)lutN * innerW);
        if (x1 <= x0)
          continue;
        simd_float3 c = lut[i];
        [[NSColor colorWithRed:c.x green:c.y blue:c.z alpha:1.0] setFill];
        NSRectFill(NSMakeRect(x0, stripY, x1 - x0, stripH));
      }
      free(lut);
    }

    // --- Easing curve line over the segment (below the strip) ---
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
        double v;
        if (seg.type == KKSegmentTypeHold) {
          if (seg.holdEffect == KKHoldEffectNone) {
            v = 1.0; // rest
          } else {
            v = KKApplyHoldEffect(t, seg.holdEffect, seg.intensity,
                                  seg.frequency, (int)seg.seed);
          }
        } else {
          double e = KKApplyEasing(t, seg.easing, seg.intensity, seg.frequency);
          // Animate-out descends (top → bottom), animate-in/mid rises
          // (bottom → top). Gives a visually distinct silhouette for the
          // last-segment case instead of mirroring to the same shape.
          v = isAnimateOut ? (1.0 - e) : e;
        }
        double y01 = (v - minVal) / valRange;
        CGFloat x = stripX + (CGFloat)t * innerW;
        CGFloat y = curveBottom + (CGFloat)y01 * (curveTop - curveBottom);
        if (i == 0)
          [path moveToPoint:NSMakePoint(x, y)];
        else
          [path lineToPoint:NSMakePoint(x, y)];
      }
      [path stroke];
    }
  }
}

@end
#pragma clang diagnostic pop
