/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKStageSequencerView (Interaction)

#pragma mark - Hit-testing helpers

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
    if (loc.y < laneY || loc.y > laneY + kKSSLaneHeight)
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
    if (loc.y < laneY || loc.y > laneY + kKSSLaneHeight)
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
    if (loc.y < ly || loc.y > ly + kKSSLaneHeight)
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

#pragma mark - Mouse tracking

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

  if (onEdge) {
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

#pragma mark - Zoom & pan

- (void)magnifyWithEvent:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:NSWidth(self.bounds)
                        trackX:&trackX
                    trackWidth:&trackWidth];

  double fracUnderCursor = [self _fracForX:loc.x
                                    trackX:trackX
                                trackWidth:trackWidth];

  _zoom = MAX(1.0, MIN(20.0, _zoom * (1.0 + event.magnification)));

  // Adjust pan so the fraction under the cursor stays put.
  _panOffset = fracUnderCursor - (loc.x - trackX) / (_zoom * trackWidth);
  [self _clampPanOffset];
  [self mouseMoved:event];
  [self renderLanes];
}

- (void)scrollWheel:(NSEvent *)event {
  if (event.phase == NSEventPhaseNone &&
      event.momentumPhase == NSEventPhaseNone)
    return;
  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:NSWidth(self.bounds)
                        trackX:&trackX
                    trackWidth:&trackWidth];
  CGFloat dx = event.scrollingDeltaX;
  if (event.hasPreciseScrollingDeltas)
    _panOffset -= dx / (_zoom * trackWidth);
  else
    _panOffset -= dx * 0.01 / _zoom;
  [self _clampPanOffset];

  NSPoint loc = [self.window mouseLocationOutsideOfEventStream];
  loc = [self convertPoint:loc fromView:nil];
  if (NSPointInRect(loc, self.bounds)) {
    [self mouseMoved:event];
  } else {
    _hoveringEdge = NO;
    _hoverLaneIdx = -1;
    _hoverSegIdx = -1;
    _hoverSegLaneIdx = -1;
    _hoverSegSegIdx = -1;
  }

  [self renderLanes];
}

#pragma mark - Mouse down/drag/up

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];

  CGFloat totalWidth = NSWidth(self.bounds);
  CGFloat totalHeight = [self _totalHeight];
  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:totalWidth
                        trackX:&trackX
                    trackWidth:&trackWidth];

  // Ruler click → scrub playhead.
  CGFloat rulerY = totalHeight - kKSSBorderInset - kKSSRulerHeight;
  if (loc.y >= rulerY && loc.y <= totalHeight - kKSSBorderInset &&
      loc.x >= trackX && loc.x <= trackX + trackWidth) {
    double frac = [self _fracForX:loc.x trackX:trackX trackWidth:trackWidth];
    frac = MAX(0.0, MIN(1.0, frac));
    _scrubbingRuler = YES;
    _dragTrackX = trackX;
    _dragTrackWidth = trackWidth;
    self.playheadFraction = frac;
    [self renderLanes];
    if (self.onPlayheadScrub)
      self.onPlayheadScrub(frac);
    return;
  }

  for (NSUInteger laneIdx = 0; laneIdx < self.lanes.count; laneIdx++) {
    KKTimingLane *lane = self.lanes[laneIdx];
    CGFloat laneY = [self _laneYForIndex:laneIdx totalHeight:totalHeight];

    if (loc.y < laneY || loc.y > laneY + kKSSLaneHeight)
      continue;

    if (loc.x < kKSSBorderInset + kKSSLabelWidth) {
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

/// Begin a resize drag if the click landed near a segment edge. Returns YES
/// if a drag started (caller should return).
- (BOOL)_tryBeginEdgeDragForLane:(KKTimingLane *)lane
                       laneIndex:(NSUInteger)laneIdx
                             loc:(NSPoint)loc
                          trackX:(CGFloat)trackX
                      trackWidth:(CGFloat)trackWidth {
  for (NSUInteger segIdx = 0; segIdx < lane.segments.count; segIdx++) {
    KKTimingSegment *seg = lane.segments[segIdx];
    CGFloat segLeft = [self _xForFrac:seg.start
                               trackX:trackX
                           trackWidth:trackWidth];
    CGFloat segRight = [self _xForFrac:seg.end
                                trackX:trackX
                            trackWidth:trackWidth];

    BOOL onLeft = fabs(loc.x - segLeft) < kKSSEdgeHitZone;
    BOOL onRight = fabs(loc.x - segRight) < kKSSEdgeHitZone;
    if (!onLeft && !onRight)
      continue;

    _dragging = YES;
    _dragLaneIdx = laneIdx;
    _dragSegIdx = segIdx;
    _dragLeadingEdge = onLeft;
    _dragTrackX = trackX;
    _dragTrackWidth = trackWidth;
    [[NSCursor resizeLeftRightCursor] set];
    return YES;
  }
  return NO;
}

/// Handle click inside a segment body: Cmd-click delete, Option-drag lane,
/// or start a segment move. Returns YES if the click consumed the event.
- (BOOL)_tryBeginSegmentInteractionForLane:(KKTimingLane *)lane
                                 laneIndex:(NSUInteger)laneIdx
                                     event:(NSEvent *)event
                                       loc:(NSPoint)loc
                                    trackX:(CGFloat)trackX
                                trackWidth:(CGFloat)trackWidth {
  for (NSUInteger segIdx = 0; segIdx < lane.segments.count; segIdx++) {
    KKTimingSegment *seg = lane.segments[segIdx];
    CGFloat segLeft = [self _xForFrac:seg.start
                               trackX:trackX
                           trackWidth:trackWidth];
    CGFloat segRight = [self _xForFrac:seg.end
                                trackX:trackX
                            trackWidth:trackWidth];
    if (loc.x < segLeft || loc.x > segRight)
      continue;

    if ((event.modifierFlags & NSEventModifierFlagCommand) &&
        lane.segments.count > 1) {
      if (self.onSegmentRemoved)
        self.onSegmentRemoved(laneIdx, segIdx);
      return YES;
    }

    if (event.modifierFlags & NSEventModifierFlagOption) {
      _dragLaneMoving = YES;
      _dragLaneIdx = laneIdx;
      _dragTrackX = trackX;
      _dragTrackWidth = trackWidth;
      _dragLaneMoveStartFrac = [self _fracForX:loc.x
                                        trackX:trackX
                                    trackWidth:trackWidth];
      NSMutableArray *origSegs =
          [NSMutableArray arrayWithCapacity:lane.segments.count];
      for (KKTimingSegment *s in lane.segments)
        [origSegs addObject:[s copy]];
      _dragLaneMoveOrigSegs = origSegs;
      _hoverSegLaneIdx = -1;
      _hoverSegSegIdx = -1;
      return YES;
    }

    // Set up move-drag state before firing callback (callback may
    // replace self.lanes via setLanes:, so _dragMoving must guard first).
    _dragMoving = YES;
    _dragLaneIdx = laneIdx;
    _dragSegIdx = segIdx;
    _dragTrackX = trackX;
    _dragTrackWidth = trackWidth;
    _dragMoveStartFrac = [self _fracForX:loc.x
                                  trackX:trackX
                              trackWidth:trackWidth];
    _dragMoveOrigStart = seg.start;
    _dragMoveOrigEnd = seg.end;
    _hoverSegLaneIdx = -1;
    _hoverSegSegIdx = -1;
    if (self.onSegmentSelected)
      self.onSegmentSelected(laneIdx, segIdx);
    [self renderLanes];
    return YES;
  }
  return NO;
}

- (void)mouseDragged:(NSEvent *)event {
  if (_scrubbingRuler) {
    [self _scrubPlayheadToEvent:event];
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

  if (_dragMoving) {
    [self _applySegmentMoveWithFrac:newFrac lanes:lanes];
  } else {
    [self _applyEdgeDragWithFrac:newFrac lanes:lanes];
  }
  self.lanes = lanes;
  [self renderLanes];
}

- (void)_scrubPlayheadToEvent:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  double frac = [self _fracForX:loc.x
                         trackX:_dragTrackX
                     trackWidth:_dragTrackWidth];
  frac = MAX(0.0, MIN(1.0, frac));
  self.playheadFraction = frac;
  [self renderLanes];
  if (self.onPlayheadScrub)
    self.onPlayheadScrub(frac);
}

- (void)_dragLaneMoveToEvent:(NSEvent *)event {
  [[NSCursor closedHandCursor] set];
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  double newFrac = [self _fracForX:loc.x
                            trackX:_dragTrackX
                        trackWidth:_dragTrackWidth];
  newFrac = MAX(0.0, MIN(1.0, newFrac));
  double delta = newFrac - _dragLaneMoveStartFrac;

  // Clamp delta so no segment goes out of 0–1.
  double firstStart = _dragLaneMoveOrigSegs.firstObject.start;
  double lastEnd = _dragLaneMoveOrigSegs.lastObject.end;
  if (firstStart + delta < 0)
    delta = -firstStart;
  if (lastEnd + delta > 1.0)
    delta = 1.0 - lastEnd;

  NSMutableArray<KKTimingLane *> *lanes = [self.lanes mutableCopy];
  KKTimingLane *lane = [lanes[_dragLaneIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs =
      [NSMutableArray arrayWithCapacity:_dragLaneMoveOrigSegs.count];
  for (KKTimingSegment *orig in _dragLaneMoveOrigSegs) {
    KKTimingSegment *s = [orig copy];
    s.start = orig.start + delta;
    s.end = orig.end + delta;
    [segs addObject:s];
  }
  lane.segments = segs;
  lanes[_dragLaneIdx] = lane;
  self.lanes = lanes;
  [self renderLanes];
}

- (void)_applySegmentMoveWithFrac:(double)newFrac
                            lanes:(NSMutableArray<KKTimingLane *> *)lanes {
  [[NSCursor closedHandCursor] set];
  KKTimingLane *lane = [lanes[_dragLaneIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];

  double delta = newFrac - _dragMoveStartFrac;
  double newStart = _dragMoveOrigStart + delta;
  double newEnd = _dragMoveOrigEnd + delta;
  double segSize = _dragMoveOrigEnd - _dragMoveOrigStart;

  double minPx = kKSSMinSegmentPx / (_dragTrackWidth * _zoom);
  double minFrac = MAX(kKSSMinSegmentFrac, minPx);

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
}

- (void)_applyEdgeDragWithFrac:(double)newFrac
                         lanes:(NSMutableArray<KKTimingLane *> *)lanes {
  KKTimingLane *lane = [lanes[_dragLaneIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];

  double minPx = kKSSMinSegmentPx / (_dragTrackWidth * _zoom);
  double minFrac = MAX(kKSSMinSegmentFrac, minPx);

  if (_dragLeadingEdge) {
    KKTimingSegment *cur = [segs[_dragSegIdx] copy];
    if (_dragSegIdx > 0) {
      KKTimingSegment *prev = [segs[_dragSegIdx - 1] copy];
      double minPos = prev.start + minFrac;
      double maxPos = cur.end - minFrac;
      newFrac = MAX(minPos, MIN(maxPos, newFrac));
      prev.end = newFrac;
      cur.start = newFrac;
      segs[_dragSegIdx - 1] = prev;
    } else {
      newFrac = MAX(0.0, MIN(cur.end - minFrac, newFrac));
      cur.start = newFrac;
    }
    segs[_dragSegIdx] = cur;
  } else {
    KKTimingSegment *cur = [segs[_dragSegIdx] copy];
    if ((NSUInteger)_dragSegIdx + 1 < segs.count) {
      KKTimingSegment *next = [segs[_dragSegIdx + 1] copy];
      newFrac = MAX(cur.start + minFrac, MIN(next.end - minFrac, newFrac));
      cur.end = newFrac;
      next.start = newFrac;
      segs[_dragSegIdx + 1] = next;
    } else {
      newFrac = MAX(cur.start + minFrac, MIN(1.0, newFrac));
      cur.end = newFrac;
    }
    segs[_dragSegIdx] = cur;
  }

  lane.segments = segs;
  lanes[_dragLaneIdx] = lane;
}

- (void)mouseUp:(NSEvent *)event {
  if (_scrubbingRuler) {
    _scrubbingRuler = NO;
    return;
  }
  if (_dragLaneMoving) {
    _dragLaneMoving = NO;
    _dragLaneMoveOrigSegs = nil;
    [[NSCursor arrowCursor] set];
    if ((NSUInteger)_dragLaneIdx < self.lanes.count && self.onLaneChanged)
      self.onLaneChanged(_dragLaneIdx, self.lanes[_dragLaneIdx]);
    return;
  }
  if (_dragMoving) {
    BOOL moved = NO;
    if ((NSUInteger)_dragLaneIdx < self.lanes.count) {
      KKTimingSegment *seg = self.lanes[_dragLaneIdx].segments[_dragSegIdx];
      moved = (fabs(seg.start - _dragMoveOrigStart) > 0.001);
    }
    _dragMoving = NO;
    [[NSCursor arrowCursor] set];
    if (moved && (NSUInteger)_dragLaneIdx < self.lanes.count &&
        self.onLaneChanged)
      self.onLaneChanged(_dragLaneIdx, self.lanes[_dragLaneIdx]);
    return;
  }
  if (_dragging) {
    _dragging = NO;
    [[NSCursor arrowCursor] set];
    _hoveringEdge = NO;
    if ((NSUInteger)_dragLaneIdx < self.lanes.count && self.onLaneChanged)
      self.onLaneChanged(_dragLaneIdx, self.lanes[_dragLaneIdx]);
  }
}

@end
#pragma clang diagnostic pop
