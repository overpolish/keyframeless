/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCheckboxView.h"
#import "KKTimelineBasicView+Guide.h"
#import "KKTimelineBasicView_Private.h"

@implementation KKTimelineBasicView (Guide)

@dynamic onPhaseToggled;
@dynamic onDiamondTapped;
@dynamic onGapTapped;

- (NSRect)guidePhaseToggleScreenRectForPhase:(NSInteger)phase {
  KKCheckboxView *check =
      (phase == 0) ? _inCheck : (phase == 1 ? _outCheck : nil);
  NSTextField *label = (phase == 0) ? _inLabel : (phase == 1 ? _outLabel : nil);
  NSWindow *w = self.window;
  if (!check || !label || !w)
    return NSZeroRect;
  NSRect cb = [self convertRect:check.frame toView:nil];
  NSRect lb = [self convertRect:label.frame toView:nil];
  return [w convertRectToScreen:NSUnionRect(cb, lb)];
}

- (void (^)(NSInteger, BOOL))onPhaseToggled {
  return _onPhaseToggled;
}

- (void)setOnPhaseToggled:(void (^)(NSInteger, BOOL))onPhaseToggled {
  _onPhaseToggled = [onPhaseToggled copy];
}

- (void (^)(NSInteger))onDiamondTapped {
  return _onDiamondTapped;
}

- (void)setOnDiamondTapped:(void (^)(NSInteger))onDiamondTapped {
  _onDiamondTapped = [onDiamondTapped copy];
}

- (void (^)(NSInteger))onGapTapped {
  return _onGapTapped;
}

- (void)setOnGapTapped:(void (^)(NSInteger))onGapTapped {
  _onGapTapped = [onGapTapped copy];
}

- (NSRect)guideGapScreenRectForSection:(NSInteger)section {
  NSWindow *w = self.window;
  if (!w || section < 1 || section > 3)
    return NSZeroRect;
  NSRect g = [self _graphRect];
  if (NSWidth(g) <= 0 || NSHeight(g) <= 0)
    return NSZeroRect;
  KKBasicProj p = [self _projection];
  if ((section == KKBasicSectionIn && !p.inEnabled) ||
      (section == KKBasicSectionOut && !p.outEnabled))
    return NSZeroRect;
  // Section x-extent in fraction space, then convert to view points via
  // KKBasicXForFrac so zoom/pan/warp are honoured.
  double f0, f1;
  if (section == KKBasicSectionIn) {
    f0 = 0.0;
    f1 = p.inEndFrac;
  } else if (section == KKBasicSectionOut) {
    f0 = p.outStartFrac;
    f1 = 1.0;
  } else {
    f0 = p.inEndFrac;
    f1 = p.outStartFrac;
  }
  CGFloat x0 = KKBasicXForFrac(f0, g, p);
  CGFloat x1 = KKBasicXForFrac(f1, g, p);
  NSRect view = NSMakeRect(MIN(x0, x1), NSMinY(g), fabs(x1 - x0), NSHeight(g));
  NSRect win = [self convertRect:view toView:nil];
  return [w convertRectToScreen:win];
}

- (CGFloat)guideScreenXForTimeSeconds:(double)seconds {
  NSWindow *w = self.window;
  NSRect g = [self _graphRect];
  double dur = [self _clipDuration];
  if (!w || NSWidth(g) <= 0 || dur <= 0)
    return NAN;
  double frac = MAX(0.0, MIN(1.0, seconds / dur));
  KKBasicProj p = [self _projection];
  CGFloat viewX = KKBasicXForFrac(frac, g, p);
  NSPoint inWin = [self convertPoint:NSMakePoint(viewX, 0) toView:nil];
  return [w convertPointToScreen:inWin].x;
}

- (NSRect)guideDiamondScreenRectAtTimeSeconds:(double)seconds
                                   forDiamond:(NSInteger)idx {
  // Only the two middle diamonds (2 = Hold-start, 3 = Hold-end) move with
  // the In/Out duration. 1 and 4 are time-locked at 0 / 1.
  if (idx != 2 && idx != 3)
    return NSZeroRect;
  NSWindow *w = self.window;
  NSRect g = [self _graphRect];
  double dur = [self _clipDuration];
  if (!w || NSWidth(g) <= 0 || dur <= 0)
    return NSZeroRect;
  double frac = MAX(0.0, MIN(1.0, seconds / dur));
  KKBasicProj p = [self _projection];
  double lo = 0.0, hi = 1.0;
  KKBasicValueExtent(p, &lo, &hi);
  NSPoint c = KKBasicPoint(g, frac, KKBasicMotionY(frac, p), lo, hi, p);
  CGFloat r = kDiamondR + 6.0;
  NSRect view = NSMakeRect(c.x - r, c.y - r, 2 * r, 2 * r);
  NSRect inWin = [self convertRect:view toView:nil];
  return [w convertRectToScreen:inWin];
}

- (BOOL)guideBeginDragDiamondAtIndex:(NSInteger)idx
                       atScreenPoint:(NSPoint)screenPoint {
  if (idx != 2 && idx != 3)
    return NO;
  KKBasicProj p = [self _projection];
  if ((idx == 2 && !p.inEnabled) || (idx == 3 && !p.outEnabled))
    return NO;
  _pressedDiamond = idx;
  _dragActive = YES;
  if (self.onDragBegin)
    self.onDragBegin();
  // Run an immediate drag tick so the first frame snaps to the cursor —
  // mirrors what mouseDown→mouseDragged does for a real drag.
  [self guideDragDiamondToScreenPoint:screenPoint];
  return YES;
}

- (void)guideDragDiamondToScreenPoint:(NSPoint)screenPoint {
  if (_pressedDiamond != 2 && _pressedDiamond != 3)
    return;
  NSWindow *w = self.window;
  if (!w)
    return;
  NSRect g = [self _graphRect];
  if (NSWidth(g) <= 0)
    return;
  KKBasicProj p = [self _projection];
  NSPoint inWin = [w convertPointFromScreen:screenPoint];
  NSPoint pt = [self convertPoint:inWin fromView:nil];
  double dur = [self _clipDuration];
  double minPh = (dur > 0.0) ? (kMinPhaseSeconds / dur) : kMinPhaseFrac;
  double zsolve = p.zoom > 0.0 ? p.zoom : 1.0;
  double targetU = MAX(
      0.0, MIN(1.0, p.panOffset + (pt.x - NSMinX(g)) / (zsolve * NSWidth(g))));
  double tIn = p.inEndFrac, tOut = p.outStartFrac;
  for (KKLane *lane in _timeline.lanes)
    if (lane.enabled && lane.keyposes.count >= 2) {
      KKHoldShape s = KKShapeOfLane(lane);
      tIn = lane.keyposes[s.holdStart].time;
      tOut = lane.keyposes[s.holdEnd].time;
      break;
    }
  if (_pressedDiamond == 2)
    tIn = KKBasicSolveBoundary(p, 2, targetU, minPh, tOut - kMinHoldFrac);
  else
    tOut = KKBasicSolveBoundary(p, 3, targetU, tIn + kMinHoldFrac, 1.0 - minPh);
  [self _rebuildInOn:p.inEnabled outOn:p.outEnabled tIn:tIn tOut:tOut];
}

- (void)guideEndDiamondDrag {
  if (_pressedDiamond != 2 && _pressedDiamond != 3)
    return;
  _pressedDiamond = 0;
  _dragActive = NO;
  if (self.onDragEnd)
    self.onDragEnd();
}

- (double)guideCurrentDiamondTimeSecondsForIndex:(NSInteger)idx {
  double dur = [self _clipDuration];
  if (dur <= 0)
    return NAN;
  // Read the stored Hold-pair time from the first animatable lane (matches
  // what the drag math uses as its baseline).
  for (KKLane *lane in _timeline.lanes) {
    if (lane.enabled && lane.keyposes.count >= 2) {
      KKHoldShape s = KKShapeOfLane(lane);
      if (idx == 2)
        return lane.keyposes[s.holdStart].time * dur;
      if (idx == 3)
        return lane.keyposes[s.holdEnd].time * dur;
      if (idx == 1)
        return 0.0;
      if (idx == 4)
        return dur;
    }
  }
  return NAN;
}

- (NSRect)guideDiamondScreenRectForIndex:(NSInteger)idx {
  NSWindow *w = self.window;
  if (!w || idx < 1 || idx > 4)
    return NSZeroRect;
  NSRect g = [self _graphRect];
  if (NSWidth(g) <= 0 || NSHeight(g) <= 0)
    return NSZeroRect;
  KKBasicProj p = [self _projection];
  // Match the visibility filter from -_diamondAtPoint:proj:rect:.
  BOOL enabled[4] = {p.inEnabled, p.anyAnimatable, p.anyAnimatable,
                     p.outEnabled};
  if (!enabled[idx - 1])
    return NSZeroRect;
  double lo = 0.0, hi = 1.0;
  KKBasicValueExtent(p, &lo, &hi);
  NSPoint c;
  switch (idx) {
  case 1:
    c = KKBasicPoint(g, 0.0, 0.0, lo, hi, p);
    break;
  case 2:
    c = KKBasicPoint(g, p.inEndFrac, KKBasicMotionY(p.inEndFrac, p), lo, hi, p);
    break;
  case 3:
    c = KKBasicPoint(g, p.outStartFrac, KKBasicMotionY(p.outStartFrac, p), lo,
                     hi, p);
    break;
  default:
    c = KKBasicPoint(g, 1.0, 0.0, lo, hi, p);
    break;
  }
  // Pad the cutout a few pts so the diamond reads as a glow target.
  CGFloat r = kDiamondR + 6.0;
  NSRect view = NSMakeRect(c.x - r, c.y - r, 2 * r, 2 * r);
  NSRect win = [self convertRect:view toView:nil];
  return [w convertRectToScreen:win];
}

@end
