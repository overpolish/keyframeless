/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKStageSequencerView (InteractionDrag)

/// Returns `frac` snapped to the nearest boundary in another lane, the
/// playhead, or 0/1, within `kKSSSnapPx` screen pixels. When no snap
/// applies (or `enabled` is NO), returns `frac` unchanged. On a successful
/// snap, sets `*outSnapped` to YES and stores the target fraction.
- (double)_snappedFrac:(double)frac
               enabled:(BOOL)enabled
           excludeLane:(NSInteger)excludeLaneIdx
                trackX:(CGFloat)trackX
            trackWidth:(CGFloat)trackWidth
            outSnapped:(BOOL *)outSnapped
               outFrac:(double *)outFrac {
  if (outSnapped)
    *outSnapped = NO;
  if (!enabled)
    return frac;

  double threshFrac = kKSSSnapPx / (trackWidth * _zoom);
  __block double bestDelta = threshFrac;
  __block double best = frac;
  __block BOOL found = NO;

  void (^consider)(double) = ^(double target) {
    double d = fabs(target - frac);
    if (d < bestDelta) {
      bestDelta = d;
      best = target;
      found = YES;
    }
  };

  consider(0.0);
  consider(1.0);
  if (self.playheadFraction >= 0.0 && self.playheadFraction <= 1.0)
    consider(self.playheadFraction);

  for (NSUInteger li = 0; li < self.lanes.count; li++) {
    if ((NSInteger)li == excludeLaneIdx)
      continue;
    KKTimingLane *lane = self.lanes[li];
    for (KKTimingSegment *seg in lane.segments) {
      consider(seg.start);
      consider(seg.end);
    }
  }

  if (found) {
    if (outSnapped)
      *outSnapped = YES;
    if (outFrac)
      *outFrac = best;
    return best;
  }
  return frac;
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

    if (event.modifierFlags & NSEventModifierFlagShift) {
      // Shift+click a segment body → toggle duration lock. Fires on
      // mouseDown rather than mouseUp so it doesn't compete with the
      // in-drag "shift disables snap" behaviour on edge resize.
      if (self.onSegmentLockToggled) {
        double newLocked = (seg.lockedDurationSeconds > 0)
                               ? 0.0
                               : (seg.end - seg.start) * self.effectDuration;
        self.onSegmentLockToggled(laneIdx, segIdx, newLocked);
      }
      return YES;
    }

    if ((event.modifierFlags & NSEventModifierFlagCommand) &&
        lane.segments.count > 1) {
      if (self.onSegmentRemoved)
        self.onSegmentRemoved(laneIdx, segIdx);
      return YES;
    }

    if (event.modifierFlags & NSEventModifierFlagOption) {
      _dragValueCopying = YES;
      _dragCopyLaneIdx = (NSInteger)laneIdx;
      _dragCopySrcSegIdx = (NSInteger)segIdx;
      _dragCopyDstSegIdx = -1;
      _hoverSegLaneIdx = -1;
      _hoverSegSegIdx = -1;
      [[NSCursor dragCopyCursor] set];
      [self renderLanes];
      return YES;
    }

    if (event.modifierFlags & NSEventModifierFlagControl) {
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

- (void)_dragValueCopyToEvent:(NSEvent *)event {
  [[NSCursor dragCopyCursor] set];
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger hoverLane = -1, hoverSeg = -1;
  [self _segmentUnderPoint:loc outLane:&hoverLane outSeg:&hoverSeg];
  // Only same-lane, non-source segments are valid drop targets.
  if (hoverLane != _dragCopyLaneIdx || hoverSeg == _dragCopySrcSegIdx)
    hoverSeg = -1;
  if (hoverSeg != _dragCopyDstSegIdx) {
    _dragCopyDstSegIdx = hoverSeg;
    [self renderLanes];
  }
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

  // Snap: for each boundary of the shifted lane, find the best snap.
  // Apply the smallest residual shift that lands any boundary on a target.
  BOOL snapEnabled = !(event.modifierFlags & NSEventModifierFlagShift);
  _snapActive = NO;
  if (snapEnabled) {
    double bestShift = 0;
    double bestAbs = INFINITY;
    double bestTarget = 0;
    NSMutableArray<NSNumber *> *boundaries = [NSMutableArray array];
    for (KKTimingSegment *s in _dragLaneMoveOrigSegs)
      [boundaries addObject:@(s.start + delta)];
    KKTimingSegment *lastSeg = _dragLaneMoveOrigSegs.lastObject;
    if (lastSeg)
      [boundaries addObject:@(lastSeg.end + delta)];

    for (NSNumber *b in boundaries) {
      BOOL snapped = NO;
      double target = b.doubleValue;
      [self _snappedFrac:b.doubleValue
                 enabled:YES
             excludeLane:_dragLaneIdx
                  trackX:_dragTrackX
              trackWidth:_dragTrackWidth
              outSnapped:&snapped
                 outFrac:&target];
      if (snapped) {
        double shift = target - b.doubleValue;
        if (fabs(shift) < bestAbs) {
          bestAbs = fabs(shift);
          bestShift = shift;
          bestTarget = target;
        }
      }
    }
    if (bestAbs < INFINITY) {
      double proposed = delta + bestShift;
      // Re-check the 0/1 bounds with the shift applied.
      if (firstStart + proposed >= 0 && lastEnd + proposed <= 1.0) {
        delta = proposed;
        _snapActive = YES;
        _snapFrac = bestTarget;
      }
    }
  }

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
                      snapEnabled:(BOOL)snapEnabled
                            lanes:(NSMutableArray<KKTimingLane *> *)lanes {
  [[NSCursor closedHandCursor] set];
  KKTimingLane *lane = [lanes[_dragLaneIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];

  double delta = newFrac - _dragMoveStartFrac;
  double newStart = _dragMoveOrigStart + delta;
  double newEnd = _dragMoveOrigEnd + delta;
  double segSize = _dragMoveOrigEnd - _dragMoveOrigStart;

  // Snap: try start and end edges, pick whichever snaps with smaller shift.
  {
    BOOL snapStart = NO, snapEnd = NO;
    double snapStartFrac = newStart, snapEndFrac = newEnd;
    [self _snappedFrac:newStart
               enabled:snapEnabled
           excludeLane:_dragLaneIdx
                trackX:_dragTrackX
            trackWidth:_dragTrackWidth
            outSnapped:&snapStart
               outFrac:&snapStartFrac];
    [self _snappedFrac:newEnd
               enabled:snapEnabled
           excludeLane:_dragLaneIdx
                trackX:_dragTrackX
            trackWidth:_dragTrackWidth
            outSnapped:&snapEnd
               outFrac:&snapEndFrac];
    double dStart = snapStart ? fabs(snapStartFrac - newStart) : INFINITY;
    double dEnd = snapEnd ? fabs(snapEndFrac - newEnd) : INFINITY;
    if (dStart <= dEnd && snapStart) {
      double shift = snapStartFrac - newStart;
      newStart += shift;
      newEnd += shift;
      _snapActive = YES;
      _snapFrac = snapStartFrac;
    } else if (snapEnd) {
      double shift = snapEndFrac - newEnd;
      newStart += shift;
      newEnd += shift;
      _snapActive = YES;
      _snapFrac = snapEndFrac;
    }
  }

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

  // If neighbor clamps displaced both edges away from the snap target, the
  // snap no longer holds — drop the guide.
  if (_snapActive && fabs(newStart - _snapFrac) > 1e-6 &&
      fabs(newEnd - _snapFrac) > 1e-6)
    _snapActive = NO;
}

- (void)_applyEdgeDragWithFrac:(double)newFrac
                   snapEnabled:(BOOL)snapEnabled
                         lanes:(NSMutableArray<KKTimingLane *> *)lanes {
  KKTimingLane *lane = [lanes[_dragLaneIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];

  double minPx = kKSSMinSegmentPx / (_dragTrackWidth * _zoom);
  double minFrac = MAX(kKSSMinSegmentFrac, minPx);

  BOOL didSnap = NO;
  double snapTarget = newFrac;
  newFrac = [self _snappedFrac:newFrac
                       enabled:snapEnabled
                   excludeLane:_dragLaneIdx
                        trackX:_dragTrackX
                    trackWidth:_dragTrackWidth
                    outSnapped:&didSnap
                       outFrac:&snapTarget];

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

  // Only show the snap guide if the snapped fraction survived clamping.
  if (didSnap && fabs(newFrac - snapTarget) < 1e-6) {
    _snapActive = YES;
    _snapFrac = snapTarget;
  }
}

@end
#pragma clang diagnostic pop
