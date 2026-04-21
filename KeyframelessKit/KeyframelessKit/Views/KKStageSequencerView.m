/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKStageSequencerView.h"
#import "../Math/KKEasing.h"
#import "../Math/KKTimingStage.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"

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
  // Drag state.
  BOOL _dragging;
  NSInteger _dragLaneIdx;
  NSInteger _dragSegIdx;
  BOOL _dragLeadingEdge;
  CGFloat _dragTrackX;
  CGFloat _dragTrackWidth;
  // Hover state.
  NSInteger _hoverLaneIdx;
  NSInteger _hoverSegIdx;
  BOOL _hoverLeading;
  BOOL _hoveringEdge;
  // Segment hover (for highlight).
  NSInteger _hoverSegLaneIdx;
  NSInteger _hoverSegSegIdx;
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
  if (!_dragging)
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
  return totalHeight - kBorderInset - (laneIdx + 1) * kLaneHeight -
         laneIdx * kLaneSpacing;
}

- (CGFloat)_totalHeight {
  return _lanes.count * kLaneHeight + (_lanes.count - 1) * kLaneSpacing +
         2 * kBorderInset;
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

    // Double-click to add segment.
    if (event.clickCount == 2) {
      double clickFrac = (loc.x - trackX) / trackWidth;
      clickFrac = MAX(0.0, MIN(1.0, clickFrac));
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
        // Regular click — select.
        if (_onSegmentSelected)
          _onSegmentSelected(laneIdx, segIdx);
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
  if (!_dragging)
    return;

  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  double newFrac = (loc.x - _dragTrackX) / _dragTrackWidth;
  newFrac = MAX(0.0, MIN(1.0, newFrac));

  NSMutableArray<KKTimingLane *> *lanes = [_lanes mutableCopy];
  if ((NSUInteger)_dragLaneIdx >= lanes.count)
    return;

  KKTimingLane *lane = [lanes[_dragLaneIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];

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
  if (_dragging) {
    _dragging = NO;
    [[NSCursor arrowCursor] set];
    _hoveringEdge = NO;
    if ((NSUInteger)_dragLaneIdx < _lanes.count && _onLaneChanged)
      _onLaneChanged(_dragLaneIdx, _lanes[_dragLaneIdx]);
  }
}

@end
