/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKStageSequencerView (InteractionHitTest)

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

  for (NSUInteger laneIdx = 0; laneIdx < self.lanes.count; laneIdx++) {
    KKTimingLane *lane = self.lanes[laneIdx];
    if (!lane.enabled)
      continue;
    CGFloat laneY = [self _laneYForIndex:laneIdx totalHeight:totalHeight];
    if (loc.y < laneY || loc.y > laneY + [self _laneHeight])
      continue;
    if (loc.x < kKSSBorderInset + kKSSLabelWidth)
      return NO;

    for (NSUInteger segIdx = 0; segIdx < lane.segments.count; segIdx++) {
      KKTimingSegment *seg = lane.segments[segIdx];
      CGFloat segLeft = [self _xForFrac:seg.start
                                 trackX:trackX
                             trackWidth:trackWidth];
      CGFloat segRight = [self _xForFrac:seg.end
                                  trackX:trackX
                              trackWidth:trackWidth];

      if (fabs(loc.x - segLeft) < kKSSEdgeHitZone) {
        *outLane = laneIdx;
        *outSeg = segIdx;
        *outLeading = YES;
        return YES;
      }
      if (fabs(loc.x - segRight) < kKSSEdgeHitZone) {
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

- (BOOL)_canDeleteAtPoint:(NSPoint)loc {
  CGFloat totalWidth = NSWidth(self.bounds);
  CGFloat totalHeight = [self _totalHeight];
  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:totalWidth
                        trackX:&trackX
                    trackWidth:&trackWidth];

  for (NSUInteger laneIdx = 0; laneIdx < self.lanes.count; laneIdx++) {
    KKTimingLane *lane = self.lanes[laneIdx];
    if (!lane.enabled || lane.segments.count <= 1)
      continue;
    CGFloat laneY = [self _laneYForIndex:laneIdx totalHeight:totalHeight];
    if (loc.y < laneY || loc.y > laneY + [self _laneHeight])
      continue;
    if (loc.x < kKSSBorderInset + kKSSLabelWidth)
      return NO;

    for (NSUInteger segIdx = 0; segIdx < lane.segments.count; segIdx++) {
      KKTimingSegment *seg = lane.segments[segIdx];
      CGFloat segLeft = [self _xForFrac:seg.start
                                 trackX:trackX
                             trackWidth:trackWidth];
      CGFloat segRight = [self _xForFrac:seg.end
                                  trackX:trackX
                              trackWidth:trackWidth];
      if (loc.x >= segLeft && loc.x <= segRight)
        return YES;
    }
  }
  return NO;
}

/// Returns YES when `loc` falls on the edit button of the currently hovered
/// segment. The button only exists on the hovered segment and only when that
/// segment is wide enough to show it.
- (BOOL)_editButtonUnderPoint:(NSPoint)loc
                      outLane:(NSInteger *)outLane
                       outSeg:(NSInteger *)outSeg
                outAnchorRect:(NSRect *)outRect {
  if (outLane)
    *outLane = -1;
  if (outSeg)
    *outSeg = -1;
  if (_hoverSegLaneIdx < 0 || _hoverSegSegIdx < 0)
    return NO;
  if ((NSUInteger)_hoverSegLaneIdx >= self.lanes.count)
    return NO;
  KKTimingLane *lane = self.lanes[_hoverSegLaneIdx];
  if (!lane.enabled || (NSUInteger)_hoverSegSegIdx >= lane.segments.count)
    return NO;
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
  if (NSIsEmptyRect(btn) || !NSPointInRect(loc, btn))
    return NO;
  if (outLane)
    *outLane = _hoverSegLaneIdx;
  if (outSeg)
    *outSeg = _hoverSegSegIdx;
  if (outRect) {
    // Anchor the popover to the segment itself, not the tiny edit button —
    // keeps the callout pointing at the thing being edited.
    KKTimingSegment *seg = lane.segments[_hoverSegSegIdx];
    CGFloat segX = [self _xForFrac:seg.start
                            trackX:trackX
                        trackWidth:trackWidth];
    CGFloat segW = (seg.end - seg.start) * trackWidth * _zoom;
    CGFloat laneY = [self _laneYForIndex:(NSUInteger)_hoverSegLaneIdx
                             totalHeight:totalHeight];
    *outRect = NSMakeRect(segX, laneY + 2, segW, [self _laneHeight] - 4);
  }
  return YES;
}

/// Finds the (lane, segment) that a point sits inside, or (-1, -1).
- (void)_segmentUnderPoint:(NSPoint)loc
                   outLane:(NSInteger *)outLane
                    outSeg:(NSInteger *)outSeg {
  *outLane = -1;
  *outSeg = -1;
  CGFloat totalWidth = NSWidth(self.bounds);
  CGFloat totalHeight = [self _totalHeight];
  CGFloat tX, tW;
  [self _trackGeometryForWidth:totalWidth trackX:&tX trackWidth:&tW];

  for (NSUInteger li = 0; li < self.lanes.count; li++) {
    KKTimingLane *l = self.lanes[li];
    if (!l.enabled)
      continue;
    CGFloat ly = [self _laneYForIndex:li totalHeight:totalHeight];
    if (loc.y < ly || loc.y > ly + [self _laneHeight])
      continue;
    if (loc.x < kKSSBorderInset + kKSSLabelWidth)
      return;
    for (NSUInteger si = 0; si < l.segments.count; si++) {
      CGFloat sL = [self _xForFrac:l.segments[si].start
                            trackX:tX
                        trackWidth:tW];
      CGFloat sR = [self _xForFrac:l.segments[si].end trackX:tX trackWidth:tW];
      if (loc.x >= sL && loc.x <= sR) {
        *outLane = li;
        *outSeg = si;
        return;
      }
    }
    return;
  }
}

@end
#pragma clang diagnostic pop
