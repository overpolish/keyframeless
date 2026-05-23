/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKTimelineBasicView_Private.h"

#import "../Math/KKTimelineScale.h"
#import "../Math/KKTimelineScrubMath.h"
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

// Pill index under `pt` (1 t=0, 2 t_inEnd, 3 t_outStart, 4 t=1), or 0. Pills
// span the full track height — the hit is a vertical band around the pill x
// regardless of cursor y.
- (NSInteger)_diamondAtPoint:(NSPoint)pt proj:(KKBasicProj)p rect:(NSRect)g {
  if (pt.y < NSMinY(g) || pt.y > NSMaxY(g))
    return 0;
  CGFloat xs[4] = {
      KKBasicXForFrac(0.0, g, p),
      KKBasicXForFrac(p.inEndFrac, g, p),
      KKBasicXForFrac(p.outStartFrac, g, p),
      KKBasicXForFrac(1.0, g, p),
  };
  BOOL enabled[4] = {p.inEnabled, p.anyAnimatable, p.anyAnimatable,
                     p.outEnabled};
  CGFloat halfHit = kPillW * 0.5 + kPillHitSlop;
  for (NSInteger i = 0; i < 4; i++)
    if (enabled[i] && fabs(pt.x - xs[i]) <= halfHit)
      return i + 1;
  return 0;
}

// The two middle diamonds drag to set In/Out duration (endpoints are
// time-locked). A press that doesn't move opens the value popover for that
// boundary instead.
// Subtle snap so a scrub can land precisely on a diamond — important for the
// Snap window — closest enabled diamond within this many px wins; no
// hysteresis (the old sticky-out caused worse jitter on log-warped regions).
static const CGFloat kScrubSnapInPx = 4.0;

- (double)_snappedScrubFracForX:(CGFloat)x proj:(KKBasicProj)p rect:(NSRect)g {
  // Visual scrubber stays unclamped to 1.0 so it can reach the right-edge
  // diamond on short clips (where 1-frameFrac is several percent inside the
  // edge). The actual playhead delivery is clamped to the last frame at the
  // call site — see KKTimelineScrubFracDelivered().
  NSMutableArray<NSNumber *> *cands = [NSMutableArray arrayWithCapacity:4];
  if (p.inEnabled)
    [cands addObject:@(0.0)];
  if (p.anyAnimatable) {
    [cands addObject:@(p.inEndFrac)];
    [cands addObject:@(p.outStartFrac)];
  }
  if (p.outEnabled)
    [cands addObject:@(1.0)];
  return KKTimelineSnapFracInPixels(
      x, KKBasicFracForX(x, g, p), cands,
      ^CGFloat(double frac) {
        return KKBasicXForFrac(frac, g, p);
      },
      kScrubSnapInPx, &_snappedScrubFrac);
}

- (double)_deliveredScrubFracFromVisual:(double)visualFrac {
  return KKTimelineScrubFracDelivered(visualFrac, [self _clipDuration],
                                      _frameDurationSeconds);
}

- (BOOL)_isInScrubBand:(NSPoint)pt rect:(NSRect)g {
  return KKTimelineScrubBandContainsPoint(pt, NSMinX(g), NSMaxX(g), NSMaxY(g));
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  NSRect g = [self _graphRect];
  _dragActive = NO;
  KKBasicProj p = [self _projection];
  _scrubbing = [self _isInScrubBand:pt rect:g];
  if (_scrubbing) {
    _snappedScrubFrac = NAN; // fresh scrub starts with no sticky snap
    // Click-jump: move the playhead to the clicked position immediately,
    // then -mouseDragged: continues tracking. Update the visual optimistic-
    // ally (bypassing the setter, which ignores pushes while scrubbing).
    _pressedDiamond = 0;
    _pressPoint = pt;
    double frac = [self _snappedScrubFracForX:pt.x proj:p rect:g];
    _playheadFraction = frac;
    [self setNeedsDisplay:YES];
    if (self.onScrub)
      self.onScrub([self _deliveredScrubFracFromVisual:frac]);
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
    double frac = [self _snappedScrubFracForX:pt.x proj:p rect:g];
    _playheadFraction = frac;
    [self setNeedsDisplay:YES];
    if (self.onScrub)
      self.onScrub([self _deliveredScrubFracFromVisual:frac]);
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
  // Link toggle moved to the right-click context menu — ctrl+click would
  // conflict with AppKit's contextual-menu routing in the XPC inspector.
  KKBasicSection sec = [self _sectionAtPoint:_pressPoint];
  // Plain click on a gap → that phase's popover. In/Out: easing. Hold:
  // modulation when flat, or the easing editor when it's a drift (a drift
  // is a real tween from hold-start to hold-end). A disabled In/Out reports
  // as Hold and falls through to the (always-present) Hold popover.
  if (sec == KKBasicSectionIn || sec == KKBasicSectionOut)
    [self _openGapPopoverForSection:sec];
  else if (sec == KKBasicSectionHold)
    [self _openHoldPopover];
}

// Right-click on the Hold gap → "Link Endpoints" / "Unlink Endpoints".
// In/Out sections have no link concept (the curve always spans those
// phases as a single transition), so right-click there shows no menu.
- (NSMenu *)menuForEvent:(NSEvent *)event {
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  KKBasicSection sec = [self _sectionAtPoint:pt];
  if (sec != KKBasicSectionHold)
    return nil;
  KKBasicProj p = [self _projection];
  if (!p.anyAnimatable)
    return nil;
  // Probe the first animatable lane's Hold interval to decide the verb —
  // _toggleHoldLink mutates every animatable lane's Hold uniformly so this
  // first-lane state is representative of the toggle's effect.
  KKInterval *holdIv = nil;
  for (KKLane *lane in _timeline.lanes)
    if (lane.enabled && lane.keyposes.count >= 2) {
      holdIv = lane.keyposes[KKShapeOfLane(lane).holdStart].outgoing;
      break;
    }
  if (!holdIv)
    return nil;
  NSMenu *menu = [[NSMenu alloc] init];
  NSString *title =
      holdIv.endpointsLinked
          ? KKLoc(@"Unlink Endpoints", @"Context menu: unlink endpoints.")
          : KKLoc(@"Link Endpoints", @"Context menu: link endpoints.");
  [menu addItemWithTitle:title
                  action:@selector(_menuToggleHoldLink:)
           keyEquivalent:@""]
      .target = self;
  return menu;
}

- (void)_menuToggleHoldLink:(id)sender {
  [self _toggleHoldLink];
}

@end
