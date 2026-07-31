/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageSurfaceCircleView_Internal.h"

#import "MirageOklab.h" // the shared sRGB / Oklab maths

#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

/// The sRGB cube's pure-hue edge at `h` degrees of HSV: saturation 1, value 1, the
/// most colourful thing the display can show at that HSV hue. Written out rather
/// than asked of AppKit because it is called from a table build, not from drawing,
/// and an NSColor round trip there is all allocation and no arithmetic.
static void MirageFullyLitRGBForHSVHue(double h, double *outR, double *outG,
                                       double *outB) {
  h = fmod(fmod(h, 360.0) + 360.0, 360.0) / 60.0;
  int sector = (int)floor(h);
  double f = h - (double)sector, up = f, down = 1.0 - f;
  double r, g, b;
  switch (sector) {
  case 0: r = 1.0;  g = up;   b = 0.0;  break;
  case 1: r = down; g = 1.0;  b = 0.0;  break;
  case 2: r = 0.0;  g = 1.0;  b = up;   break;
  case 3: r = 0.0;  g = down; b = 1.0;  break;
  case 4: r = up;   g = 0.0;  b = 1.0;  break;
  default: r = 1.0; g = 0.0;  b = down; break;
  }
  *outR = r;
  *outG = g;
  *outB = b;
}

/// Oklab hue (0..360) and chroma of a DISPLAY-ENCODED sRGB triple. Both at once
/// because the decode and the forward transform are the whole cost, and every
/// caller here wants the pair.
static void MirageOklabHueChromaOfEncoded(double r, double g, double b,
                                          double *outHue, double *outChroma) {
  MirageOklabLChOfEncoded(r, g, b, NULL, outChroma, outHue);
}

/// The most vivid DISPLAYABLE colour whose Oklab hue is `hueDegrees`, as
/// display-encoded sRGB 0..1 - the gamut cusp for that hue.
///
/// This is no longer painted directly. Nothing is wrong with the colour it
/// returns, but its LIGHTNESS is wherever the cusp happens to sit, and that is not
/// a continuous function of hue: measured, HSV 220..240 is 22 degrees of visibly
/// different blues (0,85,255 at L=0.53 through pure blue at L=0.45) squeezed into
/// under 2 degrees of Oklab hue, which is one segment of a 180-segment ring. Two
/// neighbouring segments picking their own cusp therefore picked wildly different
/// lightnesses and the ring showed a hard cliff in the blues. It survives as the
/// source of the cusp lightness curve, which is smoothed before use.
///
/// The ring and the cloud before that painted every hue at a fixed Oklab lightness
/// of 0.75, and the result was a wheel of pastels: sRGB's own primaries sit nowhere
/// near a common lightness - red is L=0.63, blue L=0.45, yellow L=0.97 - so red
/// came out as salmon (255,133,115) and blue as a pale sky. A legend for a colour
/// cast has to show the colours the frame can actually contain.
///
/// The most saturated sRGB colours are the cube's pure-hue edge, which is exactly
/// HSV saturation 1 value 1, so this is a one-dimensional search: bisect on HSV
/// hue until the Oklab hue of the result is the one asked for.
///
/// The chroma sweep at the end is not a refinement of the hue - it is there because
/// Oklab hue is NOT monotone in HSV hue everywhere, which the obvious bisection
/// assumes. Measured, it rises to 264.21 degrees at HSV 232, falls back to 264.05
/// at pure blue, then climbs again, so every hue in that 0.15-degree window has
/// three answers on the edge and plain bisection returns the WASHED-OUT one:
/// requesting 264 gave (0,60,255) instead of pure blue. Among candidates whose hue
/// is right to well inside a just-noticeable amount, the most colourful one wins.
static void MirageVividForOklabHue(double hueDegrees, double *outR, double *outG,
                                   double *outB) {
  double r0 = 0.0, g0 = 0.0, b0 = 0.0;
  MirageFullyLitRGBForHSVHue(0.0, &r0, &g0, &b0);
  double base = 0.0, chroma = 0.0;
  MirageOklabHueChromaOfEncoded(r0, g0, b0, &base, &chroma);
  // Unwrapped against HSV zero, so the bisection runs on a plainly increasing
  // function over one full turn instead of on an angle that wraps mid-interval.
  double signedFromBase = fmod(base - hueDegrees + 540.0, 360.0) - 180.0;
  double want = base + (signedFromBase <= 0.0 ? -signedFromBase
                                              : 360.0 - signedFromBase);
  double lo = 0.0, hi = 360.0, at = 0.0;
  for (int i = 0; i < 40; i++) {
    double mid = (lo + hi) * 0.5;
    double r = 0.0, g = 0.0, b = 0.0, h = 0.0, c = 0.0;
    MirageFullyLitRGBForHSVHue(mid, &r, &g, &b);
    MirageOklabHueChromaOfEncoded(r, g, b, &h, &c);
    if (h < base)
      h += 360.0;
    at = mid;
    if (fabs(h - want) < 0.02)
      break;
    if (h < want)
      lo = mid;
    else
      hi = mid;
  }
  MirageFullyLitRGBForHSVHue(at, outR, outG, outB);
  double bestHue = 0.0, bestChroma = 0.0;
  MirageOklabHueChromaOfEncoded(*outR, *outG, *outB, &bestHue, &bestChroma);
  for (double off = -16.0; off <= 16.0; off += 0.5) {
    double r = 0.0, g = 0.0, b = 0.0, h = 0.0, c = 0.0;
    MirageFullyLitRGBForHSVHue(at + off, &r, &g, &b);
    MirageOklabHueChromaOfEncoded(r, g, b, &h, &c);
    if (fabs(fmod(h - hueDegrees + 540.0, 360.0) - 180.0) > 0.06 ||
        c <= bestChroma)
      continue;
    bestChroma = c;
    *outR = r;
    *outG = g;
    *outB = b;
  }
}

/// Samples in the cusp lightness table: one per whole degree of Oklab hue. An enum
/// rather than a `static const` because it has to size a C array.
enum { kCuspSamples = 360 };
/// Half-width, in degrees, of the circular low-pass over the cusp lightness curve.
/// Measured on the finished ring: the worst step between neighbouring segments is
/// 3.0x the median at 10 degrees, 2.2x at 20, 1.8x at 30, and stops improving after
/// that, while yellow falls from L=0.95 to 0.91 and blue rises from 0.48 to 0.53 -
/// still plainly a bright yellow and a dark blue.
static const NSInteger kCuspSmoothHalfWidth = 30;

/// The lightness the ring and the cloud paint at each whole degree of Oklab hue:
/// the cusp lightness curve, low-passed CIRCULARLY. The wrap matters as much as the
/// smoothing - averaging degree 359 against degrees 0..19 is the only thing keeping
/// a new seam from appearing at the top of the wheel, where there was never one.
///
/// A `dispatch_once` static is safe here despite the no-mutable-statics rule for
/// XPC plugin instances: this is derived purely from compile-time constants and is
/// never written again, so there is no per-instance state for one process to
/// change and another to miss.
static const double *MirageCuspLightnessTable(void) {
  static double table[kCuspSamples];
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    double raw[kCuspSamples];
    for (NSInteger i = 0; i < kCuspSamples; i++) {
      double r = 0.0, g = 0.0, b = 0.0;
      MirageVividForOklabHue((double)i * 360.0 / (double)kCuspSamples, &r, &g, &b);
      double L = 0.0;
      MirageOklabLChOfEncoded(r, g, b, &L, NULL, NULL);
      raw[i] = L;
    }
    for (NSInteger i = 0; i < kCuspSamples; i++) {
      double sum = 0.0;
      for (NSInteger o = -kCuspSmoothHalfWidth; o <= kCuspSmoothHalfWidth; o++)
        sum += raw[(i + o + kCuspSamples * 2) % kCuspSamples];
      table[i] = sum / (double)(2 * kCuspSmoothHalfWidth + 1);
    }
  });
  return table;
}

/// The colour the wheel shows at `hueDegrees`: the smoothed cusp lightness for that
/// hue, at the most chroma the display can hold AT that lightness.
///
/// Bisecting chroma rather than taking the cusp's own is what removes the cliff -
/// adjacent segments now differ only by how their smoothed lightnesses differ,
/// which is bounded by the low-pass, instead of by whatever two unrelated cusps
/// happened to be. The hue is untouched by any of it, which is load-bearing: the
/// cloud is binned in Oklab hue and this ring is its legend.
///
/// Costs a few dozen cube roots per call and is called only from the table builds.
static void MirageDisplayRGBForOklabHue(double hueDegrees, double *outR,
                                        double *outG, double *outB) {
  const double *table = MirageCuspLightnessTable();
  double h = fmod(fmod(hueDegrees, 360.0) + 360.0, 360.0);
  NSInteger i0 = (NSInteger)floor(h);
  double f = h - (double)i0;
  double L = table[i0 % kCuspSamples] * (1.0 - f) +
             table[(i0 + 1) % kCuspSamples] * f;
  double ca = cos(h * M_PI / 180.0), sa = sin(h * M_PI / 180.0);
  // 0.4 is comfortably past sRGB's most chromatic colour in Oklab, so the upper
  // bound always starts outside the gamut and the bisection is well posed.
  double lo = 0.0, hi = 0.4;
  for (int i = 0; i < 48; i++) {
    double mid = (lo + hi) * 0.5;
    double r = 0.0, g = 0.0, b = 0.0;
    MirageOklabToLinear(L, ca * mid, sa * mid, &r, &g, &b);
    double least = MIN(r, MIN(g, b)), most = MAX(r, MAX(g, b));
    if (least >= -1e-9 && most <= 1.0 + 1e-9)
      lo = mid;
    else
      hi = mid;
  }
  double r = 0.0, g = 0.0, b = 0.0;
  MirageOklabToLinear(L, ca * lo, sa * lo, &r, &g, &b);
  *outR = MirageSRGBEncode(r);
  *outG = MirageSRGBEncode(g);
  *outB = MirageSRGBEncode(b);
}

/// The mid-angle of ring segment `index`, in radians. The segments overlap by 2
/// percent to hide their seams, so this is not quite the bin centre.
static double MirageRingSegmentMidAngle(NSUInteger index) {
  double step = 2.0 * M_PI / (double)kRingSegments;
  return ((double)index + 0.51) * step;
}

@implementation MirageSurfaceCircleView (Drawing)

/// One opaque colour per (angle bin, radius bin), in row-major order matching the
/// bins themselves. Built once per bin geometry: the vivid inversion runs once per
/// ANGLE, never per radius and never per frame.
- (NSArray<NSColor *> *)_cloudCellColors {
  if (_cloudColors.count == _chromaAngleBins * _chromaRadiusBins &&
      _cloudColorsAngleBins == _chromaAngleBins &&
      _cloudColorsRadiusBins == _chromaRadiusBins)
    return _cloudColors;
  // The centre of the cloud is where neutral pixels land, so the inner bands are
  // painted as the near-greys they are and only the rim gets the full hue. Ramping
  // an Oklab chroma request instead - what this did - could not survive dropping
  // the fixed lightness, and the grey is the honest end of the ramp anyway.
  const CGFloat neutral = 0.72;
  NSMutableArray<NSColor *> *colors =
      [NSMutableArray arrayWithCapacity:_chromaAngleBins * _chromaRadiusBins];
  for (NSUInteger a = 0; a < _chromaAngleBins; a++) {
    double vr = 0.0, vg = 0.0, vb = 0.0;
    MirageDisplayRGBForOklabHue((double)a * 360.0 / (double)_chromaAngleBins, &vr,
                                &vg, &vb);
    for (NSUInteger ri = 0; ri < _chromaRadiusBins; ri++) {
      CGFloat t = (CGFloat)(ri + 1) / (CGFloat)_chromaRadiusBins;
      [colors addObject:[NSColor colorWithSRGBRed:neutral + ((CGFloat)vr - neutral) * t
                                            green:neutral + ((CGFloat)vg - neutral) * t
                                             blue:neutral + ((CGFloat)vb - neutral) * t
                                            alpha:1.0]];
    }
  }
  _cloudColors = colors;
  _cloudColorsAngleBins = _chromaAngleBins;
  _cloudColorsRadiusBins = _chromaRadiusBins;
  return _cloudColors;
}

// The vectorscope cloud: every sampled pixel placed by its colour, hue as angle
// and colourfulness as distance from centre. Drawn in the puck's own space, which
// is the whole point - a cast is a lopsided cloud, and the correction is pulling
// the puck the opposite way.
- (void)_drawChromaCloudInRect:(NSRect)circle {
  // Whole frame first and faint, visible region on top at full strength. Ordered
  // that way so the layer the user is looking at is never sitting under the one
  // they zoomed past, and the ghost still says which way the rest of the picture
  // leans.
  if (_chromaRegionBins.count && _chromaRegionPeak > 0.0) {
    [self _drawChromaCloudInRect:circle
                            bins:_chromaBins
                            peak:_chromaPeak
                      alphaScale:kGhostCloudAlpha];
    [self _drawChromaCloudInRect:circle
                            bins:_chromaRegionBins
                            peak:_chromaRegionPeak
                      alphaScale:1.0];
    return;
  }
  [self _drawChromaCloudInRect:circle
                          bins:_chromaBins
                          peak:_chromaPeak
                    alphaScale:1.0];
}

- (void)_drawChromaCloudInRect:(NSRect)circle
                          bins:(NSArray<NSNumber *> *)bins
                          peak:(double)peak
                    alphaScale:(double)alphaScale {
  if (!bins.count || peak <= 0.0)
    return;
  NSPoint centre = NSMakePoint(NSMidX(circle), NSMidY(circle));
  CGFloat maxR = circle.size.width / 2.0 - kRingThickness;
  NSArray<NSColor *> *cellColors = [self _cloudCellColors];
  double angleStep = 2.0 * M_PI / (double)_chromaAngleBins;
  for (NSUInteger a = 0; a < _chromaAngleBins; a++) {
    // Skip the innermost band: it is the neutral pile-up, and drawing it would put
    // a permanent blob over the centre where the puck lives.
    for (NSUInteger ri = 1; ri < _chromaRadiusBins; ri++) {
      double count = bins[a * _chromaRadiusBins + ri].doubleValue;
      if (count <= 0.0)
        continue;
      // Square-rooted: a frame's colour distribution spans orders of magnitude, and
      // linear alpha would show only the single densest cluster.
      double alpha = sqrt(count / peak) * alphaScale;
      if (alpha < 0.02)
        continue;
      double a0 = (double)a * angleStep;
      double r0 = (double)ri / (double)_chromaRadiusBins * maxR;
      double r1 = (double)(ri + 1) / (double)_chromaRadiusBins * maxR;
      NSBezierPath *cell = [NSBezierPath bezierPath];
      [cell appendBezierPathWithArcWithCenter:centre
                                       radius:r1
                                   startAngle:a0 * 180.0 / M_PI
                                     endAngle:(a0 + angleStep) * 180.0 / M_PI];
      [cell appendBezierPathWithArcWithCenter:centre
                                       radius:r0
                                   startAngle:(a0 + angleStep) * 180.0 / M_PI
                                     endAngle:a0 * 180.0 / M_PI
                                    clockwise:YES];
      [cell closePath];
      // Coloured by where it sits, so the cloud reads as the image's own colour
      // rather than as an abstract heat map, and matches the ring above it. Only
      // the alpha is this frame's - the colour came out of the table.
      [[cellColors[a * _chromaRadiusBins + ri]
          colorWithAlphaComponent:MIN(0.85, alpha)] set];
      [cell fill];
    }
  }
}

// The light equivalent of the chroma cloud: each luminance band drawn at the height
// its brightness maps to, in its own grey, as wide as it is populated.
//
// A histogram in a box beside the circle was the obvious thing and was the wrong
// thing - it made the user look somewhere else and relate two pictures. Here the
// frame's tones sit under the puck in the puck's own space, so dragging up toward
// Glow visibly moves the band the glow is coming from.
- (void)_drawToneCloudInRect:(NSRect)circle {
  if (_toneRegionBins.count && _toneRegionPeak > 0.0) {
    [self _drawToneCloudInRect:circle
                          bins:_toneBins
                          peak:_tonePeak
                    alphaScale:kGhostCloudAlpha];
    [self _drawToneCloudInRect:circle
                          bins:_toneRegionBins
                          peak:_toneRegionPeak
                    alphaScale:1.0];
    return;
  }
  [self _drawToneCloudInRect:circle
                        bins:_toneBins
                        peak:_tonePeak
                  alphaScale:1.0];
}

- (void)_drawToneCloudInRect:(NSRect)circle
                        bins:(NSArray<NSNumber *> *)bins
                        peak:(double)peak
                  alphaScale:(double)alphaScale {
  if (bins.count < 2 || peak <= 0.0)
    return;
  NSPoint centre = NSMakePoint(NSMidX(circle), NSMidY(circle));
  CGFloat maxR = circle.size.width / 2.0 - kRingThickness;
  NSUInteger n = bins.count;
  CGFloat bandHeight = (maxR * 2.0) / (CGFloat)n;
  for (NSUInteger i = 0; i < n; i++) {
    double count = bins[i].doubleValue;
    if (count <= 0.0)
      continue;
    // Square-rooted like the chroma cloud, and for the same reason: a frame's tone
    // counts span orders of magnitude, so a linear width would show one band only.
    double fill = sqrt(count / peak);
    if (fill < 0.02)
      continue;
    double t = ((double)i + 0.5) / (double)n; // 0 dark at the bottom, 1 bright up top
    CGFloat y = centre.y + (CGFloat)(t * 2.0 - 1.0) * maxR;
    // Kept inside the disc: the band is as wide as the circle is at that height, so
    // the cloud reads as belonging to the circle rather than overflowing it.
    CGFloat dy = fabs(y - centre.y);
    CGFloat chord = dy >= maxR ? 0.0 : sqrt(maxR * maxR - dy * dy);
    CGFloat half = chord * (CGFloat)fill;
    if (half <= 0.5)
      continue;
    // The ghost is dimmed by ALPHA, never by width: a band's width is how much of
    // the frame is at that brightness, so narrowing it would be a different
    // reading rather than a fainter one.
    [[NSColor colorWithWhite:0.15 + 0.85 * t
                       alpha:(0.28 + 0.34 * fill) * alphaScale] set];
    NSRectFillUsingOperation(NSMakeRect(centre.x - half, y - bandHeight * 0.5,
                                       half * 2.0, MAX(1.0, bandHeight - 0.5)),
                             NSCompositingOperationSourceOver);
  }
}

// The ring's colour for one segment. Light runs dark at the bottom to bright at
// the top so it agrees with the vertical axis it is explaining, rather than
// starting at an arbitrary compass point.
//
// Only the hue ring is tabled. The other two are a `colorWithWhite:` and a
// separator tint - cheap, and the separator is a dynamic colour that has to keep
// resolving against the current appearance rather than being frozen at build time.
- (NSColor *)_ringColorForSegment:(NSUInteger)index {
  switch (self.ring) {
  case MirageColorSurfaceRingLight: {
    double t = (sin(MirageRingSegmentMidAngle(index)) + 1.0) * 0.5;
    return [NSColor colorWithWhite:t alpha:1.0];
  }
  case MirageColorSurfaceRingHue: {
    if (_ringColors.count != kRingSegments) {
      NSMutableArray<NSColor *> *colors =
          [NSMutableArray arrayWithCapacity:kRingSegments];
      for (NSUInteger i = 0; i < kRingSegments; i++) {
        double r = 0.0, g = 0.0, b = 0.0;
        MirageDisplayRGBForOklabHue(MirageRingSegmentMidAngle(i) * 180.0 / M_PI,
                                    &r, &g, &b);
        [colors addObject:[NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0]];
      }
      _ringColors = colors;
    }
    return _ringColors[index];
  }
  case MirageColorSurfaceRingPlain:
  default:
    return [NSColor.separatorColor colorWithAlphaComponent:0.5];
  }
}

- (void)_drawRingInRect:(NSRect)circle {
  CGFloat outer = circle.size.width / 2.0;
  CGFloat inner = outer - kRingThickness;
  NSPoint centre = NSMakePoint(NSMidX(circle), NSMidY(circle));
  double step = 2.0 * M_PI / (double)kRingSegments;
  for (NSUInteger i = 0; i < kRingSegments; i++) {
    double a0 = (double)i * step, a1 = a0 + step * 1.02; // overlap hides seams
    // The ring is a plain legend of even thickness. It used to swell with the
    // luminance distribution, which summarised rather than showed - the actual
    // scope is the cloud inside, where pixels are plotted individually.
    CGFloat thickness = kRingThickness;
    NSBezierPath *seg = [NSBezierPath bezierPath];
    [seg appendBezierPathWithArcWithCenter:centre
                                    radius:outer
                                startAngle:a0 * 180.0 / M_PI
                                  endAngle:a1 * 180.0 / M_PI];
    [seg appendBezierPathWithArcWithCenter:centre
                                    radius:outer - thickness
                                startAngle:a1 * 180.0 / M_PI
                                  endAngle:a0 * 180.0 / M_PI
                                 clockwise:YES];
    [seg closePath];
    NSColor *hue = [self _ringColorForSegment:i];
    // A soft bloom outside the band, in that segment's own colour. Two fading
    // passes rather than a real blur: cheap enough to redraw every frame, and it
    // gives the ring the lit look of a colour wheel instead of a flat swatch.
    for (int pass = 2; pass >= 1; pass--) {
      CGFloat spread = (CGFloat)pass * 2.5;
      NSBezierPath *halo = [NSBezierPath bezierPath];
      [halo appendBezierPathWithArcWithCenter:centre
                                       radius:outer + spread
                                   startAngle:a0 * 180.0 / M_PI
                                     endAngle:a1 * 180.0 / M_PI];
      [halo appendBezierPathWithArcWithCenter:centre
                                       radius:outer
                                   startAngle:a1 * 180.0 / M_PI
                                     endAngle:a0 * 180.0 / M_PI
                                    clockwise:YES];
      [halo closePath];
      [[hue colorWithAlphaComponent:pass == 1 ? 0.22 : 0.09] set];
      [halo fill];
    }
    [hue set];
    [seg fill];
  }
  [[NSColor.separatorColor colorWithAlphaComponent:0.45] set];
  NSBezierPath *edge = [NSBezierPath
      bezierPathWithOvalInRect:NSInsetRect(circle, kRingThickness,
                                           kRingThickness)];
  edge.lineWidth = 1.0;
  [edge stroke];
  (void)inner;
}

// The reference marker: a cross, deliberately not a disc, so it never reads as a
// second draggable puck. It is the tint of the patch the USER picked as something
// that ought to be grey, so its offset from the centre is the error to correct, and
// the correction is to pull the puck the opposite way until the cross reaches the
// middle.
- (void)_drawCentroidInRect:(NSRect)circle {
  if (!self.castAvailable)
    return; // no grey to judge against: say nothing rather than imply balance
  NSPoint centre = NSMakePoint(NSMidX(circle), NSMidY(circle));
  CGFloat maxR = circle.size.width / 2.0 - kRingThickness;
  // The measurement can exceed the circle's scale. Clamped for drawing, but marked:
  // a marker that silently stops moving reads as "the correction stopped working",
  // which is exactly the confusion it caused.
  double cx = self.chromaCast.x, cy = self.chromaCast.y;
  double len = hypot(cx, cy);
  BOOL beyond = len > 0.999;
  if (beyond && len > 0.0) {
    cx /= len;
    cy /= len;
  }
  NSPoint at = NSMakePoint(centre.x + (CGFloat)cx * maxR,
                           centre.y + (CGFloat)cy * maxR);
  if (beyond) {
    // An arc on the rim in the marker's direction: the reading is off the scale that
    // way, so the arrow points where it would be.
    [[NSColor.warning colorWithAlphaComponent:0.8] set];
    double a = atan2(cy, cx) * 180.0 / M_PI;
    NSBezierPath *arc = [NSBezierPath bezierPath];
    [arc appendBezierPathWithArcWithCenter:centre
                                   radius:maxR + 2.0
                               startAngle:a - 7.0
                                 endAngle:a + 7.0];
    arc.lineWidth = 2.5;
    [arc stroke];
  }
  CGFloat arm = 4.0;
  // White with a dark halo so it stays visible over any hue the cloud puts under
  // it.
  for (int pass = 0; pass < 2; pass++) {
    [(pass == 0 ? [NSColor.blackColor colorWithAlphaComponent:0.55]
                : NSColor.whiteColor) set];
    CGFloat w = pass == 0 ? 3.0 : 1.5;
    NSBezierPath *cross = [NSBezierPath bezierPath];
    [cross moveToPoint:NSMakePoint(at.x - arm, at.y)];
    [cross lineToPoint:NSMakePoint(at.x + arm, at.y)];
    [cross moveToPoint:NSMakePoint(at.x, at.y - arm)];
    [cross lineToPoint:NSMakePoint(at.x, at.y + arm)];
    cross.lineWidth = w;
    [cross stroke];
  }
}

// Labels sit OUTSIDE the ring, aligned so they grow away from it: the left one
// ends before the circle, the right one starts after it. Centring them on a point
// at the circle's edge made a wide label straddle the ring, overlapping its own
// first or last character onto the painted band.
//
// A dead axis keeps the same colour as a live one. It still has to be readable -
// it is telling the user what that direction WOULD do - so it is distinguished by
// the dimmed crosshair and the puck refusing to travel, not by unreadable text.
- (void)_drawAxisLabelsInRect:(NSRect)circle {
  NSDictionary *attrs = MirageAxisLabelAttributes();
  CGFloat r = circle.size.width / 2.0;
  NSPoint c = NSMakePoint(NSMidX(circle), NSMidY(circle));
  NSRect b = self.bounds;
  if (self.xAxisLabels.count == 2) {
    NSString *left = self.xAxisLabels[0], *right = self.xAxisLabels[1];
    NSSize ls = [left sizeWithAttributes:attrs];
    NSSize rs = [right sizeWithAttributes:attrs];
    // Each label is drawn into the room that is really there. Normally that is its
    // own width and it lands exactly where it always did; once the circle has hit
    // its floor the rect is narrower and the paragraph style takes the tail.
    CGFloat leftRoom = MAX(0.0, c.x - r - kLabelGap - NSMinX(b));
    CGFloat leftWidth = MIN(ls.width, leftRoom);
    [left drawInRect:NSMakeRect(c.x - r - kLabelGap - leftWidth,
                                c.y - ls.height / 2.0, leftWidth, ls.height)
      withAttributes:attrs];
    CGFloat rightWidth = MIN(rs.width, MAX(0.0, NSMaxX(b) - (c.x + r + kLabelGap)));
    [right drawInRect:NSMakeRect(c.x + r + kLabelGap, c.y - rs.height / 2.0,
                                 rightWidth, rs.height)
       withAttributes:attrs];
  }
  if (self.yAxisLabels.count == 2) {
    NSString *below = self.yAxisLabels[0], *above = self.yAxisLabels[1];
    NSSize bs = [below sizeWithAttributes:attrs];
    NSSize as = [above sizeWithAttributes:attrs];
    // Centred over and under the circle, so it is the VIEW's width these have to
    // fit in - a long enough word overflows sideways even with a small circle.
    CGFloat belowWidth = MIN(bs.width, b.size.width);
    CGFloat aboveWidth = MIN(as.width, b.size.width);
    [below drawInRect:NSMakeRect(c.x - belowWidth / 2.0,
                                 c.y - r - kLabelGap - bs.height, belowWidth,
                                 bs.height)
       withAttributes:attrs];
    [above drawInRect:NSMakeRect(c.x - aboveWidth / 2.0, c.y + r + kLabelGap,
                                 aboveWidth, as.height)
       withAttributes:attrs];
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  NSRect circle = [self _circleRect];
  [self _drawRingInRect:circle];
  if (self.ring == MirageColorSurfaceRingHue) {
    [self _drawChromaCloudInRect:circle];
    [self _drawCentroidInRect:circle];
  } else if (self.ring == MirageColorSurfaceRingLight) {
    [self _drawToneCloudInRect:circle];
  }
  [self _drawAxisLabelsInRect:circle];

  NSPoint centre = NSMakePoint(NSMidX(circle), NSMidY(circle));
  CGFloat travel = circle.size.width / 2.0 - kRingThickness - kPuckRadius;

  if (self.polarAxes) {
    // Distance and bearing, so the guides are a ring and spokes. Halfway is marked
    // because that is where the response curve's slope is still the author's own -
    // past it the puck accelerates toward the control's limits.
    [[NSColor.separatorColor colorWithAlphaComponent:0.35] set];
    NSBezierPath *half = [NSBezierPath
        bezierPathWithOvalInRect:NSMakeRect(centre.x - travel * 0.5,
                                            centre.y - travel * 0.5, travel,
                                            travel)];
    half.lineWidth = 1.0;
    [half stroke];
    [[NSColor.separatorColor colorWithAlphaComponent:0.22] set];
    for (int spoke = 0; spoke < 4; spoke++) {
      double angle = spoke * M_PI_2;
      NSBezierPath *line = [NSBezierPath bezierPath];
      [line moveToPoint:centre];
      [line lineToPoint:NSMakePoint(centre.x + cos(angle) * travel,
                                    centre.y + sin(angle) * travel)];
      line.lineWidth = 1.0;
      [line stroke];
    }
  } else {
    // Crosshair through the centre, dimmed on a dead axis so a direction that
    // cannot move is visibly not draggable.
    [[NSColor.separatorColor colorWithAlphaComponent:self.xAxisLive ? 0.45 : 0.16]
        set];
    NSRectFill(NSMakeRect(centre.x - travel, centre.y - 0.5, travel * 2.0, 1.0));
    [[NSColor.separatorColor colorWithAlphaComponent:self.yAxisLive ? 0.45 : 0.16]
        set];
    NSRectFill(NSMakeRect(centre.x - 0.5, centre.y - travel, 1.0, travel * 2.0));
  }

  // The tracks first, so a handle always sits ON its circle rather than under it.
  for (MirageSurfacePuck *puck in self.pucks) {
    if (puck.trackRadius <= 0.0)
      continue;
    CGFloat r = puck.trackRadius * travel;
    [[NSColor.separatorColor colorWithAlphaComponent:0.5] set];
    NSBezierPath *track = [NSBezierPath
        bezierPathWithOvalInRect:NSMakeRect(centre.x - r, centre.y - r, r * 2.0,
                                            r * 2.0)];
    track.lineWidth = 1.0;
    // Dashed, because a solid ring at an arbitrary radius reads as another scale
    // marking. A dashed one reads as a rail.
    CGFloat dash[2] = {2.0, 3.0};
    [track setLineDash:dash count:2 phase:0.0];
    [track stroke];
  }

  for (NSUInteger i = 0; i < self.pucks.count; i++)
    [self _drawPuck:self.pucks[i]
             active:(i == self.activePuck)
             centre:centre
             travel:travel];
}

- (void)_drawPuck:(MirageSurfacePuck *)puck
           active:(BOOL)active
           centre:(NSPoint)centre
           travel:(CGFloat)travel {
  BOOL pinned = NO;
  NSPoint sits = [self _drawnPositionForPuck:puck pinned:&pinned];
  MirageDrawSurfacePuck(puck, active, pinned,
                        NSMakePoint(centre.x + sits.x * travel,
                                    centre.y + sits.y * travel),
                        self.window.backingScaleFactor);
}

@end

CGFloat MirageSurfacePuckRadius(MirageSurfacePuck *puck) {
  // An icon needs room, so an iconed handle is bigger.
  return puck.icon ? kPuckIconRadius : kPuckRadius;
}

void MirageDrawSurfacePuck(MirageSurfacePuck *puck, BOOL active, BOOL pinned,
                           NSPoint at, CGFloat backingScale) {
  CGFloat radius = MirageSurfacePuckRadius(puck);
  NSRect puckRect = NSMakeRect(at.x - radius, at.y - radius, radius * 2.0,
                               radius * 2.0);
  [[NSColor.controlBackgroundColor colorWithAlphaComponent:0.95] set];
  [[NSBezierPath bezierPathWithOvalInRect:puckRect] fill];
  // Pinned to the rim: the controls have been pushed past what a full-deflection
  // gesture would produce, so the position is the closest the circle can show.
  // Marked rather than silently clamped - otherwise the puck would claim a value
  // the controls no longer hold, which is the one thing it must never do.
  //
  // Every handle is the same colour. Dimming the unselected ones made them genuinely
  // hard to see, and they are not less real than the active one - each is showing a
  // correction that is currently applied. Only the stroke weight marks which one a
  // click in open space would move.
  //
  // One colour for the ring AND its icon, so a handle reads as one object and the
  // warning state colours the whole thing rather than just its outline.
  NSColor *tint = pinned ? NSColor.warning : NSColor.labelColor;
  [tint set];
  NSBezierPath *puckEdge = [NSBezierPath bezierPathWithOvalInRect:puckRect];
  puckEdge.lineWidth = pinned ? 2.0 : (active ? 1.5 : 1.0);
  [puckEdge stroke];

  if (!puck.icon)
    return;
  CGFloat glyph = radius * 1.2;
  // Tinted through a symbol configuration, not by setting a fill colour first: a
  // template image only picks up the current colour when AppKit draws it for a cell,
  // so drawn directly it came out black regardless of what was set.
  NSImage *icon = puck.icon;
  if (@available(macOS 12.0, *))
    icon = [icon imageWithSymbolConfiguration:
                     [NSImageSymbolConfiguration
                         configurationWithHierarchicalColor:tint]];
  // Fit the symbol's OWN aspect inside the glyph box. Squeezing a symbol into a
  // square stretches it, and most SF Symbols are wider than they are tall, so the
  // handle's centre and the glyph's centre ended up a point apart - which is exactly
  // what "slightly off centre" looks like at 9pt.
  //
  // Snapped to DEVICE pixels, not to whole points. Rounding to points quantises the
  // glyph to a 2-device-pixel grid on Retina while the puck's own circle is filled at
  // its exact fractional centre, so a puck landing on an odd device pixel carried its
  // icon up to half a point off and read as off-centre again.
  CGFloat backing = backingScale > 0.0 ? backingScale : 2.0;
  CGFloat (^snap)(CGFloat) = ^CGFloat(CGFloat v) {
    return round(v * backing) / backing;
  };
  NSSize size = icon.size;
  CGFloat side = MAX(size.width, size.height);
  CGFloat scale = side > 0.0 ? glyph / side : 1.0;
  NSSize drawn = NSMakeSize(snap(size.width * scale), snap(size.height * scale));
  [icon drawInRect:NSMakeRect(snap(at.x - drawn.width / 2.0),
                              snap(at.y - drawn.height / 2.0), drawn.width,
                              drawn.height)
          fromRect:NSZeroRect
         operation:NSCompositingOperationSourceOver
          fraction:1.0
    respectFlipped:YES
             hints:nil];
}
