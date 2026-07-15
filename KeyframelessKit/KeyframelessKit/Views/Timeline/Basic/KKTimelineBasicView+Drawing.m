/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineBasicView_Private.h"

#import "KKKeyposeSymbol.h"
#import "KKMiniViewerView.h"
#import "KKSegmentEditView.h"
#import "KKTimelineHintText.h"
#import "KKTimelineScale.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

@implementation KKTimelineBasicView (Drawing)

- (void)drawRect:(NSRect)dirtyRect {
  KKBasicProj p = [self _projection];
  NSRect g = [self _graphRect];
  if (NSWidth(g) <= 0 || NSHeight(g) <= 0)
    return;
  // No animatable lanes: keep the container + ruler + playhead so the timeline
  // stays scrubbable, with the empty-state message where the phases would be.
  if (!p.anyAnimatable) {
    if (self.emptyMessage.length)
      [self _drawEmptyStateInRect:g proj:p];
    return;
  }

  // The container background fills the full track width (independent of the
  // graph rect's half-pill content inset + 1px right padding) so the box keeps
  // its size while content sits inset from the right edge.
  NSBezierPath *track =
      [NSBezierPath bezierPathWithRoundedRect:[self _containerRect]
                                      xRadius:KKRadiusMD
                                      yRadius:KKRadiusMD];
  [[[NSColor inspectorLabel] colorWithAlphaComponent:0.06] setFill];
  [track fill];

  double lo = 0.0, hi = 1.0;
  KKBasicValueExtent(p, &lo, &hi);

  // Active-gap band: while a curve/modulation popover is open, tint its section
  // (In / Hold / Out) span in the same translucent gap-selection style Advanced
  // uses, so the user sees which gap the fixed-position popover edits. Colour
  // tracks the section's value (warn when it's a real transition/drift, accent
  // when flat), matching the section's curve/pill colour. Drawn behind the
  // curve + pills as a background band.
  if (_gapPopoverShowing) {
    double bandA = 0.0, bandB = 0.0;
    BOOL bandWarn = NO;
    if (_activeGapSection == KKBasicSectionIn) {
      bandA = 0.0;
      bandB = p.inEndFrac;
      bandWarn = [self _inIsTransition];
    } else if (_activeGapSection == KKBasicSectionOut) {
      bandA = p.outStartFrac;
      bandB = 1.0;
      bandWarn = [self _outIsTransition];
    } else { // Hold
      bandA = p.inEnabled ? p.inEndFrac : 0.0;
      bandB = p.outEnabled ? p.outStartFrac : 1.0;
      bandWarn = [self _holdDrift];
    }
    CGFloat bx0 = KKBasicXForFrac(bandA, g, p);
    CGFloat bx1 = KKBasicXForFrac(bandB, g, p);
    if (bx1 - bx0 >= 1.0) {
      NSColor *bandTint =
          (bandWarn ? [NSColor warning] : [NSColor accentMatchingHost]);
      [[bandTint colorWithAlphaComponent:0.15] setFill];
      NSRectFillUsingOperation(
          NSMakeRect(bx0, NSMinY(g), bx1 - bx0, NSHeight(g)),
          NSCompositingOperationSourceOver);
    }
  }

  // Render is always live (log warp). Stable cursor tracking comes from
  // solving the drag fixed point each frame in -mouseDragged:, not from
  // freezing the map (which caused a jarring re-warp on release).
  KKBasicProj xp = p;

  // Phase dividers used to be drawn here; the boundary pills (further down)
  // serve as the divider now - one less stroke per frame.

  // Stroke per section, all solid. A live transition (enabled In/Out) is
  // "non-hold" - warn-tinted so it reads distinctly. A disabled In/Out is
  // just the flat hold extended (hold color), so the whole thing looks
  // like one continuous hold line with no dashing.
  NSColor *hold = [NSColor accentMatchingHost];
  NSColor *warn = [NSColor warning];
  // Value-based colour (matches Advanced's per-keypose rule): a section/pill is
  // warn only when its endpoints actually differ. A drifting Hold (unlinked,
  // endpoints differ) counts as a transition; a flat In/Out (endpoint == hold)
  // reads accent until it's given a distinct value.
  BOOL drift = [self _holdDrift];
  BOOL inTrans = [self _inIsTransition];
  BOOL outTrans = [self _outIsTransition];
  NSColor *holdC = drift ? warn : hold;
  // Interior pill colour follows EITHER adjacent interval, like Advanced.
  NSColor *holdStartC = (inTrans || drift) ? warn : hold;
  NSColor *holdEndC = (outTrans || drift) ? warn : hold;
  // Clip the curve to the graph's X bounds so the 2px round line cap can't
  // leak ~1px past the first/last keypose. Y is left unclipped so easing
  // overshoot (Elastic/Bounce) still shows.
  [NSGraphicsContext saveGraphicsState];
  NSRectClip(NSMakeRect(NSMinX(g), NSMinY(self.bounds), NSWidth(g),
                        NSHeight(self.bounds)));
  [self _strokeCurveFrom:0.0
                      to:p.inEndFrac
                    proj:p
                   xproj:xp
                    rect:g
                      lo:lo
                      hi:hi
                  dashed:NO
                   color:inTrans ? warn : hold];
  [self _strokeCurveFrom:p.inEndFrac
                      to:p.outStartFrac
                    proj:p
                   xproj:xp
                    rect:g
                      lo:lo
                      hi:hi
                  dashed:NO
                   color:holdC];
  [self _strokeCurveFrom:p.outStartFrac
                      to:1.0
                    proj:p
                   xproj:xp
                    rect:g
                      lo:lo
                      hi:hi
                  dashed:NO
                   color:outTrans ? warn : hold];
  [NSGraphicsContext restoreGraphicsState];

  // Pills + tie bar clip to the visible container (the full-width background).
  // The frac 0/1 pills sit at the inset content edges; clipping to the full
  // container (not the right-padded content rect) leaves room for the frac 1
  // pill to show whole instead of being cut flush at the content edge. Pills
  // panned/zoomed past the container are clipped instead of overflowing.
  [NSGraphicsContext saveGraphicsState];
  NSRect bg = [self _containerRect];
  NSRectClip(NSMakeRect(NSMinX(bg), NSMinY(self.bounds), NSWidth(bg),
                        NSHeight(self.bounds)));

  // Boundary pills - vertical capsules spanning the track height. Hold pair
  // always shows when any lane is animatable; In-start / Out-end only when
  // that phase is enabled (and rendered hollow = time-locked endpoint).
  if (p.anyAnimatable) {
    [self _drawPillAtX:KKBasicXForFrac(p.inEndFrac, g, xp)
                inRect:g
                filled:YES
                 color:holdStartC];
    [self _drawPillAtX:KKBasicXForFrac(p.outStartFrac, g, xp)
                inRect:g
                filled:YES
                 color:holdEndC];
  }
  if (p.inEnabled)
    [self _drawPillAtX:KKBasicXForFrac(0.0, g, xp)
                inRect:g
                filled:NO
                 color:inTrans ? warn : hold];
  if (p.outEnabled)
    [self _drawPillAtX:KKBasicXForFrac(1.0, g, xp)
                inRect:g
                filled:NO
                 color:outTrans ? warn : hold];

  // When the Hold pair is linked, bridge the two interior pills with a
  // tie-bar. With full-height pills the bar floats just above the pill tops
  // (a thin horizontal connector signalling the bond).
  if (p.anyAnimatable && [self _holdLinked]) {
    CGFloat ax = KKBasicXForFrac(p.inEndFrac, g, xp);
    CGFloat bx = KKBasicXForFrac(p.outStartFrac, g, xp);
    CGFloat pillTopY = NSMaxY(g) - kPillInsetY;
    CGFloat barY = MIN(pillTopY + 4.0, NSMaxY(g) - 1.0);
    NSBezierPath *tie = [NSBezierPath bezierPath];
    [tie moveToPoint:NSMakePoint(ax, pillTopY)];
    [tie lineToPoint:NSMakePoint(ax, barY)];
    [tie lineToPoint:NSMakePoint(bx, barY)];
    [tie lineToPoint:NSMakePoint(bx, pillTopY)];
    tie.lineWidth = KKBorderWidthSM;
    tie.lineJoinStyle = NSLineJoinStyleRound;
    tie.lineCapStyle = NSLineCapStyleRound;
    [[hold colorWithAlphaComponent:0.7] setStroke];
    [tie stroke];
  }

  [NSGraphicsContext restoreGraphicsState];

  // Active-keypose highlight: while the boundary popover is open, ring the pill
  // it's editing so the user sees which keypose the (fixed-position) popover
  // controls. The ring colour tracks that pill's own value colour (warn when
  // the endpoint is a real transition, accent when flat), matching the diamond
  // it highlights. Drawn unclipped so the ring isn't shaved at the track edges.
  if (_boundaryPopoverShowing && p.anyAnimatable) {
    double af;
    NSColor *hlColor;
    if (_curDiamond == 1) {
      af = p.inEnabled ? 0.0 : p.inEndFrac;
      hlColor = p.inEnabled ? (inTrans ? warn : hold) : holdStartC;
    } else if (_curDiamond == 3) {
      af = p.outStartFrac;
      hlColor = holdEndC;
    } else if (_curDiamond == 4) {
      af = p.outEnabled ? 1.0 : p.outStartFrac;
      hlColor = p.outEnabled ? (outTrans ? warn : hold) : holdEndC;
    } else {
      af = p.inEndFrac; // d == 2 (hold-start) / default
      hlColor = holdStartC;
    }
    CGFloat cx = round(KKBasicXForFrac(af, g, xp)) + 0.5;
    NSRect pill = NSMakeRect(cx - kPillW * 0.5, NSMinY(g) + kPillInsetY, kPillW,
                             NSHeight(g) - 2.0 * kPillInsetY);
    NSBezierPath *hl =
        [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(pill, -3.0, -3.0)
                                        xRadius:kPillW
                                        yRadius:kPillW];
    hl.lineWidth = 2.0;
    [hlColor setStroke];
    [hl stroke];
  }

  [self _drawRulerInRect:g proj:p xproj:xp];

  [self _drawPlayheadInRect:g proj:p];
}

// Playhead: a thin line spanning ruler→track plus a small top knob, mapped
// through the same warp as everything else. < 0 = hidden (not playing).
- (void)_drawPlayheadInRect:(NSRect)g proj:(KKBasicProj)p {
  if (_playheadFraction < 0.0)
    return;
  CGFloat px = KKBasicXForFrac(_playheadFraction, g, p);
  px = round(px) + 0.5; // crisp 1px line
  CGFloat top = NSMaxY(g) + kRulerGap + kRulerH;
  NSColor *phc = [NSColor inspectorLabel];
  // Contain the scrubber horizontally to the visible container; vertical is
  // left free so the knob still sits up in the ruler.
  NSRect cont = [self _containerRect];
  [NSGraphicsContext saveGraphicsState];
  NSRectClip(NSMakeRect(NSMinX(cont), NSMinY(g), NSWidth(cont),
                        NSMaxY(self.bounds) - NSMinY(g)));
  NSBezierPath *line = [NSBezierPath bezierPath];
  [line moveToPoint:NSMakePoint(px, NSMinY(g))];
  [line lineToPoint:NSMakePoint(px, top)];
  line.lineWidth = 1.0;
  [[phc colorWithAlphaComponent:0.85] setStroke];
  [line stroke];
  CGFloat kw = 7.0, kh = 6.0;
  NSBezierPath *knob = [NSBezierPath bezierPath];
  [knob moveToPoint:NSMakePoint(px - kw / 2.0, top)];
  [knob lineToPoint:NSMakePoint(px + kw / 2.0, top)];
  [knob lineToPoint:NSMakePoint(px + kw / 2.0, top - kh + 3.0)];
  [knob lineToPoint:NSMakePoint(px, top - kh)];
  [knob lineToPoint:NSMakePoint(px - kw / 2.0, top - kh + 3.0)];
  [knob closePath];
  [phc setFill];
  [knob fill];
  [NSGraphicsContext restoreGraphicsState];
}

- (void)_drawEmptyStateInRect:(NSRect)g proj:(KKBasicProj)p {
  NSBezierPath *track =
      [NSBezierPath bezierPathWithRoundedRect:[self _containerRect]
                                      xRadius:KKRadiusMD
                                      yRadius:KKRadiusMD];
  [[[NSColor inspectorLabel] colorWithAlphaComponent:0.06] setFill];
  [track fill];

  KKTimelineDrawCenteredHint(self.emptyMessage, g);

  // With no lanes p is the default linear projection, so it doubles as the
  // ruler's unwarped x-projection.
  [self _drawRulerInRect:g proj:p xproj:p];
  [self _drawPlayheadInRect:g proj:p];
}

- (void)_strokeCurveFrom:(double)t0
                      to:(double)t1
                    proj:(KKBasicProj)p
                   xproj:(KKBasicProj)xp
                    rect:(NSRect)g
                      lo:(double)lo
                      hi:(double)hi
                  dashed:(BOOL)dashed
                   color:(NSColor *)color {
  if (t1 - t0 < kEps)
    return;
  // Sample by *displayed* width, not true-fraction span - a short In/Out is
  // warped wide, so it still needs enough points to show its easing. Shape
  // from `p` (live), X from `xp` (frozen while dragging).
  double du = fabs(KKBasicFracToU(t1, xp) - KKBasicFracToU(t0, xp)) *
              (xp.zoom > 0.0 ? xp.zoom : 1.0);
  NSInteger n = MAX(2, (NSInteger)round(kCurveSamples * du));
  // High-frequency Hold modulation oscillates many times across the held
  // span; the displayed-width count alone undersamples it and the line
  // turns jagged. Add ~24 samples per oscillation cycle for the part of
  // this segment that carries modulation (frequency is 0..1).
  if (p.holdMod != KKIntervalModulationNone && p.outStartFrac > p.inEndFrac) {
    double ov = MIN(t1, p.outStartFrac) - MAX(t0, p.inEndFrac);
    if (ov > 0.0) {
      double cyc; // highest visually-significant cycles over the full span
      switch (KKBasicHoldEffect(p.holdMod)) {
      case KKHoldEffectBounce:
        cyc = 6.0;
        break;
      case KKHoldEffectHandheld:
        cyc = 60.0;
        break;
      default:
        cyc = 55.0; // Wiggle's fastest (f3) term
        break;
      }
      cyc *= p.holdModFrequency;
      double frac = ov / (p.outStartFrac - p.inEndFrac);
      n = MAX(n, (NSInteger)ceil(cyc * frac * 24.0));
      n = MIN(n, 4000);
    }
  }
  NSPoint *pts = malloc(sizeof(NSPoint) * (size_t)(n + 1));
  for (NSInteger i = 0; i <= n; i++) {
    double t = t0 + (t1 - t0) * (double)i / n;
    pts[i] = KKBasicPoint(g, t, KKBasicMotionYSmoothed(t, p), lo, hi, xp);
  }
  KKStrokeTimelineCurve(pts, n + 1, kCurveWidth, dashed, color);
  free(pts);
}

- (void)_drawDiamondAt:(NSPoint)c filled:(BOOL)filled color:(NSColor *)color {
  KKDrawKeyposeDiamond(c, kDiamondR, filled, color);
}

- (void)_drawPillAtX:(CGFloat)x
              inRect:(NSRect)g
              filled:(BOOL)filled
               color:(NSColor *)color {
  // Match the playhead's `round(x) + 0.5` rounding so the pill center sits
  // exactly under the playhead line (otherwise sub-pixel x lands them ±1px
  // apart depending on frac(x)).
  CGFloat cx = round(x) + 0.5;
  NSRect pill = NSMakeRect(cx - kPillW * 0.5, NSMinY(g) + kPillInsetY, kPillW,
                           NSHeight(g) - 2.0 * kPillInsetY);
  KKDrawKeyposePill(pill, filled, color);
}

- (void)_drawDurationForSection:(KKBasicSection)section
                         inRect:(NSRect)g
                           proj:(KKBasicProj)p
                          xproj:(KKBasicProj)xp
                            dur:(double)dur
                         rulerY:(CGFloat)rulerY {
  double a = 0, b = 0;
  // Value-based tint (matches the curve/pill colour): warn only when the
  // section's endpoints actually differ - a flat In/Out reads accent.
  NSColor *tint = [NSColor accentMatchingHost];
  if (section == KKBasicSectionIn) {
    a = 0;
    b = p.inEndFrac;
    tint = p.inIsTransition ? [NSColor warning] : [NSColor accentMatchingHost];
  } else if (section == KKBasicSectionHold) {
    // Hold spans the merged flat region: a disabled In/Out folds in, so the
    // readout is the combined held duration, not just the middle.
    a = p.inEnabled ? p.inEndFrac : 0.0;
    b = p.outEnabled ? p.outStartFrac : 1.0;
    // Drift = Hold endpoints with different values (a real tween, not flat) →
    // surface it with warning, matching the warn fill used by _drawHoldSection.
    tint = [self _holdDrift] ? [NSColor warning] : [NSColor accentMatchingHost];
  } else {
    a = p.outStartFrac;
    b = 1.0;
    tint = p.outIsTransition ? [NSColor warning] : [NSColor accentMatchingHost];
  }
  double secs = (b - a) * dur;
  NSString *txt = secs < 10.0 ? [NSString stringWithFormat:@"%.1fs", secs]
                              : [NSString stringWithFormat:@"%.0fs", secs];
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                            weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName : tint,
  };
  NSSize sz = [txt sizeWithAttributes:attrs];
  CGFloat cx = (KKBasicXForFrac(a, g, xp) + KKBasicXForFrac(b, g, xp)) / 2.0;
  CGFloat x = round(cx - sz.width / 2.0);
  x = MAX(NSMinX(g), MIN(NSMaxX(g) - sz.width, x));
  CGFloat y = rulerY + (kRulerH - sz.height) / 2.0;
  // Pill behind the readout so it stays legible over the ruler ticks/labels.
  NSRect pill =
      NSInsetRect(NSMakeRect(x, rulerY, sz.width, kRulerH), -3.0, 0.0);
  [[[NSColor inspectorBackground] colorWithAlphaComponent:0.92] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:pill
                                   xRadius:KKRadiusSM
                                   yRadius:KKRadiusSM] fill];
  [txt drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
}

- (void)_drawRulerInRect:(NSRect)g proj:(KKBasicProj)p xproj:(KKBasicProj)xp {
  CGFloat rulerY = NSMaxY(g) + kRulerGap;
  double dur = [self _clipDuration];
  if (dur <= 0)
    return;

  // Ruler ticks always draw - the duration readout overlays them rather
  // than replacing them, so the timeline stays legible while hovering.
  CGFloat pps = NSWidth(g) / dur;
  double interval = KKTimelineScaleTickInterval(pps, kTickMinSpacing);
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName :
        [[NSColor inspectorLabel] colorWithAlphaComponent:0.35],
  };
  NSBezierPath *ticks = [NSBezierPath bezierPath];
  ticks.lineWidth = KKBorderWidthXS;
  [[[NSColor inspectorLabel] colorWithAlphaComponent:0.15] setStroke];
  for (double t = 0; t <= dur + 0.001; t += interval) {
    double frac = t / dur;
    if (frac > 1.0 + kEps)
      break;
    CGFloat x = KKBasicXForFrac(frac, g, xp);
    if (x < NSMinX(g) - 0.5 || x > NSMaxX(g) + 0.5)
      continue; // off-screen when zoomed/panned
    [ticks moveToPoint:NSMakePoint(x, rulerY)];
    [ticks lineToPoint:NSMakePoint(x, rulerY + 4.0)];
    NSString *label = KKTimelineScaleTimecode(t);
    NSSize lsz = [label sizeWithAttributes:attrs];
    CGFloat lx = x + 3.0;
    if (lx >= NSMinX(g) && lx + lsz.width <= NSMaxX(g))
      [label drawAtPoint:NSMakePoint(lx, rulerY + (kRulerH - lsz.height) / 2.0)
          withAttributes:attrs];
  }
  [ticks stroke];

  // Overlay: dragging a boundary shows BOTH adjacent durations (the side
  // you grabbed shouldn't decide what you see); hovering shows that one.
  if (_dragActive && (_pressedDiamond == 2 || _pressedDiamond == 3)) {
    KKBasicSection left =
        _pressedDiamond == 2 ? KKBasicSectionIn : KKBasicSectionHold;
    KKBasicSection right =
        _pressedDiamond == 2 ? KKBasicSectionHold : KKBasicSectionOut;
    [self _drawDurationForSection:left
                           inRect:g
                             proj:p
                            xproj:xp
                              dur:dur
                           rulerY:rulerY];
    [self _drawDurationForSection:right
                           inRect:g
                             proj:p
                            xproj:xp
                              dur:dur
                           rulerY:rulerY];
  } else if (_hoverSection != KKBasicSectionNone) {
    [self _drawDurationForSection:_hoverSection
                           inRect:g
                             proj:p
                            xproj:xp
                              dur:dur
                           rulerY:rulerY];
  }
}

@end
