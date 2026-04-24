/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKStageSequencerView (Interaction)

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
  if (self.onZoomPanChanged)
    self.onZoomPanChanged(_zoom, _panOffset);
}

- (void)scrollWheel:(NSEvent *)event {
  // Always forward to super so the enclosing NSScrollView gets a coherent
  // event stream (including zero-delta phase markers) — necessary for native
  // momentum to fire correctly on lift-off.
  [super scrollWheel:event];

  CGFloat dx = event.scrollingDeltaX;
  CGFloat dy = event.scrollingDeltaY;
  // Apply horizontal pan only when dx clearly dominates and we have a real
  // delta frame (not a phase marker).
  if (fabs(dx) <= fabs(dy) * 1.2 || (dx == 0 && dy == 0))
    return;

  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:NSWidth(self.bounds)
                        trackX:&trackX
                    trackWidth:&trackWidth];
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
  if (self.onZoomPanChanged)
    self.onZoomPanChanged(_zoom, _panOffset);
}

- (void)rightMouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  NSInteger laneIdx = -1, segIdx = -1;
  [self _segmentUnderPoint:loc outLane:&laneIdx outSeg:&segIdx];
  if (laneIdx < 0 || segIdx < 0)
    return;
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
    if (self.onSegmentEditRequested)
      self.onSegmentEditRequested(editLane, editSeg, editRect);
    return;
  }

  CGFloat totalWidth = NSWidth(self.bounds);
  CGFloat totalHeight = [self _totalHeight];
  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:totalWidth
                        trackX:&trackX
                    trackWidth:&trackWidth];

  for (NSUInteger laneIdx = 0; laneIdx < self.lanes.count; laneIdx++) {
    KKTimingLane *lane = self.lanes[laneIdx];
    CGFloat laneY = [self _laneYForIndex:laneIdx totalHeight:totalHeight];

    if (loc.y < laneY || loc.y > laneY + [self _laneHeight])
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
      double minFrac = MAX(kKSSMinSegmentFrac, minPx);
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

- (void)mouseDragged:(NSEvent *)event {
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
  } else {
    [self _applyEdgeDragWithFrac:newFrac snapEnabled:snapEnabled lanes:lanes];
  }
  self.lanes = lanes;
  [self renderLanes];
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

- (void)mouseUp:(NSEvent *)event {
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
    _dragging = NO;
    [[NSCursor arrowCursor] set];
    _hoveringEdge = NO;
    _snapActive = NO;
    if ((NSUInteger)_dragLaneIdx < self.lanes.count && self.onLaneChanged)
      self.onLaneChanged(_dragLaneIdx, self.lanes[_dragLaneIdx]);
  }
  if (wasDragging)
    [self renderLanes];
}

@end
#pragma clang diagnostic pop
