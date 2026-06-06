/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineAdvancedView_Private.h"

@implementation KKTimelineAdvancedView (Guide)

- (NSRect)guideLaneRowScreenRectForLabel:(NSString *)label {
  NSWindow *w = self.window;
  NSInteger i = [self _animatableIndexForLabel:label];
  NSInteger n = [self _animatableCount];
  if (!w || i < 0 || n <= 0)
    return NSZeroRect;
  NSRect r = [self _rowRectForIndex:i count:n];
  NSRect inWin = [self convertRect:r toView:nil];
  return [w convertRectToScreen:inWin];
}

- (NSRect)guideKeyposeScreenRectForLabel:(NSString *)label
                                 atIndex:(NSInteger)kpIdx {
  KKLane *lane = [self _animatableLaneForLabel:label];
  if (!lane || kpIdx < 0 || kpIdx >= (NSInteger)lane.keyposes.count)
    return NSZeroRect;
  return [self guideKeyposeScreenRectForLabel:label
                                   atFraction:lane.keyposes[kpIdx].time];
}

- (NSRect)guideKeyposeScreenRectForLabel:(NSString *)label
                              atFraction:(double)frac {
  NSWindow *w = self.window;
  NSInteger i = [self _animatableIndexForLabel:label];
  NSInteger n = [self _animatableCount];
  if (!w || i < 0 || n <= 0)
    return NSZeroRect;
  NSRect row = [self _rowRectForIndex:i count:n];
  NSRect tracks = [self _tracksRect];
  if (NSWidth(tracks) <= 0)
    return NSZeroRect;
  CGFloat x = [self _xForFrac:frac inTracks:tracks];
  CGFloat halo = 4.0;
  NSRect view = NSMakeRect(x - kPillW * 0.5 - halo, NSMinY(row) - halo,
                           kPillW + 2.0 * halo, NSHeight(row) + 2.0 * halo);
  NSRect inWin = [self convertRect:view toView:nil];
  return [w convertRectToScreen:inWin];
}

- (double)guideKeyposeFractionForLabel:(NSString *)label
                               atIndex:(NSInteger)kpIdx {
  KKLane *lane = [self _animatableLaneForLabel:label];
  if (!lane || kpIdx < 0 || kpIdx >= (NSInteger)lane.keyposes.count)
    return NAN;
  return lane.keyposes[kpIdx].time;
}

- (NSInteger)guideSelectedKeyposeIndexNearestFraction:(double)frac
                                             forLabel:(NSString *)label {
  KKLane *lane = [self _animatableLaneForLabel:label];
  if (!lane)
    return NSNotFound;
  NSInteger best = NSNotFound;
  double bestDist = INFINITY;
  for (NSInteger j = 0; j < (NSInteger)lane.keyposes.count; j++) {
    if (![self _pillSelected:lane atIdx:j])
      continue;
    double d = fabs(lane.keyposes[j].time - frac);
    if (d < bestDist) {
      bestDist = d;
      best = j;
    }
  }
  return best;
}

- (BOOL)guideBeginPillDragForLabel:(NSString *)label
                           atIndex:(NSInteger)kpIdx
                     atScreenPoint:(NSPoint)screenPoint {
  KKLane *lane = [self _animatableLaneForLabel:label];
  if (!lane || kpIdx < 0 || kpIdx >= (NSInteger)lane.keyposes.count)
    return NO;
  NSWindow *w = self.window;
  if (!w)
    return NO;
  NSPoint inWin = [w convertPointFromScreen:screenPoint];
  NSPoint pt = [self convertPoint:inWin fromView:nil];

  _pressLaneLabel = [label copy];
  _pressKPIdx = kpIdx;
  _pressPoint = pt;
  _topLaneLabel = _pressLaneLabel;
  _topKPIdx = kpIdx;
  _dragActive = YES;
  if (self.onDragBegin)
    self.onDragBegin();
  // Run an immediate tick so the first frame snaps to the cursor (matches
  // mouseDown → mouseDragged for a real drag).
  [self guideDragPillToScreenPoint:screenPoint];
  return YES;
}

- (void)guideDragPillToScreenPoint:(NSPoint)screenPoint {
  if (!_pressLaneLabel || !_dragActive)
    return;
  NSWindow *w = self.window;
  if (!w)
    return;
  NSPoint inWin = [w convertPointFromScreen:screenPoint];
  NSPoint pt = [self convertPoint:inWin fromView:nil];
  NSRect tracks = [self _tracksRect];
  double newFrac = [self _fracForX:pt.x inTracks:tracks];
  newFrac = [self _snappedDragFracForX:pt.x
                                  frac:newFrac
                              inTracks:tracks
                              skipLane:_pressLaneLabel
                                skipKP:_pressKPIdx];
  NSInteger after = [self _moveKPInLaneLabel:_pressLaneLabel
                                       kpIdx:_pressKPIdx
                                      toFrac:newFrac];
  if (after >= 0 && after != _pressKPIdx) {
    _pressKPIdx = after;
    _topKPIdx = after;
  }
}

- (void)guideEndPillDrag {
  if (!_dragActive)
    return;
  _dragActive = NO;
  _pressLaneLabel = nil;
  _pressKPIdx = -1;
  if (self.onDragEnd)
    self.onDragEnd();
}

- (NSRect)guideMarqueeTargetScreenRectAtFraction:(double)frac {
  NSWindow *w = self.window;
  if (!w)
    return NSZeroRect;
  NSRect tracks = [self _tracksRect];
  if (NSWidth(tracks) <= 0 || NSHeight(tracks) <= 0)
    return NSZeroRect;
  CGFloat x = [self _xForFrac:frac inTracks:tracks];
  // Vertically centred in the tracks so the guide's start->target line is a
  // straight horizontal sweep (the box itself still spans every row, set in
  // guideBeginMarquee). The start zone is also full-height-centred, so both
  // ends share this midline.
  CGFloat y = NSMidY(tracks);
  NSRect view = NSMakeRect(x - 7.0, y - 7.0, 14.0, 14.0);
  return [w convertRectToScreen:[self convertRect:view toView:nil]];
}

- (NSRect)guideTracksRegionScreenRectFromFraction:(double)fa
                                       toFraction:(double)fb {
  NSWindow *w = self.window;
  if (!w)
    return NSZeroRect;
  NSRect tracks = [self _tracksRect];
  if (NSWidth(tracks) <= 0 || NSHeight(tracks) <= 0)
    return NSZeroRect;
  CGFloat xa = [self _xForFrac:fa inTracks:tracks];
  CGFloat xb = [self _xForFrac:fb inTracks:tracks];
  NSRect view = NSMakeRect(MIN(xa, xb), NSMinY(tracks), fabs(xb - xa),
                           NSHeight(tracks));
  return [w convertRectToScreen:[self convertRect:view toView:nil]];
}

- (void)guideBeginMarqueeAtScreenPoint:(NSPoint)screenPoint {
  NSWindow *w = self.window;
  if (!w)
    return;
  NSPoint pt = [self convertPoint:[w convertPointFromScreen:screenPoint]
                         fromView:nil];
  NSRect tracks = [self _tracksRect];
  [_selection removeAllObjects];
  [_selectedGaps removeAllObjects];
  _marqueeShift = NO;
  _marqueeActive = YES;
  // Anchor the box at the press x but pin it to span every row vertically (top
  // to bottom of the tracks), so the guide drag only has to sweep horizontally
  // to enclose keyposes across all lanes.
  _marqueeAnchor = NSMakePoint(pt.x, NSMaxY(tracks));
  _marqueeCurrent = NSMakePoint(pt.x, NSMinY(tracks));
  [self setNeedsDisplay:YES];
}

- (void)guideDragMarqueeToScreenPoint:(NSPoint)screenPoint {
  if (!_marqueeActive)
    return;
  NSWindow *w = self.window;
  if (!w)
    return;
  NSPoint pt = [self convertPoint:[w convertPointFromScreen:screenPoint]
                         fromView:nil];
  NSRect tracks = [self _tracksRect];
  _marqueeCurrent = NSMakePoint(pt.x, NSMinY(tracks));
  [self setNeedsDisplay:YES];
}

- (void)guideEndMarquee {
  if (!_marqueeActive)
    return;
  NSRect r = NSMakeRect(MIN(_marqueeAnchor.x, _marqueeCurrent.x),
                        MIN(_marqueeAnchor.y, _marqueeCurrent.y),
                        fabs(_marqueeAnchor.x - _marqueeCurrent.x),
                        fabs(_marqueeAnchor.y - _marqueeCurrent.y));
  [_selection removeAllObjects];
  [_selectedGaps removeAllObjects];
  [self _addPillsInRect:r toSelection:_selection];
  _marqueeActive = NO;
  [self setNeedsDisplay:YES];
}

- (BOOL)guideBeginSelectionDragForLabel:(NSString *)label
                                atIndex:(NSInteger)kpIdx
                          atScreenPoint:(NSPoint)screenPoint {
  NSWindow *w = self.window;
  if (!w)
    return NO;
  NSString *key = [self _selectionKeyForLabel:label kpIdx:kpIdx];
  if (![_selection containsObject:key])
    return NO;
  NSPoint pt = [self convertPoint:[w convertPointFromScreen:screenPoint]
                         fromView:nil];
  _pressLaneLabel = [label copy];
  _pressKPIdx = kpIdx;
  _pressPoint = pt;
  _topLaneLabel = _pressLaneLabel;
  _topKPIdx = kpIdx;
  _dragActive = YES;
  // Snapshot every selected pill's start time + the press fraction, exactly as
  // -mouseDragged: does when a press lands on an already-selected pill - the
  // delta from these origins drives _moveSelectionByDelta:.
  [_dragOriginTimes removeAllObjects];
  for (NSString *k in _selection) {
    NSString *kLabel;
    NSInteger idx;
    if (![self _decodeSelectionKey:k label:&kLabel kpIdx:&idx])
      continue;
    for (KKLane *lane in _timeline.lanes) {
      if (![lane.label isEqualToString:kLabel])
        continue;
      if (idx >= 0 && idx < (NSInteger)lane.keyposes.count)
        _dragOriginTimes[k] = @(lane.keyposes[idx].time);
      break;
    }
  }
  _dragOriginFrac = [self _fracForX:_pressPoint.x inTracks:[self _tracksRect]];
  if (self.onDragBegin)
    self.onDragBegin();
  return YES;
}

- (void)guideDragSelectionToScreenPoint:(NSPoint)screenPoint {
  if (!_dragActive || _dragOriginTimes.count == 0)
    return;
  NSWindow *w = self.window;
  if (!w)
    return;
  NSPoint pt = [self convertPoint:[w convertPointFromScreen:screenPoint]
                         fromView:nil];
  double newFrac = [self _fracForX:pt.x inTracks:[self _tracksRect]];
  [self _moveSelectionByDelta:(newFrac - _dragOriginFrac)];
}

- (void)guideEndSelectionDrag {
  if (!_dragActive)
    return;
  _dragActive = NO;
  _pressLaneLabel = nil;
  _pressKPIdx = -1;
  [_dragOriginTimes removeAllObjects];
  [self setNeedsDisplay:YES];
  if (self.onDragEnd)
    self.onDragEnd();
}

@end
