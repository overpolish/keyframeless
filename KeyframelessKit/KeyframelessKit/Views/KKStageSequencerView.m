/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKStageSequencerView.h"
#import "../Math/KKEasing.h"
#import "../Math/KKTimingStage.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"

static const CGFloat kRulerHeight = 10.0;
static const CGFloat kPlayheadSnapPx = 10.0;
static const CGFloat kBoundaryLabelHeight = 10.0;
static const CGFloat kLaneHeight = 30.0;
static const CGFloat kLaneSpacing = KKSpacingXS;
static const CGFloat kLabelWidth = 50.0;
static const CGFloat kLabelPadding = KKSpacingSM;
static const CGFloat kSegmentCornerRadius = KKRadiusSM;
static const CGFloat kCurvePadding = 3.0;
static const CGFloat kBorderInset = KKPaddingSM;
static const CGFloat kEdgeHitZone = 5.0;
static const CGFloat kMinSegmentFrac = 0.04;
static const CGFloat kMinSegmentPx = 12.0;
static const NSInteger kCurveSegments = 40;

@implementation KKStageSequencerView {
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
}

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.wantsLayer = YES;
    self.layer.masksToBounds = YES;
    self.layer.cornerRadius = KKSpacingMD;
    self.layer.borderWidth = KKBorderWidthXS;
    self.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.05].CGColor;

    _hoverLaneIdx = -1;
    _hoverSegIdx = -1;
    _hoverSegLaneIdx = -1;
    _hoverSegSegIdx = -1;

    NSTrackingArea *trackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                     NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:trackingArea];
  }
  return self;
}

- (void)setLanes:(NSArray<KKTimingLane *> *)lanes {
  _lanes = [lanes copy];
  if (!_dragging && !_dragMoving)
    [self renderLanes];
}

- (void)setEffectDuration:(double)effectDuration {
  if (fabs(_effectDuration - effectDuration) < 0.001)
    return;
  _effectDuration = effectDuration;
  [self renderLanes];
}

- (void)setPlayheadFraction:(double)playheadFraction {
  if (fabs(_playheadFraction - playheadFraction) < 0.0001)
    return;
  _playheadFraction = playheadFraction;
  [self renderLanes];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self renderLanes];
}

#pragma mark - Coordinate helpers

- (void)_trackGeometryForWidth:(CGFloat)viewWidth
                        trackX:(CGFloat *)outTrackX
                    trackWidth:(CGFloat *)outTrackWidth {
  *outTrackX = kBorderInset + kLabelWidth;
  *outTrackWidth = viewWidth - 2 * kBorderInset - kLabelWidth - kLabelPadding;
}

- (CGFloat)_laneYForIndex:(NSUInteger)laneIdx totalHeight:(CGFloat)totalHeight {
  return totalHeight - kBorderInset - kRulerHeight -
         (laneIdx + 1) * (kLaneHeight + kBoundaryLabelHeight) -
         laneIdx * kLaneSpacing;
}

- (CGFloat)_totalHeight {
  return kRulerHeight + kBoundaryLabelHeight +
         _lanes.count * (kLaneHeight + kBoundaryLabelHeight) +
         (_lanes.count - 1) * kLaneSpacing + 2 * kBorderInset;
}

#pragma mark - Rendering

- (void)renderLanes {
  CGFloat totalWidth = NSWidth(self.bounds);
  if (totalWidth < 1 || !_lanes.count)
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

  for (NSUInteger laneIdx = 0; laneIdx < _lanes.count; laneIdx++) {
    KKTimingLane *lane = _lanes[laneIdx];
    CGFloat laneY = [self _laneYForIndex:laneIdx totalHeight:totalHeight];

    NSRect laneRect = NSMakeRect(kBorderInset, laneY,
                                 imageWidth - 2 * kBorderInset, kLaneHeight);
    [[NSColor inspectorBackground] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:laneRect
                                     xRadius:KKRadiusMD
                                     yRadius:KKRadiusMD] fill];

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
        NSMakePoint(kBorderInset + kLabelPadding,
                    laneY + (kLaneHeight - labelSize.height) / 2.0);
    [lane.propertyLabel drawAtPoint:labelPoint withAttributes:labelAttrs];

    if (trackWidth < 1)
      continue;

    // Selection fills per segment.
    for (NSUInteger segIdx = 0; segIdx < lane.segments.count; segIdx++) {
      KKTimingSegment *seg = lane.segments[segIdx];
      CGFloat segX = trackX + seg.start * trackWidth;
      CGFloat segW = (seg.end - seg.start) * trackWidth;
      if (segW < 1)
        continue;

      NSRect segRect = NSMakeRect(segX, laneY + 2, segW, kLaneHeight - 4);
      BOOL isSelected =
          (lane.enabled && lane.selectedSegment == (NSInteger)segIdx);
      BOOL isHovered =
          (lane.enabled && _hoverSegLaneIdx == (NSInteger)laneIdx &&
           _hoverSegSegIdx == (NSInteger)segIdx && !isSelected);

      NSColor *segColor = (seg.type == KKSegmentTypeHold)
                              ? [NSColor accentMatchingHost]
                              : [NSColor warning];
      NSBezierPath *segPath =
          [NSBezierPath bezierPathWithRoundedRect:segRect
                                          xRadius:kSegmentCornerRadius
                                          yRadius:kSegmentCornerRadius];
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

    // Continuous graph line across the whole lane.
    if (lane.enabled && trackWidth > 10)
      [self _renderLaneGraph:lane
                      trackX:trackX
                  trackWidth:trackWidth
                       laneY:laneY];

    // Boundary time labels below the lane.
    if (lane.enabled && trackWidth > 10)
      [self _renderBoundaryLabelsForLane:lane
                               laneIndex:laneIdx
                                  trackX:trackX
                              trackWidth:trackWidth
                                   laneY:laneY];

    // Hover indicator line on boundary.
    if (_hoveringEdge && _hoverLaneIdx == (NSInteger)laneIdx && lane.enabled) {
      CGFloat edgeX;
      if (_hoverLeading && _hoverSegIdx >= 0 &&
          (NSUInteger)_hoverSegIdx < lane.segments.count) {
        edgeX = trackX + lane.segments[_hoverSegIdx].start * trackWidth;
      } else if (!_hoverLeading && _hoverSegIdx >= 0 &&
                 (NSUInteger)_hoverSegIdx < lane.segments.count) {
        edgeX = trackX + lane.segments[_hoverSegIdx].end * trackWidth;
      } else {
        edgeX = -1;
      }
      if (edgeX >= 0) {
        [[NSColor accentMatchingHost] setStroke];
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(edgeX, laneY + 2)];
        [line lineToPoint:NSMakePoint(edgeX, laneY + kLaneHeight - 2)];
        line.lineWidth = 2.0;
        [line stroke];
      }
    }
  }

  [self _renderRulerWithTrackX:trackX
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

/// Average of all values in a segment (for multi-value properties).
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
  CGFloat pad = kCurvePadding;
  CGFloat drawBottom = laneY + 2 + pad;
  CGFloat drawHeight = kLaneHeight - 4 - 2 * pad;
  if (drawHeight < 2)
    return;

  // Find max value for normalization.
  double maxVal = 0;
  for (KKTimingSegment *seg in lane.segments) {
    double v = fabs(_segAvgValue(seg));
    if (v > maxVal)
      maxVal = v;
  }
  if (maxVal < 0.001)
    maxVal = 1.0;

  // Build per-segment paths with type-specific colors.
  NSPoint lastPoint = NSZeroPoint;
  BOOL hasLast = NO;

  for (NSUInteger segIdx = 0; segIdx < lane.segments.count; segIdx++) {
    KKTimingSegment *seg = lane.segments[segIdx];
    CGFloat segLeft = trackX + seg.start * trackWidth;
    CGFloat segWidth = (seg.end - seg.start) * trackWidth;
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
        // Connect from previous segment end.
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

      for (NSInteger i = 0; i <= kCurveSegments; i++) {
        double t = (double)i / (double)kCurveSegments;
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
        if (i == kCurveSegments)
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
  if (_effectDuration <= 0)
    return;

  CGFloat labelRowY = laneY - kBoundaryLabelHeight;

  NSDictionary *dimAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:8.0
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName :
        [[NSColor inspectorLabel] colorWithAlphaComponent:0.35],
  };

  // Pre-compute duration label rect so boundary labels can avoid it.
  CGFloat durLabelLeft = -999, durLabelRight = -999;
  BOOL isHovered =
      (_hoverSegLaneIdx == (NSInteger)laneIdx && _hoverSegSegIdx >= 0 &&
       (NSUInteger)_hoverSegSegIdx < lane.segments.count);
  NSString *durLabel = nil;
  NSDictionary *durAttrs = nil;
  CGFloat durX = 0, durY = 0;

  if (isHovered) {
    KKTimingSegment *hSeg = lane.segments[_hoverSegSegIdx];
    double durSec = (hSeg.end - hSeg.start) * _effectDuration;
    if (durSec < 10.0)
      durLabel = [NSString stringWithFormat:@"%.1fs", durSec];
    else
      durLabel = [NSString stringWithFormat:@"%.0fs", durSec];

    durAttrs = @{
      NSFontAttributeName : [NSFont systemFontOfSize:8.0
                                              weight:NSFontWeightMedium],
      NSForegroundColorAttributeName : [NSColor accentMatchingHost],
    };
    NSSize durSize = [durLabel sizeWithAttributes:durAttrs];
    CGFloat segMidX = trackX + ((hSeg.start + hSeg.end) / 2.0) * trackWidth;
    durX = segMidX - durSize.width / 2.0;
    durX = MAX(trackX, MIN(trackX + trackWidth - durSize.width, durX));
    durY = labelRowY + (kBoundaryLabelHeight - durSize.height) / 2.0;
    durLabelLeft = durX;
    durLabelRight = durX + durSize.width;
  }

  // Collect boundary positions (unique, sorted).
  NSMutableArray<NSNumber *> *boundaries = [NSMutableArray array];
  for (KKTimingSegment *seg in lane.segments) {
    [boundaries addObject:@(seg.start)];
  }
  KKTimingSegment *last = lane.segments.lastObject;
  if (last)
    [boundaries addObject:@(last.end)];

  // Draw boundary labels, skipping overlaps with each other and duration label.
  CGFloat lastLabelRight = -999;
  static const CGFloat kLabelGap = 4.0;

  for (NSNumber *bNum in boundaries) {
    double frac = bNum.doubleValue;
    CGFloat bx = trackX + frac * trackWidth;
    NSString *label = _boundaryTimeLabel(frac, _effectDuration);
    NSSize labelSize = [label sizeWithAttributes:dimAttrs];
    CGFloat labelX = bx - labelSize.width / 2.0;
    labelX = MAX(trackX, MIN(trackX + trackWidth - labelSize.width, labelX));

    if (labelX < lastLabelRight + kLabelGap)
      continue;

    // Skip if this boundary label overlaps the hover duration label.
    if (isHovered && labelX + labelSize.width + kLabelGap > durLabelLeft &&
        labelX < durLabelRight + kLabelGap)
      continue;

    CGFloat labelY =
        labelRowY + (kBoundaryLabelHeight - labelSize.height) / 2.0;
    [label drawAtPoint:NSMakePoint(labelX, labelY) withAttributes:dimAttrs];
    lastLabelRight = labelX + labelSize.width;
  }

  // Draw the hover duration label on top.
  if (isHovered && durLabel)
    [durLabel drawAtPoint:NSMakePoint(durX, durY) withAttributes:durAttrs];
}

- (double)_tickIntervalForPixelsPerSecond:(CGFloat)pps {
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
  if (_effectDuration <= 0 || trackWidth < 10)
    return;

  CGFloat rulerY = totalHeight - kBorderInset - kRulerHeight;

  CGFloat pps = trackWidth / _effectDuration;
  double interval = [self _tickIntervalForPixelsPerSecond:pps];

  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName : [NSColor timelineLabel],
  };

  [[NSColor colorWithWhite:0.8 alpha:0.15] setStroke];
  NSBezierPath *ticks = [NSBezierPath bezierPath];
  ticks.lineWidth = 1.0;

  double t = 0.0;
  while (t <= _effectDuration + 0.001) {
    CGFloat x = trackX + (t / _effectDuration) * trackWidth;
    x = MAX(trackX, MIN(trackX + trackWidth, x));

    [ticks moveToPoint:NSMakePoint(x, rulerY)];
    [ticks lineToPoint:NSMakePoint(x, rulerY + kRulerHeight)];

    NSString *label = _timecodeLabel(t);
    NSSize labelSize = [label sizeWithAttributes:attrs];
    CGFloat labelX = x + 3;
    if (labelX + labelSize.width <= trackX + trackWidth) {
      CGFloat labelY = rulerY + (kRulerHeight - labelSize.height) / 2.0;
      [label drawAtPoint:NSMakePoint(labelX, labelY) withAttributes:attrs];
    }

    t += interval;
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

  // Flat top edge with rounded corners.
  [path moveToPoint:NSMakePoint(left + cr, top)];
  [path lineToPoint:NSMakePoint(right - cr, top)];
  [path appendBezierPathWithArcFromPoint:NSMakePoint(right, top)
                                 toPoint:NSMakePoint(right, top - cr)
                                  radius:cr];
  // Right side down to point base.
  [path lineToPoint:NSMakePoint(right, pointBaseY)];
  // Curve to point (bottom center).
  [path curveToPoint:NSMakePoint(midX, bottom)
       controlPoint1:NSMakePoint(right - curveOff,
                                 pointBaseY - pointH * sideRatio)
       controlPoint2:NSMakePoint(midX + curveCtl, bottom + curveOff)];
  // Curve back up left side.
  [path curveToPoint:NSMakePoint(left, pointBaseY)
       controlPoint1:NSMakePoint(midX - curveCtl, bottom + curveOff)
       controlPoint2:NSMakePoint(left + curveOff,
                                 pointBaseY - pointH * sideRatio)];
  // Left side up to top-left corner.
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

- (void)_renderPlayheadWithTrackX:(CGFloat)trackX
                       trackWidth:(CGFloat)trackWidth
                      totalHeight:(CGFloat)totalHeight {
  if (_playheadFraction < 0 || _playheadFraction > 1 || trackWidth < 1)
    return;

  NSColor *playheadColor = [NSColor colorWithWhite:0.8 alpha:1.0];
  CGFloat x = trackX + _playheadFraction * trackWidth;
  CGFloat lanesBottom = kBorderInset;
  CGFloat rulerTop = totalHeight - kBorderInset;

  [playheadColor setStroke];
  NSBezierPath *line = [NSBezierPath bezierPath];
  line.lineWidth = 1.0;
  [line moveToPoint:NSMakePoint(x, lanesBottom)];
  [line lineToPoint:NSMakePoint(x, rulerTop)];
  [line stroke];

  // Knob in ruler area, flat edge at ruler top, point down into lanes.
  _drawPlayheadKnob(x, rulerTop, playheadColor);
}

#pragma mark - Mouse interaction

- (BOOL)_hitTestEdgeAtPoint:(NSPoint)loc
                    laneIdx:(NSInteger *)outLane
                     segIdx:(NSInteger *)outSeg
                    leading:(BOOL *)outLeading {
  CGFloat totalWidth = NSWidth(self.bounds);
  CGFloat totalHeight = [self _totalHeight];
  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:totalWidth
                        trackX:&trackX
                    trackWidth:&trackWidth];

  for (NSUInteger laneIdx = 0; laneIdx < _lanes.count; laneIdx++) {
    KKTimingLane *lane = _lanes[laneIdx];
    if (!lane.enabled)
      continue;
    CGFloat laneY = [self _laneYForIndex:laneIdx totalHeight:totalHeight];
    if (loc.y < laneY || loc.y > laneY + kLaneHeight)
      continue;
    if (loc.x < kBorderInset + kLabelWidth)
      return NO;

    for (NSUInteger segIdx = 0; segIdx < lane.segments.count; segIdx++) {
      KKTimingSegment *seg = lane.segments[segIdx];
      CGFloat segLeft = trackX + seg.start * trackWidth;
      CGFloat segRight = trackX + seg.end * trackWidth;

      if (segIdx > 0 && fabs(loc.x - segLeft) < kEdgeHitZone) {
        *outLane = laneIdx;
        *outSeg = segIdx;
        *outLeading = YES;
        return YES;
      }
      if (segIdx < lane.segments.count - 1 &&
          fabs(loc.x - segRight) < kEdgeHitZone) {
        *outLane = laneIdx;
        *outSeg = segIdx;
        *outLeading = NO;
        return YES;
      }
    }
    return NO;
  }
  return NO;
}

- (void)mouseMoved:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger lane = -1, seg = -1;
  BOOL leading = NO;
  BOOL onEdge = [self _hitTestEdgeAtPoint:loc
                                  laneIdx:&lane
                                   segIdx:&seg
                                  leading:&leading];
  // Track which segment the cursor is over for hover highlight.
  NSInteger hovSegLane = -1, hovSegSeg = -1;
  if (!onEdge) {
    CGFloat totalWidth2 = NSWidth(self.bounds);
    CGFloat totalHeight2 = [self _totalHeight];
    CGFloat tX, tW;
    [self _trackGeometryForWidth:totalWidth2 trackX:&tX trackWidth:&tW];
    for (NSUInteger li = 0; li < _lanes.count; li++) {
      KKTimingLane *l = _lanes[li];
      if (!l.enabled)
        continue;
      CGFloat ly = [self _laneYForIndex:li totalHeight:totalHeight2];
      if (loc.y < ly || loc.y > ly + kLaneHeight)
        continue;
      if (loc.x < kBorderInset + kLabelWidth)
        break;
      for (NSUInteger si = 0; si < l.segments.count; si++) {
        CGFloat sL = tX + l.segments[si].start * tW;
        CGFloat sR = tX + l.segments[si].end * tW;
        if (loc.x >= sL && loc.x <= sR) {
          hovSegLane = li;
          hovSegSeg = si;
          break;
        }
      }
      break;
    }
  }

  BOOL changed = (onEdge != _hoveringEdge || lane != _hoverLaneIdx ||
                  seg != _hoverSegIdx || hovSegLane != _hoverSegLaneIdx ||
                  hovSegSeg != _hoverSegSegIdx);
  _hoveringEdge = onEdge;
  _hoverLaneIdx = lane;
  _hoverSegIdx = seg;
  _hoverLeading = leading;
  _hoverSegLaneIdx = hovSegLane;
  _hoverSegSegIdx = hovSegSeg;

  if (onEdge) {
    [[NSCursor resizeLeftRightCursor] set];
  } else if (event.modifierFlags & NSEventModifierFlagCommand) {
    // Show delete cursor if Cmd is held and we're over a removable segment.
    BOOL canDelete = [self _canDeleteAtPoint:loc];
    if (canDelete)
      [[NSCursor disappearingItemCursor] set];
    else
      [[NSCursor arrowCursor] set];
  } else {
    [[NSCursor arrowCursor] set];
  }

  if (changed)
    [self renderLanes];
}

- (BOOL)_canDeleteAtPoint:(NSPoint)loc {
  CGFloat totalWidth = NSWidth(self.bounds);
  CGFloat totalHeight = [self _totalHeight];
  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:totalWidth
                        trackX:&trackX
                    trackWidth:&trackWidth];

  for (NSUInteger laneIdx = 0; laneIdx < _lanes.count; laneIdx++) {
    KKTimingLane *lane = _lanes[laneIdx];
    if (!lane.enabled || lane.segments.count <= 1)
      continue;
    CGFloat laneY = [self _laneYForIndex:laneIdx totalHeight:totalHeight];
    if (loc.y < laneY || loc.y > laneY + kLaneHeight)
      continue;
    if (loc.x < kBorderInset + kLabelWidth)
      return NO;

    for (NSUInteger segIdx = 0; segIdx < lane.segments.count; segIdx++) {
      KKTimingSegment *seg = lane.segments[segIdx];
      CGFloat segLeft = trackX + seg.start * trackWidth;
      CGFloat segRight = trackX + seg.end * trackWidth;
      if (loc.x >= segLeft && loc.x <= segRight)
        return YES;
    }
  }
  return NO;
}

- (void)flagsChanged:(NSEvent *)event {
  if (_dragging || _hoveringEdge)
    return;
  NSPoint loc = [self.window mouseLocationOutsideOfEventStream];
  loc = [self convertPoint:loc fromView:nil];
  if (NSPointInRect(loc, self.bounds)) {
    if (event.modifierFlags & NSEventModifierFlagCommand) {
      if ([self _canDeleteAtPoint:loc])
        [[NSCursor disappearingItemCursor] set];
      else
        [[NSCursor arrowCursor] set];
    } else {
      [[NSCursor arrowCursor] set];
    }
  }
}

- (void)mouseExited:(NSEvent *)event {
  BOOL needsRender = _hoveringEdge || _hoverSegLaneIdx >= 0;
  _hoveringEdge = NO;
  _hoverLaneIdx = -1;
  _hoverSegIdx = -1;
  _hoverSegLaneIdx = -1;
  _hoverSegSegIdx = -1;
  [[NSCursor arrowCursor] set];
  if (needsRender)
    [self renderLanes];
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];

  CGFloat totalWidth = NSWidth(self.bounds);
  CGFloat totalHeight = [self _totalHeight];
  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:totalWidth
                        trackX:&trackX
                    trackWidth:&trackWidth];

  // Ruler click → scrub playhead.
  CGFloat rulerY = totalHeight - kBorderInset - kRulerHeight;
  if (loc.y >= rulerY && loc.y <= totalHeight - kBorderInset &&
      loc.x >= trackX && loc.x <= trackX + trackWidth) {
    double frac = (loc.x - trackX) / trackWidth;
    frac = MAX(0.0, MIN(1.0, frac));
    _scrubbingRuler = YES;
    _dragTrackX = trackX;
    _dragTrackWidth = trackWidth;
    _playheadFraction = frac;
    [self renderLanes];
    if (_onPlayheadScrub)
      _onPlayheadScrub(frac);
    return;
  }

  for (NSUInteger laneIdx = 0; laneIdx < _lanes.count; laneIdx++) {
    KKTimingLane *lane = _lanes[laneIdx];
    CGFloat laneY = [self _laneYForIndex:laneIdx totalHeight:totalHeight];

    if (loc.y < laneY || loc.y > laneY + kLaneHeight)
      continue;

    if (loc.x < kBorderInset + kLabelWidth) {
      if (_onLaneToggled)
        _onLaneToggled(laneIdx, !lane.enabled);
      return;
    }

    if (!lane.enabled)
      return;

    // Check for edge drag.
    for (NSUInteger segIdx = 0; segIdx < lane.segments.count; segIdx++) {
      KKTimingSegment *seg = lane.segments[segIdx];
      CGFloat segLeft = trackX + seg.start * trackWidth;
      CGFloat segRight = trackX + seg.end * trackWidth;

      // Leading edge (not for first segment).
      if (segIdx > 0 && fabs(loc.x - segLeft) < kEdgeHitZone) {
        _dragging = YES;
        _dragLaneIdx = laneIdx;
        _dragSegIdx = segIdx;
        _dragLeadingEdge = YES;
        _dragTrackX = trackX;
        _dragTrackWidth = trackWidth;
        [[NSCursor resizeLeftRightCursor] set];
        return;
      }
      // Trailing edge (not for last segment).
      if (segIdx < lane.segments.count - 1 &&
          fabs(loc.x - segRight) < kEdgeHitZone) {
        _dragging = YES;
        _dragLaneIdx = laneIdx;
        _dragSegIdx = segIdx;
        _dragLeadingEdge = NO;
        _dragTrackX = trackX;
        _dragTrackWidth = trackWidth;
        [[NSCursor resizeLeftRightCursor] set];
        return;
      }
    }

    // Double-click to add segment (snap to playhead if close).
    if (event.clickCount == 2) {
      double clickFrac = (loc.x - trackX) / trackWidth;
      clickFrac = MAX(0.0, MIN(1.0, clickFrac));
      CGFloat playheadX = trackX + _playheadFraction * trackWidth;
      if (fabs(loc.x - playheadX) < kPlayheadSnapPx)
        clickFrac = _playheadFraction;
      if (_onSegmentAdded)
        _onSegmentAdded(laneIdx, clickFrac);
      return;
    }

    // Check which segment was clicked.
    for (NSUInteger segIdx = 0; segIdx < lane.segments.count; segIdx++) {
      KKTimingSegment *seg = lane.segments[segIdx];
      CGFloat segLeft = trackX + seg.start * trackWidth;
      CGFloat segRight = trackX + seg.end * trackWidth;
      if (loc.x >= segLeft && loc.x <= segRight) {
        // Cmd-click removes the clicked segment.
        if ((event.modifierFlags & NSEventModifierFlagCommand) &&
            lane.segments.count > 1) {
          if (_onSegmentRemoved)
            _onSegmentRemoved(laneIdx, segIdx);
          return;
        }
        // Set up move-drag state before firing callback (callback may
        // replace _lanes via setLanes:, so _dragMoving must guard first).
        _dragMoving = YES;
        _dragLaneIdx = laneIdx;
        _dragSegIdx = segIdx;
        _dragTrackX = trackX;
        _dragTrackWidth = trackWidth;
        _dragMoveStartFrac = (loc.x - trackX) / trackWidth;
        _dragMoveOrigStart = seg.start;
        _dragMoveOrigEnd = seg.end;
        _hoverSegLaneIdx = -1;
        _hoverSegSegIdx = -1;
        if (_onSegmentSelected)
          _onSegmentSelected(laneIdx, segIdx);
        [self renderLanes];
        return;
      }
    }

    // Clicked empty region.
    if (_onSegmentSelected)
      _onSegmentSelected(laneIdx, -1);
    return;
  }
}

- (void)mouseDragged:(NSEvent *)event {
  if (_scrubbingRuler) {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    double frac = (loc.x - _dragTrackX) / _dragTrackWidth;
    frac = MAX(0.0, MIN(1.0, frac));
    _playheadFraction = frac;
    [self renderLanes];
    if (_onPlayheadScrub)
      _onPlayheadScrub(frac);
    return;
  }

  if (!_dragging && !_dragMoving)
    return;

  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  double newFrac = (loc.x - _dragTrackX) / _dragTrackWidth;
  newFrac = MAX(0.0, MIN(1.0, newFrac));

  NSMutableArray<KKTimingLane *> *lanes = [_lanes mutableCopy];
  if ((NSUInteger)_dragLaneIdx >= lanes.count)
    return;

  KKTimingLane *lane = [lanes[_dragLaneIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];

  if (_dragMoving) {
    [[NSCursor closedHandCursor] set];
    double delta = newFrac - _dragMoveStartFrac;
    double newStart = _dragMoveOrigStart + delta;
    double newEnd = _dragMoveOrigEnd + delta;
    double segSize = _dragMoveOrigEnd - _dragMoveOrigStart;

    double minPx = kMinSegmentPx / _dragTrackWidth;
    double minFrac = MAX(kMinSegmentFrac, minPx);

    // Clamp against previous neighbor's minimum size.
    if (_dragSegIdx > 0) {
      double prevStart = segs[_dragSegIdx - 1].start;
      if (newStart < prevStart + minFrac) {
        newStart = prevStart + minFrac;
        newEnd = newStart + segSize;
      }
    } else {
      if (newStart < 0) {
        newStart = 0;
        newEnd = newStart + segSize;
      }
    }
    // Clamp against next neighbor's minimum size.
    if ((NSUInteger)_dragSegIdx + 1 < segs.count) {
      double nextEnd = segs[_dragSegIdx + 1].end;
      if (newEnd > nextEnd - minFrac) {
        newEnd = nextEnd - minFrac;
        newStart = newEnd - segSize;
      }
    } else {
      if (newEnd > 1.0) {
        newEnd = 1.0;
        newStart = newEnd - segSize;
      }
    }

    KKTimingSegment *cur = [segs[_dragSegIdx] copy];
    cur.start = newStart;
    cur.end = newEnd;
    segs[_dragSegIdx] = cur;

    // Adjust neighbors to stay contiguous.
    if (_dragSegIdx > 0) {
      KKTimingSegment *prev = [segs[_dragSegIdx - 1] copy];
      prev.end = newStart;
      segs[_dragSegIdx - 1] = prev;
    }
    if ((NSUInteger)_dragSegIdx + 1 < segs.count) {
      KKTimingSegment *next = [segs[_dragSegIdx + 1] copy];
      next.start = newEnd;
      segs[_dragSegIdx + 1] = next;
    }

    lane.segments = segs;
    lanes[_dragLaneIdx] = lane;
    _lanes = lanes;
    [self renderLanes];
    return;
  }

  if (_dragLeadingEdge) {
    // Dragging the leading edge of _dragSegIdx.
    // This is the shared boundary between seg[_dragSegIdx-1] and
    // seg[_dragSegIdx].
    if (_dragSegIdx <= 0 || (NSUInteger)_dragSegIdx >= segs.count)
      return;
    KKTimingSegment *prev = [segs[_dragSegIdx - 1] copy];
    KKTimingSegment *cur = [segs[_dragSegIdx] copy];

    double minPx = kMinSegmentPx / _dragTrackWidth;
    double minFrac = MAX(kMinSegmentFrac, minPx);
    double minPos = prev.start + minFrac;
    double maxPos = cur.end - minFrac;
    newFrac = MAX(minPos, MIN(maxPos, newFrac));

    prev.end = newFrac;
    cur.start = newFrac;
    segs[_dragSegIdx - 1] = prev;
    segs[_dragSegIdx] = cur;
  } else {
    // Dragging the trailing edge of _dragSegIdx.
    // Shared boundary between seg[_dragSegIdx] and seg[_dragSegIdx+1].
    if ((NSUInteger)_dragSegIdx + 1 >= segs.count)
      return;
    KKTimingSegment *cur = [segs[_dragSegIdx] copy];
    KKTimingSegment *next = [segs[_dragSegIdx + 1] copy];

    double minPx = kMinSegmentPx / _dragTrackWidth;
    double minFrac = MAX(kMinSegmentFrac, minPx);
    newFrac = MAX(cur.start + minFrac, MIN(next.end - minFrac, newFrac));

    cur.end = newFrac;
    next.start = newFrac;
    segs[_dragSegIdx] = cur;
    segs[_dragSegIdx + 1] = next;
  }

  lane.segments = segs;
  lanes[_dragLaneIdx] = lane;
  _lanes = lanes;
  [self renderLanes];
}

- (void)mouseUp:(NSEvent *)event {
  if (_scrubbingRuler) {
    _scrubbingRuler = NO;
    return;
  }
  if (_dragMoving) {
    BOOL moved = NO;
    if ((NSUInteger)_dragLaneIdx < _lanes.count) {
      KKTimingSegment *seg = _lanes[_dragLaneIdx].segments[_dragSegIdx];
      moved = (fabs(seg.start - _dragMoveOrigStart) > 0.001);
    }
    _dragMoving = NO;
    [[NSCursor arrowCursor] set];
    if (moved && (NSUInteger)_dragLaneIdx < _lanes.count && _onLaneChanged)
      _onLaneChanged(_dragLaneIdx, _lanes[_dragLaneIdx]);
    return;
  }
  if (_dragging) {
    _dragging = NO;
    [[NSCursor arrowCursor] set];
    _hoveringEdge = NO;
    if ((NSUInteger)_dragLaneIdx < _lanes.count && _onLaneChanged)
      _onLaneChanged(_dragLaneIdx, _lanes[_dragLaneIdx]);
  }
}

@end
