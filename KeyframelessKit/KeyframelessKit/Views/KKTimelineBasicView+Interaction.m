/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineBasicView_Private.h"

#import "../Math/KKTimelineScale.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKKeyposeSymbol.h"
#import "KKMiniCanvasView.h"
#import "KKSegmentEditView.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

@implementation KKTimelineBasicView (Interaction)

- (KKBasicSection)_sectionAtPoint:(NSPoint)pt {
  NSRect g = [self _graphRect];
  // Track only — the ruler strip is the scrub zone, not part of the
  // In/Hold/Out hover area, so hovering it doesn't pop a duration readout.
  if (!NSPointInRect(pt, g) || NSWidth(g) <= 0)
    return KKBasicSectionNone;
  KKBasicProj p = [self _projection];
  // A disabled In/Out is rendered as flat hold, so its region hovers as
  // Hold (and the Hold readout below spans the merged flat extent).
  double frac = KKBasicFracForX(pt.x, g, p);
  if (frac < p.inEndFrac)
    return p.inEnabled ? KKBasicSectionIn : KKBasicSectionHold;
  if (frac < p.outStartFrac)
    return KKBasicSectionHold;
  return p.outEnabled ? KKBasicSectionOut : KKBasicSectionHold;
}

- (void)mouseMoved:(NSEvent *)event {
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  KKBasicSection s = [self _sectionAtPoint:pt];
  if (s != _hoverSection) {
    _hoverSection = s;
    [self setNeedsDisplay:YES];
  }
}

- (void)_notifyZoomChanged {
  BOOL zoomed = _zp.isZoomed;
  if (zoomed == _zoomedNotified)
    return;
  _zoomedNotified = zoomed;
  if (self.onZoomChanged)
    self.onZoomChanged(zoomed);
}

- (void)magnifyWithEvent:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  if (![_zp magnifyBy:event.magnification atX:loc.x inRect:[self _graphRect]])
    return;
  [self setNeedsDisplay:YES];
  [self _notifyZoomChanged];
}

// Forward to super first so the enclosing scroll view sees a coherent
// stream (momentum/phase markers). Only pan when the horizontal delta
// clearly dominates and it's a real delta frame.
- (void)scrollWheel:(NSEvent *)event {
  [super scrollWheel:event];
  CGFloat dx = event.scrollingDeltaX;
  CGFloat dy = event.scrollingDeltaY;
  if (fabs(dx) <= fabs(dy) * 1.2 || (dx == 0 && dy == 0))
    return;
  if (![_zp panByScrollDeltaX:dx
                      precise:event.hasPreciseScrollingDeltas
                       inRect:[self _graphRect]])
    return;
  [self setNeedsDisplay:YES];
  [self _notifyZoomChanged];
}

- (void)mouseExited:(NSEvent *)event {
  if (_hoverSection != KKBasicSectionNone) {
    _hoverSection = KKBasicSectionNone;
    [self setNeedsDisplay:YES];
  }
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

// Diamond index under `pt` (1 t=0, 2 t_inEnd, 3 t_outStart, 4 t=1), or 0.
- (NSInteger)_diamondAtPoint:(NSPoint)pt proj:(KKBasicProj)p rect:(NSRect)g {
  double lo = 0.0, hi = 1.0;
  KKBasicValueExtent(p, &lo, &hi);
  CGFloat hitR = kDiamondR + 5.0;
  NSPoint centers[4] = {
      KKBasicPoint(g, 0.0, 0.0, lo, hi, p),
      KKBasicPoint(g, p.inEndFrac, KKBasicMotionY(p.inEndFrac, p), lo, hi, p),
      KKBasicPoint(g, p.outStartFrac, KKBasicMotionY(p.outStartFrac, p), lo, hi,
                   p),
      KKBasicPoint(g, 1.0, 0.0, lo, hi, p),
  };
  // The Hold pair (indices 1,2) is always present/hittable; the In-start
  // (0) and Out-end (3) endpoints only when that phase is enabled.
  BOOL enabled[4] = {p.inEnabled, p.anyAnimatable, p.anyAnimatable,
                     p.outEnabled};
  for (NSInteger i = 0; i < 4; i++)
    if (enabled[i] && hypot(pt.x - centers[i].x, pt.y - centers[i].y) <= hitR)
      return i + 1;
  return 0;
}

// The two middle diamonds drag to set In/Out duration (endpoints are
// time-locked). A press that doesn't move opens the value popover for that
// boundary instead.
// YES if pt is in the ruler strip (above the track). The whole ruler is the
// scrub zone — click anywhere there to jump the playhead, then drag. It's
// separate from the track so it never conflicts with diamonds / gap clicks.
- (BOOL)_isInScrubBand:(NSPoint)pt rect:(NSRect)g {
  if (NSWidth(g) <= 0)
    return NO;
  return pt.x >= NSMinX(g) && pt.x <= NSMaxX(g) && pt.y >= NSMaxY(g) &&
         pt.y <= NSMaxY(g) + kRulerGap + kRulerH + 2.0;
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  NSRect g = [self _graphRect];
  _dragActive = NO;
  KKBasicProj p = [self _projection];
  _scrubbing = [self _isInScrubBand:pt rect:g];
  if (_scrubbing) {
    // Click-jump: move the playhead to the clicked position immediately,
    // then -mouseDragged: continues tracking. Update the visual optimistic-
    // ally (bypassing the setter, which ignores pushes while scrubbing).
    _pressedDiamond = 0;
    _pressPoint = pt;
    double frac = KKBasicFracForX(pt.x, g, p);
    _playheadFraction = frac;
    [self setNeedsDisplay:YES];
    if (self.onScrub)
      self.onScrub(frac);
    return;
  }
  _pressedDiamond =
      (NSWidth(g) > 0) ? [self _diamondAtPoint:pt proj:p rect:g] : 0;
  _pressPoint = pt;
}

- (void)mouseDragged:(NSEvent *)event {
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  NSRect g = [self _graphRect];
  if (NSWidth(g) <= 0)
    return;
  KKBasicProj p = [self _projection];
  if (_scrubbing) {
    // Playhead drag doesn't change the warp, so the plain live inverse
    // tracks the cursor exactly. Update the visual optimistically; the
    // host playhead follows via onScrub (render pushes are ignored here).
    double frac = KKBasicFracForX(pt.x, g, p);
    _playheadFraction = frac;
    [self setNeedsDisplay:YES];
    if (self.onScrub)
      self.onScrub(frac);
    return;
  }
  if (_pressedDiamond != 2 && _pressedDiamond != 3)
    return; // endpoints are time-locked; non-diamond presses do nothing
  // When a phase is off its Hold boundary is pinned to the clip edge — not a
  // draggable In/Out boundary. The press still falls through to mouseUp as a
  // click (→ Hold value popover).
  if ((_pressedDiamond == 2 && !p.inEnabled) ||
      (_pressedDiamond == 3 && !p.outEnabled))
    return;
  if (!_dragActive) {
    if (hypot(pt.x - _pressPoint.x, pt.y - _pressPoint.y) < 3.0)
      return; // not yet a drag — still a potential click
    _dragActive = YES;
    if (self.onDragBegin)
      self.onDragBegin();
  }
  // Minimum In/Out is an absolute duration, not a fixed fraction — a fixed
  // fraction makes the floor balloon on long clips (0.02·19.5s ≈ 0.4s).
  double dur = [self _clipDuration];
  double minPh = (dur > 0.0) ? (kMinPhaseSeconds / dur) : kMinPhaseFrac;
  // Boundary solve works in warped-u space; undo zoom/pan (not the log
  // warp) to get the target u the cursor maps to.
  double zsolve = p.zoom > 0.0 ? p.zoom : 1.0;
  double targetU = MAX(
      0.0, MIN(1.0, p.panOffset + (pt.x - NSMinX(g)) / (zsolve * NSWidth(g))));
  // Baseline must be the *stored* Hold-pair times, not p.inEndFrac /
  // p.outStartFrac — those are display-pinned to the clip edge when a phase
  // is off, and feeding 1.0 into the rebuild would park the hold-end keypose
  // at t=1 and make keypose-presence inference re-enable Out.
  double tIn = p.inEndFrac, tOut = p.outStartFrac;
  for (KKLane *lane in _timeline.lanes)
    if (lane.enabled && lane.keyposes.count >= 2) {
      KKHoldShape s = KKShapeOfLane(lane);
      tIn = lane.keyposes[s.holdStart].time;
      tOut = lane.keyposes[s.holdEnd].time;
      break;
    }
  // Solve the exact fraction that places the boundary under the cursor on
  // the LIVE log warp (the warp depends on it — so root-solve per frame
  // instead of one self-referential step that would ping).
  if (_pressedDiamond == 2)
    tIn = KKBasicSolveBoundary(p, 2, targetU, minPh, tOut - kMinHoldFrac);
  else
    tOut = KKBasicSolveBoundary(p, 3, targetU, tIn + kMinHoldFrac, 1.0 - minPh);
  [self _rebuildInOn:p.inEnabled outOn:p.outEnabled tIn:tIn tOut:tOut];
}

- (void)mouseUp:(NSEvent *)event {
  if (_scrubbing) {
    _scrubbing = NO;
    return;
  }
  if (_dragActive) {
    _dragActive = NO;
    _pressedDiamond = 0;
    if (self.onDragEnd)
      self.onDragEnd();
    return;
  }
  NSInteger d = _pressedDiamond;
  _pressedDiamond = 0;
  if (d != 0) {
    [self _openBoundaryPopoverForDiamond:d];
    return;
  }
  // Modifier comes from the system HID state — NSEvent flags read empty in
  // the plugin XPC.
  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  KKBasicSection sec = [self _sectionAtPoint:_pressPoint];
  if (flags & kCGEventFlagMaskCommand) {
    // Cmd-click the Hold gap toggles its link (the Hold pair always exists).
    if (sec == KKBasicSectionHold) {
      KKBasicProj p = [self _projection];
      if (p.anyAnimatable)
        [self _toggleHoldLink];
    }
    return;
  }
  // Plain click on a gap → that phase's popover. In/Out: easing. Hold:
  // modulation when flat, or the easing editor when it's a drift (a drift
  // is a real tween from hold-start to hold-end). A disabled In/Out reports
  // as Hold and falls through to the (always-present) Hold popover.
  if (sec == KKBasicSectionIn || sec == KKBasicSectionOut)
    [self _openGapPopoverForSection:sec];
  else if (sec == KKBasicSectionHold)
    [self _openHoldPopover];
}

@end
