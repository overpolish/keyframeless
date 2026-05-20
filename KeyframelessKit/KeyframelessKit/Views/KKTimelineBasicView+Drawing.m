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

@implementation KKTimelineBasicView (Drawing)

- (void)drawRect:(NSRect)dirtyRect {
  KKBasicProj p = [self _projection];
  if (!p.anyAnimatable)
    return;
  NSRect g = [self _graphRect];
  if (NSWidth(g) <= 0 || NSHeight(g) <= 0)
    return;

  NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:g
                                                        xRadius:KKRadiusMD
                                                        yRadius:KKRadiusMD];
  [[[NSColor inspectorLabel] colorWithAlphaComponent:0.06] setFill];
  [track fill];

  double lo = 0.0, hi = 1.0;
  KKBasicValueExtent(p, &lo, &hi);

  // Render is always live (log warp). Stable cursor tracking comes from
  // solving the drag fixed point each frame in -mouseDragged:, not from
  // freezing the map (which caused a jarring re-warp on release).
  KKBasicProj xp = p;

  // Only show a phase divider for an enabled phase — a disabled In/Out has
  // no boundary; it's just an extension of the flat hold.
  NSMutableArray<NSNumber *> *dividers = [NSMutableArray array];
  if (p.inEnabled)
    [dividers addObject:@(p.inEndFrac)];
  if (p.outEnabled)
    [dividers addObject:@(p.outStartFrac)];
  [[[NSColor inspectorLabel] colorWithAlphaComponent:0.12] setStroke];
  for (NSNumber *fn in dividers) {
    double f = fn.doubleValue;
    CGFloat x = KKBasicXForFrac(f, g, xp);
    NSBezierPath *div = [NSBezierPath bezierPath];
    [div moveToPoint:NSMakePoint(x, NSMinY(g))];
    [div lineToPoint:NSMakePoint(x, NSMaxY(g))];
    div.lineWidth = KKBorderWidthXS;
    [div stroke];
  }

  // Stroke per section, all solid. A live transition (enabled In/Out) is
  // "non-hold" — warn-tinted so it reads distinctly. A disabled In/Out is
  // just the flat hold extended (hold color), so the whole thing looks
  // like one continuous hold line with no dashing.
  NSColor *hold = [NSColor accentMatchingHost];
  NSColor *warn = [NSColor warning];
  // A drifting Hold (unlinked, endpoints differ) is itself "non-hold" —
  // warn-tint its segment and interior diamonds like a transition.
  BOOL drift = [self _holdDrift];
  NSColor *holdC = drift ? warn : hold;
  [self _strokeCurveFrom:0.0
                      to:p.inEndFrac
                    proj:p
                   xproj:xp
                    rect:g
                      lo:lo
                      hi:hi
                  dashed:NO
                   color:p.inEnabled ? warn : hold];
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
                   color:p.outEnabled ? warn : hold];

  // The Hold pair is always present, so its two diamonds always show. The
  // first/last (In-start / Out-end) diamonds appear only when that phase is
  // enabled — a disabled phase renders as a plain flat hold.
  if (p.anyAnimatable) {
    [self
        _drawDiamondAt:KKBasicPoint(g, p.inEndFrac,
                                    KKBasicMotionY(p.inEndFrac, xp), lo, hi, xp)
                filled:YES
                 color:holdC];
    [self _drawDiamondAt:KKBasicPoint(g, p.outStartFrac,
                                      KKBasicMotionY(p.outStartFrac, xp), lo,
                                      hi, xp)
                  filled:YES
                   color:holdC];
  }
  if (p.inEnabled)
    [self _drawDiamondAt:KKBasicPoint(g, 0.0, 0.0, lo, hi, xp)
                  filled:NO
                   color:warn];
  if (p.outEnabled)
    [self _drawDiamondAt:KKBasicPoint(g, 1.0, 0.0, lo, hi, xp)
                  filled:NO
                   color:warn];

  // When the Hold pair is linked, bridge the two interior diamonds with a
  // tie-bar. Its rail rides *above the curve's peak* across the held span
  // (sampled), so a high-amplitude modulation can never cross it — the
  // bond stays a clean, unambiguous clamp.
  if (p.anyAnimatable && [self _holdLinked]) {
    NSPoint a = KKBasicPoint(g, p.inEndFrac, KKBasicMotionY(p.inEndFrac, xp),
                             lo, hi, xp);
    NSPoint b = KKBasicPoint(g, p.outStartFrac,
                             KKBasicMotionY(p.outStartFrac, xp), lo, hi, xp);
    CGFloat peakY = MAX(a.y, b.y);
    NSInteger n = 48;
    for (NSInteger i = 0; i <= n; i++) {
      double t =
          p.inEndFrac + (p.outStartFrac - p.inEndFrac) * (double)i / (double)n;
      CGFloat cy =
          KKBasicPoint(g, t, KKBasicMotionYSmoothed(t, p), lo, hi, xp).y;
      peakY = MAX(peakY, cy);
    }
    CGFloat barY = MIN(peakY + kDiamondR + 6.0, NSMaxY(g) - 1.0);
    NSBezierPath *tie = [NSBezierPath bezierPath];
    [tie moveToPoint:NSMakePoint(a.x, a.y + kDiamondR)];
    [tie lineToPoint:NSMakePoint(a.x, barY)];
    [tie lineToPoint:NSMakePoint(b.x, barY)];
    [tie lineToPoint:NSMakePoint(b.x, b.y + kDiamondR)];
    tie.lineWidth = KKBorderWidthSM;
    tie.lineJoinStyle = NSLineJoinStyleRound;
    tie.lineCapStyle = NSLineCapStyleRound;
    [[hold colorWithAlphaComponent:0.7] setStroke];
    [tie stroke];
  }

  [self _drawRulerInRect:g proj:p xproj:xp];

  // Playhead: a thin line spanning ruler→track plus a small top knob, mapped
  // through the same warp as everything else. < 0 = hidden (not playing).
  if (_playheadFraction >= 0.0) {
    CGFloat px = KKBasicXForFrac(_playheadFraction, g, p);
    px = round(px) + 0.5; // crisp 1px line
    CGFloat top = NSMaxY(g) + kRulerGap + kRulerH;
    NSColor *phc = [NSColor inspectorLabel];
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
  }
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
  // Sample by *displayed* width, not true-fraction span — a short In/Out is
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

- (void)_drawDurationForSection:(KKBasicSection)section
                         inRect:(NSRect)g
                           proj:(KKBasicProj)p
                          xproj:(KKBasicProj)xp
                            dur:(double)dur
                         rulerY:(CGFloat)rulerY {
  double a = 0, b = 0;
  NSColor *tint = [NSColor warning];
  if (section == KKBasicSectionIn) {
    a = 0;
    b = p.inEndFrac;
  } else if (section == KKBasicSectionHold) {
    // Hold spans the merged flat region: a disabled In/Out folds in, so the
    // readout is the combined held duration, not just the middle.
    a = p.inEnabled ? p.inEndFrac : 0.0;
    b = p.outEnabled ? p.outStartFrac : 1.0;
    tint = [NSColor accentMatchingHost];
  } else {
    a = p.outStartFrac;
    b = 1.0;
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

  // Ruler ticks always draw — the duration readout overlays them rather
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
