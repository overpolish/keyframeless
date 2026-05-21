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

@end
