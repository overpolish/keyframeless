/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKStageSequencerView (Interaction)

- (void)mouseMoved:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger lane = -1, seg = -1;
  BOOL leading = NO;
  BOOL onEdge = [self _hitTestEdgeAtPoint:loc
                                  laneIdx:&lane
                                   segIdx:&seg
                                  leading:&leading];
  NSInteger hovSegLane = -1, hovSegSeg = -1;
  if (!onEdge)
    [self _segmentUnderPoint:loc outLane:&hovSegLane outSeg:&hovSegSeg];

  BOOL changed = (onEdge != _hoveringEdge || lane != _hoverLaneIdx ||
                  seg != _hoverSegIdx || hovSegLane != _hoverSegLaneIdx ||
                  hovSegSeg != _hoverSegSegIdx);
  _hoveringEdge = onEdge;
  _hoverLaneIdx = lane;
  _hoverSegIdx = seg;
  _hoverLeading = leading;
  _hoverSegLaneIdx = hovSegLane;
  _hoverSegSegIdx = hovSegSeg;

  BOOL onEdit = [self _editButtonUnderPoint:loc
                                    outLane:NULL
                                     outSeg:NULL
                              outAnchorRect:NULL];

  if (onEdit) {
    [[NSCursor pointingHandCursor] set];
  } else if (onEdge) {
    [[NSCursor resizeLeftRightCursor] set];
  } else if (event.modifierFlags & NSEventModifierFlagCommand) {
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

- (void)rightMouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger laneIdx = -1, segIdx = -1;
  [self _segmentUnderPoint:loc outLane:&laneIdx outSeg:&segIdx];
  if (laneIdx < 0 || segIdx < 0)
    return;

  if (event.modifierFlags & NSEventModifierFlagShift) {
    if (self.onAllLanesSegmentTypesToggled) {
      CGFloat trackX, trackWidth;
      [self _trackGeometryForWidth:NSWidth(self.bounds)
                            trackX:&trackX
                        trackWidth:&trackWidth];
      double frac = [self _fracForX:loc.x trackX:trackX trackWidth:trackWidth];
      self.onAllLanesSegmentTypesToggled(frac);
    }
    return;
  }

  if (self.onSegmentTypeToggled)
    self.onSegmentTypeToggled(laneIdx, segIdx);
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];

  // Edit button takes priority over any other interaction.
  NSInteger editLane = -1, editSeg = -1;
  NSRect editRect = NSZeroRect;
  if ([self _editButtonUnderPoint:loc
                          outLane:&editLane
                           outSeg:&editSeg
                    outAnchorRect:&editRect]) {
    if (event.modifierFlags & NSEventModifierFlagShift) {
      if (self.onAllLanesSegmentEditRequested)
        self.onAllLanesSegmentEditRequested(editLane, editSeg, editRect);
    } else if (self.onSegmentEditRequested) {
      self.onSegmentEditRequested(editLane, editSeg, editRect);
    }
    return;
  }

  CGFloat totalWidth = NSWidth(self.bounds);
  CGFloat totalHeight = [self _totalHeight];
  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:totalWidth
                        trackX:&trackX
                    trackWidth:&trackWidth];

  // Shift+double-click anywhere in the track area splits every lane at the
  // same fraction. Handled before the per-lane loop so it works regardless of
  // which row the click landed on.
  if (event.clickCount == 2 &&
      (event.modifierFlags & NSEventModifierFlagShift) && loc.x >= trackX &&
      loc.x <= trackX + trackWidth) {
    double clickFrac = [self _fracForX:loc.x
                                trackX:trackX
                            trackWidth:trackWidth];
    clickFrac = MAX(0.0, MIN(1.0, clickFrac));
    CGFloat playheadX = [self _xForFrac:self.playheadFraction
                                 trackX:trackX
                             trackWidth:trackWidth];
    if (fabs(loc.x - playheadX) < kKSSPlayheadSnapPx)
      clickFrac = self.playheadFraction;
    if (self.onAllLanesSegmentAdded)
      self.onAllLanesSegmentAdded(clickFrac);
    return;
  }

  for (NSUInteger laneIdx = 0; laneIdx < self.lanes.count; laneIdx++) {
    KKTimingLane *lane = self.lanes[laneIdx];
    CGFloat laneY = [self _laneYForIndex:laneIdx totalHeight:totalHeight];

    if (loc.y < laneY || loc.y > laneY + [self _laneHeight])
      continue;

    if (loc.x < kKSSBorderInset + kKSSLabelWidth) {
      CGFloat iconSlotLeft = kKSSBorderInset + kKSSLabelPadding;
      NSRect iconRect = NSMakeRect(
          iconSlotLeft, laneY + ([self _laneHeight] - kKSSOSCIconSize) / 2.0,
          kKSSOSCIconSize, kKSSOSCIconSize);
      if (lane.hasOSC && NSPointInRect(loc, iconRect)) {
        if (self.onLaneOSCVisibilityToggled)
          self.onLaneOSCVisibilityToggled(laneIdx, !lane.oscVisible);
        return;
      }
      if (self.onLaneToggled)
        self.onLaneToggled(laneIdx, !lane.enabled);
      return;
    }

    if (!lane.enabled)
      return;

    if ([self _tryBeginEdgeDragForLane:lane
                             laneIndex:laneIdx
                                   loc:loc
                                trackX:trackX
                            trackWidth:trackWidth])
      return;

    // Double-click to add segment (snap to playhead if close).
    if (event.clickCount == 2) {
      double clickFrac = [self _fracForX:loc.x
                                  trackX:trackX
                              trackWidth:trackWidth];
      clickFrac = MAX(0.0, MIN(1.0, clickFrac));
      CGFloat playheadX = [self _xForFrac:self.playheadFraction
                                   trackX:trackX
                               trackWidth:trackWidth];
      if (fabs(loc.x - playheadX) < kKSSPlayheadSnapPx)
        clickFrac = self.playheadFraction;

      // Reject splits that would produce a slither too thin to grab.
      NSUInteger splitIdx = NSNotFound;
      for (NSUInteger si = 0; si < lane.segments.count; si++) {
        KKTimingSegment *s = lane.segments[si];
        if (clickFrac >= s.start && clickFrac < s.end) {
          splitIdx = si;
          break;
        }
      }
      if (splitIdx == NSNotFound)
        return;
      double minPx = kKSSMinSegmentPx / (trackWidth * _zoom);
      double minSecFrac = self.effectDuration > 0
                              ? kKSSMinSegmentSec / self.effectDuration
                              : 0.0;
      double minFrac = MAX(minSecFrac, minPx);
      KKTimingSegment *target = lane.segments[splitIdx];
      if (clickFrac - target.start < minFrac ||
          target.end - clickFrac < minFrac)
        return;

      if (self.onSegmentAdded)
        self.onSegmentAdded(laneIdx, clickFrac);
      return;
    }

    if ([self _tryBeginSegmentInteractionForLane:lane
                                       laneIndex:laneIdx
                                           event:event
                                             loc:loc
                                          trackX:trackX
                                      trackWidth:trackWidth])
      return;

    // Clicked empty region.
    if (self.onSegmentSelected)
      self.onSegmentSelected(laneIdx, -1);
    return;
  }
}

- (void)mouseDragged:(NSEvent *)event {
  if (_pendingCtrlClick) {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    if (fabs(loc.x - _pendingCtrlStartLoc.x) >= kKSSDragThresholdPx ||
        fabs(loc.y - _pendingCtrlStartLoc.y) >= kKSSDragThresholdPx) {
      KKTimingLane *lane = self.lanes[_pendingCtrlLaneIdx];
      _dragLaneMoving = YES;
      _dragLaneMoveStartFrac = [self _fracForX:_pendingCtrlStartLoc.x
                                        trackX:_dragTrackX
                                    trackWidth:_dragTrackWidth];
      NSMutableArray *origSegs =
          [NSMutableArray arrayWithCapacity:lane.segments.count];
      for (KKTimingSegment *s in lane.segments)
        [origSegs addObject:[s copy]];
      _dragLaneMoveOrigSegs = origSegs;
      _pendingCtrlClick = NO;
    } else {
      return;
    }
  }
  if (_dragValueCopying) {
    [self _dragValueCopyToEvent:event];
    return;
  }
  if (_dragLaneMoving) {
    [self _dragLaneMoveToEvent:event];
    return;
  }
  if (!_dragging && !_dragMoving)
    return;

  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  double newFrac = [self _fracForX:loc.x
                            trackX:_dragTrackX
                        trackWidth:_dragTrackWidth];
  newFrac = MAX(0.0, MIN(1.0, newFrac));

  NSMutableArray<KKTimingLane *> *lanes = [self.lanes mutableCopy];
  if ((NSUInteger)_dragLaneIdx >= lanes.count)
    return;

  BOOL snapEnabled = !(event.modifierFlags & NSEventModifierFlagShift);
  _snapActive = NO;

  if (_dragMoving) {
    [self _applySegmentMoveWithFrac:newFrac
                        snapEnabled:snapEnabled
                              lanes:lanes];
  } else if (_bulkEdgeDrag) {
    [self _applyBulkEdgeDragWithFrac:newFrac lanes:lanes];
  } else {
    [self _applyEdgeDragWithFrac:newFrac snapEnabled:snapEnabled lanes:lanes];
  }
  self.lanes = lanes;
  [self renderLanes];
}

- (void)mouseUp:(NSEvent *)event {
  if (_pendingCtrlClick) {
    NSInteger laneIdx = _pendingCtrlLaneIdx;
    NSInteger segIdx = _pendingCtrlSegIdx;
    _pendingCtrlClick = NO;
    if ((NSUInteger)laneIdx < self.lanes.count) {
      KKTimingLane *lane = self.lanes[laneIdx];
      if ((NSUInteger)segIdx < lane.segments.count &&
          self.onSegmentLockToggled) {
        KKTimingSegment *seg = lane.segments[segIdx];
        double newLocked = (seg.lockedDurationSeconds > 0)
                               ? 0.0
                               : (seg.end - seg.start) * self.effectDuration;
        self.onSegmentLockToggled(laneIdx, segIdx, newLocked);
      }
    }
    return;
  }
  BOOL wasDragging =
      _dragValueCopying || _dragLaneMoving || _dragMoving || _dragging;
  if (_dragValueCopying) {
    NSInteger src = _dragCopySrcSegIdx;
    NSInteger dst = _dragCopyDstSegIdx;
    NSInteger lane = _dragCopyLaneIdx;
    _dragValueCopying = NO;
    _dragCopyLaneIdx = -1;
    _dragCopySrcSegIdx = -1;
    _dragCopyDstSegIdx = -1;
    [[NSCursor arrowCursor] set];
    if (dst >= 0 && src != dst && self.onSegmentValuesCopied)
      self.onSegmentValuesCopied(lane, src, dst);
    [self renderLanes];
    return;
  }
  if (_dragLaneMoving) {
    _dragLaneMoving = NO;
    _dragLaneMoveOrigSegs = nil;
    [[NSCursor arrowCursor] set];
    _snapActive = NO;
    if ((NSUInteger)_dragLaneIdx < self.lanes.count && self.onLaneChanged)
      self.onLaneChanged(_dragLaneIdx, self.lanes[_dragLaneIdx]);
  } else if (_dragMoving) {
    BOOL moved = NO;
    if ((NSUInteger)_dragLaneIdx < self.lanes.count) {
      KKTimingSegment *seg = self.lanes[_dragLaneIdx].segments[_dragSegIdx];
      moved = (fabs(seg.start - _dragMoveOrigStart) > 0.001);
    }
    _dragMoving = NO;
    [[NSCursor arrowCursor] set];
    _snapActive = NO;
    if (moved && (NSUInteger)_dragLaneIdx < self.lanes.count &&
        self.onLaneChanged)
      self.onLaneChanged(_dragLaneIdx, self.lanes[_dragLaneIdx]);
  } else if (_dragging) {
    BOOL wasBulkEdge = _bulkEdgeDrag;
    NSArray<NSValue *> *bulkTargets = _bulkEdgeTargets;
    _dragging = NO;
    _bulkEdgeDrag = NO;
    _bulkEdgeAlign = NO;
    _bulkEdgeTargets = nil;
    [[NSCursor arrowCursor] set];
    _hoveringEdge = NO;
    _snapActive = NO;
    if (wasBulkEdge) {
      NSMutableArray<NSNumber *> *idxs = [NSMutableArray array];
      NSMutableArray<KKTimingLane *> *updated = [NSMutableArray array];
      for (NSValue *v in bulkTargets) {
        NSInteger li = (NSInteger)v.rectValue.origin.x;
        if ((NSUInteger)li < self.lanes.count) {
          [idxs addObject:@(li)];
          [updated addObject:self.lanes[li]];
        }
      }
      if (self.onLanesChanged && idxs.count > 0)
        self.onLanesChanged(idxs, updated);
    } else if ((NSUInteger)_dragLaneIdx < self.lanes.count &&
               self.onLaneChanged) {
      self.onLaneChanged(_dragLaneIdx, self.lanes[_dragLaneIdx]);
    }
  }
  if (wasDragging)
    [self renderLanes];
}

@end
#pragma clang diagnostic pop
