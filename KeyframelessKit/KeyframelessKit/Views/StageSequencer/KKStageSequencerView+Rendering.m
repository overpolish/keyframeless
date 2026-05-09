/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKStageSequencerView (Rendering)

- (void)renderLanes {
  CGFloat totalWidth = NSWidth(self.bounds);
  if (totalWidth < 1)
    return;
  if (!self.lanes.count) {
    // Drop the cached image so drawRect: doesn't keep blitting the previous
    // lanes after the lane list empties (e.g. last Canvas layer deleted).
    _lanesImage = nil;
    [self setNeedsDisplay:YES];
    return;
  }

  CGFloat totalHeight = [self _totalHeight];
  CGFloat imageWidth = totalWidth;
  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:totalWidth
                        trackX:&trackX
                    trackWidth:&trackWidth];

  NSImage *image =
      [[NSImage alloc] initWithSize:NSMakeSize(imageWidth, totalHeight)];
  [image lockFocus];

  for (NSUInteger rowIdx = 0; rowIdx < _rowPlan.count; rowIdx++) {
    KKSequencerRow *row = _rowPlan[rowIdx];
    CGFloat rowY = [self _rowYForPlanIndex:rowIdx totalHeight:totalHeight];
    if (row.kind == KKSequencerRowKindHeader) {
      [self _renderGroupHeaderRow:row
                             rowY:rowY
                           trackX:trackX
                       trackWidth:trackWidth];
      continue;
    }
    NSUInteger laneIdx = (NSUInteger)row.laneIndex;
    KKTimingLane *lane = self.lanes[laneIdx];
    CGFloat laneY = rowY;

    [self _renderLaneLabel:lane laneY:laneY];

    if (trackWidth < 1)
      continue;

    [self _renderSegmentFillsForLane:lane
                           laneIndex:laneIdx
                              trackX:trackX
                          trackWidth:trackWidth
                               laneY:laneY];

    if (lane.enabled && trackWidth > 10) {
      NSNumber *kindNum = [self _slotKindForLane:lane];
      BOOL isColorLike =
          (kindNum.integerValue == KKAnimatableParamKindColor ||
           kindNum.integerValue == KKAnimatableParamKindGradient);
      // Morph lanes have no scalar payload — render the easing curve only,
      // at full lane height (no value strip).
      BOOL isMorph = (kindNum.integerValue == KKAnimatableParamKindMorph);
      if (isMorph) {
        [self _renderNormalizedCurveForLane:lane
                                     trackX:trackX
                                 trackWidth:trackWidth
                                      laneY:laneY];
      } else if (isColorLike) {
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
      }
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

@end
#pragma clang diagnostic pop
