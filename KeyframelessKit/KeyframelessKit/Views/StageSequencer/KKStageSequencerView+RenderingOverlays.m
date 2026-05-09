/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../Style/NSColor+KKColors.h"
#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKStageSequencerView (RenderingOverlays)

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
  // label).
  CGFloat btnLeft = segX + segW / 2.0 - kKSSEditButtonSize / 2.0;
  btnLeft = MAX(trackX, MIN(trackX + trackWidth - kKSSEditButtonSize, btnLeft));
  // Keep the button inside the segment's visible span so a partially-visible
  // segment doesn't push the button into an adjacent segment.
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

  NSImage *icon = [NSImage imageWithSystemSymbolName:@"water.waves"
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

@end
#pragma clang diagnostic pop
