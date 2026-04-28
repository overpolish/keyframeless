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

    NSEvent *cur = [NSApp currentEvent];
    if ((cur.modifierFlags & NSEventModifierFlagShift)) {
      [self _captureBulkEdgeTargetsForOrigFrac:(onLeft ? seg.start : seg.end)
                                   leadingEdge:onLeft];
      _bulkEdgeAlign = (cur.modifierFlags & NSEventModifierFlagOption) != 0;
    }
    return YES;
  }
  return NO;
}

/// Walk every lane and pick the boundary closest to `origFrac` (interior
/// boundaries only — frac 0 and 1 don't count). Stored alongside the dragged
/// boundary so a Shift+edge-drag moves the corresponding boundary in each
/// lane by the same offset.
- (void)_captureBulkEdgeTargetsForOrigFrac:(double)origFrac
                               leadingEdge:(BOOL)leadingEdge {
  NSMutableArray<NSValue *> *targets = [NSMutableArray array];
  for (NSUInteger li = 0; li < self.lanes.count; li++) {
    KKTimingLane *lane = self.lanes[li];
    if (lane.segments.count < 2)
      continue;
    NSInteger bestB = -1;
    double bestDelta = INFINITY;
    BOOL bestIsLeftSide = NO;
    for (NSUInteger b = 1; b < lane.segments.count; b++) {
      double frac = lane.segments[b].start;
      double d = fabs(frac - origFrac);
      BOOL isLeftSide = (frac <= origFrac);
      if (d + 1e-9 < bestDelta) {
        bestDelta = d;
        bestB = (NSInteger)b;
        bestIsLeftSide = isLeftSide;
      } else if (fabs(d - bestDelta) < 1e-9) {
        // Tiebreak: prefer the side matching the dragged edge type.
        BOOL prefersLeft = leadingEdge;
        if (prefersLeft && isLeftSide && !bestIsLeftSide) {
          bestB = (NSInteger)b;
          bestIsLeftSide = isLeftSide;
        } else if (!prefersLeft && !isLeftSide && bestIsLeftSide) {
          bestB = (NSInteger)b;
          bestIsLeftSide = isLeftSide;
        }
      }
    }
    if (bestB < 0)
      continue;
    double frac = lane.segments[bestB].start;
    [targets
        addObject:[NSValue valueWithRect:NSMakeRect((CGFloat)li, (CGFloat)bestB,
                                                    frac, 0)]];
  }
  if (targets.count == 0)
    return;
  _bulkEdgeDrag = YES;
  _bulkEdgeOrigFrac = origFrac;
  _bulkEdgeTargets = targets;
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

    NSEventModifierFlags shiftCtrl =
        NSEventModifierFlagShift | NSEventModifierFlagControl;
    if ((event.modifierFlags & shiftCtrl) == shiftCtrl) {
      if (self.onAllLanesSegmentLockToggled) {
        double frac = [self _fracForX:loc.x
                               trackX:trackX
                           trackWidth:trackWidth];
        BOOL lock = (seg.lockedDurationSeconds == 0);
        self.onAllLanesSegmentLockToggled(frac, lock);
      }
      return YES;
    }

    // Plain shift+click (no other modifiers) → bulk-select one segment per
    // lane at the click fraction. Must check after shift+ctrl so the lock
    // gesture wins.
    if ((event.modifierFlags & NSEventModifierFlagShift) &&
        !(event.modifierFlags &
          (NSEventModifierFlagCommand | NSEventModifierFlagOption |
           NSEventModifierFlagControl))) {
      if (self.onAllLanesSegmentSelected) {
        double frac = [self _fracForX:loc.x
                               trackX:trackX
                           trackWidth:trackWidth];
        self.onAllLanesSegmentSelected(frac);
      }
      return YES;
    }

    NSEventModifierFlags shiftCmd =
        NSEventModifierFlagShift | NSEventModifierFlagCommand;
    if ((event.modifierFlags & shiftCmd) == shiftCmd) {
      if (self.onAllLanesSegmentRemoved) {
        double frac = [self _fracForX:loc.x
                               trackX:trackX
                           trackWidth:trackWidth];
        self.onAllLanesSegmentRemoved(frac);
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
      // Defer the lane-move until the cursor passes the drag threshold.
      // A pure click (mouseUp before threshold) becomes a lock toggle.
      _pendingCtrlClick = YES;
      _pendingCtrlLaneIdx = (NSInteger)laneIdx;
      _pendingCtrlSegIdx = (NSInteger)segIdx;
      _pendingCtrlStartLoc = loc;
      _dragLaneIdx = laneIdx;
      _dragTrackX = trackX;
      _dragTrackWidth = trackWidth;
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
  double minSecFrac =
      self.effectDuration > 0 ? kKSSMinSegmentSec / self.effectDuration : 0.0;
  double minFrac = MAX(minSecFrac, minPx);

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
  double minSecFrac =
      self.effectDuration > 0 ? kKSSMinSegmentSec / self.effectDuration : 0.0;
  double minFrac = MAX(minSecFrac, minPx);

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

- (void)_applyBulkEdgeDragWithFrac:(double)newFrac
                             lanes:(NSMutableArray<KKTimingLane *> *)lanes {
  double minPx = kKSSMinSegmentPx / (_dragTrackWidth * _zoom);
  double minSecFrac =
      self.effectDuration > 0 ? kKSSMinSegmentSec / self.effectDuration : 0.0;
  double minFrac = MAX(minSecFrac, minPx);

  // Snap the dragged anchor to playhead / 0 / 1 only. Other-lane boundaries
  // are themselves moving with the bulk drag, so snapping to them would be
  // sticky and self-referential. Shift is already consumed for bulk mode so
  // snap is always enabled here.
  BOOL didSnap = NO;
  double snapTarget = newFrac;
  double snapPxFrac = kKSSSnapPx / (_dragTrackWidth * _zoom);
  double bestDelta = snapPxFrac;
  double snapCandidates[] = {0.0, 1.0, self.playheadFraction};
  for (NSUInteger i = 0; i < sizeof(snapCandidates) / sizeof(snapCandidates[0]);
       i++) {
    double cand = snapCandidates[i];
    if (cand < 0.0 || cand > 1.0)
      continue;
    double d = fabs(cand - newFrac);
    if (d < bestDelta) {
      bestDelta = d;
      snapTarget = cand;
      didSnap = YES;
    }
  }
  if (didSnap)
    newFrac = snapTarget;

  // Offset mode: group stops when any lane hits min-length, so per-lane
  // offsets stay locked. Align mode: each lane independently clamps to its
  // own [leftStart+minFrac, rightEnd-minFrac] window so the dragged frac
  // becomes a target rather than a uniform offset.
  double offset = 0;
  if (!_bulkEdgeAlign) {
    double desiredOffset = newFrac - _bulkEdgeOrigFrac;
    double offsetMin = -INFINITY;
    double offsetMax = INFINITY;
    for (NSValue *v in _bulkEdgeTargets) {
      NSRect r = v.rectValue;
      NSInteger li = (NSInteger)r.origin.x;
      NSInteger b = (NSInteger)r.origin.y;
      double origFrac = (double)r.size.width;
      if ((NSUInteger)li >= lanes.count)
        continue;
      KKTimingLane *lane = lanes[li];
      if ((NSUInteger)b >= lane.segments.count || b < 1)
        continue;
      double leftStart = lane.segments[b - 1].start;
      double rightEnd = lane.segments[b].end;
      double laneOffsetMin = (leftStart + minFrac) - origFrac;
      double laneOffsetMax = (rightEnd - minFrac) - origFrac;
      if (laneOffsetMin > offsetMin)
        offsetMin = laneOffsetMin;
      if (laneOffsetMax < offsetMax)
        offsetMax = laneOffsetMax;
    }
    offset = MAX(offsetMin, MIN(offsetMax, desiredOffset));
  }

  for (NSValue *v in _bulkEdgeTargets) {
    NSRect r = v.rectValue;
    NSInteger li = (NSInteger)r.origin.x;
    NSInteger b = (NSInteger)r.origin.y;
    double origFrac = (double)r.size.width;
    if ((NSUInteger)li >= lanes.count)
      continue;
    KKTimingLane *lane = [lanes[li] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
    if ((NSUInteger)b >= segs.count || b < 1)
      continue;
    double newBoundary;
    if (_bulkEdgeAlign) {
      double leftStart = segs[b - 1].start;
      double rightEnd = segs[b].end;
      newBoundary = MAX(leftStart + minFrac, MIN(rightEnd - minFrac, newFrac));
    } else {
      newBoundary = origFrac + offset;
    }
    KKTimingSegment *left = [segs[b - 1] copy];
    KKTimingSegment *right = [segs[b] copy];
    left.end = newBoundary;
    right.start = newBoundary;
    segs[b - 1] = left;
    segs[b] = right;
    lane.segments = segs;
    lanes[li] = lane;
  }

  // Drive the snap guide overlay. In offset mode the dragged anchor lands at
  // origFrac+offset; the snap holds only if that matches the snap target.
  // In align mode every target is clamped to newFrac, so the guide just
  // mirrors the snapped frac.
  if (didSnap) {
    double anchor = _bulkEdgeAlign ? newFrac : (_bulkEdgeOrigFrac + offset);
    if (fabs(anchor - snapTarget) < 1e-6) {
      _snapActive = YES;
      _snapFrac = snapTarget;
    } else {
      _snapActive = NO;
    }
  } else {
    _snapActive = NO;
  }
}

@end
#pragma clang diagnostic pop
