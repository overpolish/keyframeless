/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The GRAMMAR of the Grading surface: what a control's `surface=`, `puck=` and
// `pick=` attributes say, how they are read out of a shader's directive
// comments, and the colour measurements those readings depend on. The maths
// that turns a parsed response into puck movement lives in MirageSurfaceAxes.h.
//
// This is the half that grows: a new declaration reads out of the source here,
// and nothing in the axis maths has to know about it. `#slots` - repeatable
// groups of controls, whose members carry `puck={"Colour {n}", ...}` - is big
// enough to own a file, so it sits in MirageSlots.h and is pulled in below,
// which keeps one import for everything a shader may DECLARE.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <math.h>

#import "MirageColorProps.h"        // MirageParseHexColor
#import "MirageColorSurfaceProps.h" // MirageColorSurfaceRing, the ring marker
#import "MirageDirectiveCommon.h"
#import "MirageOklab.h" // the shared sRGB / Oklab maths
#import "MirageSlots.h" // `#slots` - repeatable groups of controls

// --- Polar axes ----------------------------------------------------------
//
// `x:`/`y:` are cartesian, which is right for two independent directions
// (warmer, brighter) and wrong for a wheel. On a hue ring, saturation IS
// distance from the centre and a hue shift IS rotation about it, so expressing
// them as a pair of cartesian controls forces two mappings that do not mean
// what the ring is painting. `r:` and `a:` say it directly:
//
//     // #percent label="Saturation" min=0 max=200 default=100 surface="r:+40"
//     // #float   label="Hue Shift"  min=-180 max=180 default=0
//     surface="a:+180"
//
// `r:` responds to the puck's DISTANCE from the centre, 0 at the middle and
// full deflection at the rim, so the centre is always the control's declared
// default. `a:` responds to its ANGLE, proportionally rather than through the
// curve: the magnitude is the value at half a turn, so `a:+180` makes the
// puck's bearing the hue offset directly. Angle has no rim to accelerate
// toward, and a hue is periodic anyway, so a curve there would only make the
// wheel non-uniform.
//
// A surface is cartesian OR polar. Mixing is rejected rather than blended: the
// two describe the same two degrees of freedom, so a shader declaring both is
// asking for one gesture to mean two things.

/// One control's response to the puck, in the control's own units at full
/// deflection. `present` is NO for a control with no `surface=`.
typedef struct {
  double x;
  double y;
  /// Response to the puck's distance from the centre, 0..1.
  double r;
  /// Response to the puck's bearing, in the control's units per half turn.
  double a;
  int present;
  /// The control's `default=`, which is what a centred puck means. Read from
  /// the same directive line: the author's declared origin, not whatever the
  /// control happens to sit at now, or the puck would always derive to the
  /// centre.
  double base;
  int hasBase;
  /// YES when `base` is a HUE ANGLE in degrees, because the control is a colour
  /// whose `default=` is a hex swatch. A colour's response is a hue rotation,
  /// so its origin has to be an angle rather than a code value - without this a
  /// colour control silently contributed nothing and its whole axis read as
  /// dead.
  int baseIsHue;
  /// The control's declared `min=` / `max=`, so the curve below knows how far
  /// it may travel. `hasLimits` is NO when either is absent, which falls back
  /// to a plain linear response rather than inventing a range.
  double minValue;
  double maxValue;
  int hasLimits;
  /// Which puck drives this control, from `puck={"Shadows", "moon"}`. Empty
  /// means the surface's single unnamed puck, which is what a one-puck shader
  /// gets without saying anything.
  ///
  /// Named pucks are how one wheel carries several independent corrections - a
  /// three-way's shadows, midtones and highlights - without a mode control to
  /// switch between them. They are NOT inferred from `group=`: a shader whose
  /// one gesture spans several inspector groups (a bloom's Threshold, Bloom and
  /// Mist) would otherwise be split into a puck per group.
  char puck[48];
  /// SF Symbol drawn inside that puck, from the second slot of `puck={}`.
  /// Optional: with several pucks in a circle, the icon is the only thing that
  /// says which is which, so a shader declaring more than one should give them
  /// all icons.
  char puckSymbol[48];
  /// `track=0.72`: pin this puck to a circle at that fraction of the radius, so
  /// the drag is a rotation and nothing else. 0 leaves it free.
  ///
  /// For a puck whose controls are all angular, distance is not merely unused -
  /// it is meaningless, and a handle that slides in and out while only its
  /// bearing does anything invites the reading that the middle is "less". A
  /// track says what the gesture actually is. Declared once per puck, on any of
  /// its controls.
  double track;
  /// Which ring this control is attached to, from the `hue` / `light` word at
  /// the front of the value: `surface="light y:+1.5"`. `hasRing` is 0 for the
  /// unmarked form.
  ///
  /// A MARKER rather than position in the file, because the alternative -
  /// binding each control to the nearest `#color-surface` above it - makes the
  /// ORDER of the directives load-bearing, and directives are reordered all the
  /// time to group the inspector. It would also have no failure mode: every
  /// control sits under some surface, so a mis-aimed one would attach silently
  /// to the wrong ring rather than saying so. The word is visible in the line
  /// that owns it.
  int ring;
  int hasRing;
} MirageSurfaceResponse;

/// HSV hue angle of an RGB triple, in degrees, or -1 for a neutral with no
/// meaningful hue. `outSaturation` receives the same triple's saturation, 0..1,
/// which is 0 for that neutral - the two come out of the same max/min pair, so
/// asking twice would compute it twice.
///
/// HSV is NOT the space the grading wheel, the vectorscope or the shader
/// templates speak: it disagrees with Oklab by up to ~30 degrees (HSV 25 is
/// Oklab 50 through the skin region), so a puck pointed at the ring's green
/// landed on a different green than the one under the cursor. Anything that has
/// to agree with the wheel wants MirageSurfaceOklabLCh below instead.
static inline double
MirageSurfaceHueDegreesWithSaturation(double r, double g, double b,
                                      double *outSaturation) {
  double mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
  double c = mx - mn;
  if (outSaturation)
    *outSaturation = mx > 1e-9 ? c / mx : 0.0;
  if (c < 1e-9)
    return -1.0; // grey: rotating it does nothing, so it says nothing
  double h;
  if (mx == r)
    h = fmod((g - b) / c, 6.0);
  else if (mx == g)
    h = (b - r) / c + 2.0;
  else
    h = (r - g) / c + 4.0;
  h *= 60.0;
  return h < 0.0 ? h + 360.0 : h;
}

static inline double MirageSurfaceHueDegrees(double r, double g, double b) {
  return MirageSurfaceHueDegreesWithSaturation(r, g, b, NULL);
}

// --- Oklab, the space the wheel measures in ------------------------------
//
// The grading circle paints its ring and bins its vectorscope cloud in OKLAB
// hue, and the shader templates rotate hue there too. Every colour measurement
// on this surface - a `#color` control's `default=` origin, the swatch the puck
// writes, the bearing the puck derives, the eyedropper's `pick=hue` - therefore
// has to be Oklab as well, or the puck's bearing and the colour under it are
// two different colours.
//
// Input and output are DISPLAY-ENCODED sRGB 0..1, because that is what colour
// lanes and hex `default=` swatches hold. The sRGB transfer function is applied
// here rather than by the callers, so no site can forget it: decoding is the
// difference between the right hue and a plausible wrong one.

/// Display encoding for one linear channel, input clamped to 0..1 first.
///
/// Deliberately NOT `MirageSRGBEncode`, which short-circuits white to exactly
/// 1.0: this one lets white come back through the curve as one ULP under 1.0,
/// which is the value every swatch this surface has ever written.
static inline double MirageSurfaceSRGBEncode(double v) {
  v = v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
  return MirageSRGBEncodeUnclamped(v);
}

/// Oklab lightness, chroma and hue of a display-encoded sRGB triple. `outHDeg`
/// receives -1 for a neutral with no meaningful hue, matching what the HSV
/// helper above reports, so the neutral-skips at every call site are unchanged.
static inline void MirageSurfaceOklabLCh(double r, double g, double b,
                                         double *outL, double *outC,
                                         double *outHDeg) {
  double L = 0.0, chroma = 0.0, hue = 0.0;
  MirageOklabLChOfEncoded(r, g, b, &L, &chroma, &hue);
  if (outL)
    *outL = L;
  if (outC)
    *outC = chroma;
  if (outHDeg) {
    // grey: rotating it does nothing, so it says nothing
    *outHDeg = chroma < 1e-4 ? -1.0 : hue;
  }
}

/// The inverse: a display-encoded sRGB triple for an Oklab L, chroma and hue.
///
/// Rec.709 is a triangle and Oklab is not, so most (L, C, h) requests are
/// simply unreachable. Clamping the out-of-range channels is the cheap answer
/// and the wrong one: it swings the hue that actually lands by 6 to 11 degrees,
/// which is exactly the disagreement between wheel and swatch this whole space
/// change exists to remove. So chroma is HALVED until the colour fits, holding
/// the lightness and - the part that matters - the hue. Eight halvings reach
/// 1/256th of the request, well past the point where anything is still visibly
/// coloured.
static inline void MirageSurfaceEncodedForOklabLCh(double L, double C,
                                                   double hDeg, double *outR,
                                                   double *outG, double *outB) {
  double rad = hDeg * M_PI / 180.0, ca = cos(rad), sa = sin(rad);
  double r = 0.0, g = 0.0, b = 0.0;
  for (int attempt = 0; attempt <= 8; attempt++) {
    MirageOklabToLinear(L, C * ca, C * sa, &r, &g, &b);
    const double e = 1e-4;
    if (r >= -e && r <= 1.0 + e && g >= -e && g <= 1.0 + e && b >= -e &&
        b <= 1.0 + e)
      break;
    C *= 0.5;
  }
  if (outR)
    *outR = MirageSurfaceSRGBEncode(r);
  if (outG)
    *outG = MirageSurfaceSRGBEncode(g);
  if (outB)
    *outB = MirageSurfaceSRGBEncode(b);
}

/// Shortest signed distance from `from` to `to` in degrees, -180..180. Hue is
/// circular, so a plain subtraction would report 350 degrees where the eye sees
/// -10 and throw the derive right across the circle.
static inline double MirageSurfaceHueDelta(double from, double to) {
  double d = fmod(to - from + 540.0, 360.0) - 180.0;
  return d;
}

/// Parse a control's `surface=` response. Accepts `x:` and `y:` terms in either
/// order, signed, whitespace or comma separated: `"y:+30"`, `"x:-4 y:+12"`,
/// `"y:12,x:-3"`.
static inline MirageSurfaceResponse
MirageParseSurfaceResponse(NSString *attrs) {
  MirageSurfaceResponse r;
  memset(&r, 0, sizeof(r));
  NSString *value = MirageAttrString(attrs, @"surface");
  if (!value.length)
    return r;
  static NSRegularExpression *termRe;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    termRe = [NSRegularExpression
        regularExpressionWithPattern:@"([xyra])\\s*:\\s*([-+]?\\d*\\.?\\d+)"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
  });
  for (NSTextCheckingResult *m in
       [termRe matchesInString:value
                       options:0
                         range:NSMakeRange(0, value.length)]) {
    NSString *axis =
        [[value substringWithRange:[m rangeAtIndex:1]] lowercaseString];
    double amount = [value substringWithRange:[m rangeAtIndex:2]].doubleValue;
    if ([axis isEqualToString:@"x"])
      r.x = amount;
    else if ([axis isEqualToString:@"y"])
      r.y = amount;
    else if ([axis isEqualToString:@"r"])
      r.r = amount;
    else
      r.a = amount;
    r.present = 1;
  }
  if (r.present) {
    // The ring marker. Scanned separately from the terms above rather than
    // folded into them: it is a word with no colon, so the term pattern cannot
    // see it, and a shader that names no ring must parse exactly as it did
    // before this existed.
    static NSRegularExpression *ringRe;
    static dispatch_once_t ringOnce;
    dispatch_once(&ringOnce, ^{
      ringRe = [NSRegularExpression
          regularExpressionWithPattern:@"\\b(hue|light)\\b"
                               options:NSRegularExpressionCaseInsensitive
                                 error:nil];
    });
    NSTextCheckingResult *rm =
        [ringRe firstMatchInString:value
                           options:0
                             range:NSMakeRange(0, value.length)];
    if (rm) {
      NSString *word =
          [[value substringWithRange:[rm rangeAtIndex:1]] lowercaseString];
      r.ring = [word isEqualToString:@"light"] ? MirageColorSurfaceRingLight
                                               : MirageColorSurfaceRingHue;
      r.hasRing = 1;
    }
    // `puck={"Name", "symbol"}`, or the bare `puck="Name"`. Same braced-pair
    // shape as `group=`, so there is one spelling for "a name and an icon" to
    // learn.
    MirageParseNamedPairAttr(attrs, @"puck", r.puck, sizeof(r.puck),
                             r.puckSymbol, sizeof(r.puckSymbol));
    // Clamped rather than rejected: a track outside the disc has no circle to
    // draw, and one at the centre is a puck that cannot move at all.
    double track =
        MirageAttrDouble(attrs, @"\\btrack\\s*=\\s*([-+]?\\d*\\.?\\d+)", 0.0);
    if (track > 0.0)
      r.track = fmin(1.0, fmax(0.1, track));
    const double kNoBase = -1.0e300;
    double lo =
        MirageAttrDouble(attrs, @"\\bmin\\s*=\\s*([-+]?\\d*\\.?\\d+)", kNoBase);
    double hi =
        MirageAttrDouble(attrs, @"\\bmax\\s*=\\s*([-+]?\\d*\\.?\\d+)", kNoBase);
    if (lo != kNoBase && hi != kNoBase && hi > lo) {
      r.minValue = lo;
      r.maxValue = hi;
      r.hasLimits = 1;
    }
    double base = MirageAttrDouble(
        attrs, @"\\bdefault\\s*=\\s*([-+]?\\d*\\.?\\d+)", kNoBase);
    if (base != kNoBase) {
      r.base = base;
      r.hasBase = 1;
    } else {
      // A colour control's default is a hex swatch, so its origin is that
      // swatch's hue - measured the way the grading wheel measures hue, since
      // apply, derive and recentre are all angles against this one number.
      NSString *hex = MirageAttrString(attrs, @"default");
      float rgba[4] = {0.0f, 0.0f, 0.0f, 1.0f};
      if (hex.length && MirageParseHexColor(hex, rgba)) {
        double hue = -1.0;
        MirageSurfaceOklabLCh(rgba[0], rgba[1], rgba[2], NULL, NULL, &hue);
        if (hue >= 0.0) {
          r.base = hue;
          r.hasBase = 1;
          r.baseIsHue = 1;
        }
      }
    }
  }
  return r;
}

/// Every control in `source` whose `surface=` declares a response, keyed by its
/// uniform name. A directive with no uniform after it is ignored, matching how
/// every other Mirage directive resolves its control.
static inline NSDictionary<NSString *, NSValue *> *
MirageSurfaceResponsesForSource(NSString *source) {
  NSMutableDictionary<NSString *, NSValue *> *out =
      [NSMutableDictionary dictionary];
  if (!source.length)
    return out;
  static NSRegularExpression *dirRe;
  static NSRegularExpression *uniRe;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dirRe = [NSRegularExpression
        regularExpressionWithPattern:@"(?m)^[ \\t]*//[ \\t]*#[A-Za-z_][\\w-]*"
                                     @"([^\\n]*)$"
                             options:0
                               error:nil];
    uniRe = [NSRegularExpression
        regularExpressionWithPattern:
            @"\\buniform\\s+(?:float|int|vec2|vec3|vec4|bool)\\s+(\\w+)"
                             options:0
                               error:nil];
  });
  NSArray<NSTextCheckingResult *> *dirs =
      [dirRe matchesInString:source
                     options:0
                       range:NSMakeRange(0, source.length)];
  for (NSUInteger i = 0; i < dirs.count; i++) {
    NSTextCheckingResult *dm = dirs[i];
    NSString *attrs = [source substringWithRange:[dm rangeAtIndex:1]];
    MirageSurfaceResponse r = MirageParseSurfaceResponse(attrs);
    if (!r.present)
      continue;
    NSUInteger after = NSMaxRange(dm.range);
    NSUInteger limit =
        (i + 1 < dirs.count) ? dirs[i + 1].range.location : source.length;
    NSTextCheckingResult *um =
        [uniRe firstMatchInString:source
                          options:0
                            range:NSMakeRange(after, limit - after)];
    if (!um)
      continue;
    NSString *name = [source substringWithRange:[um rangeAtIndex:1]];
    out[name] = [NSValue valueWithBytes:&r
                               objCType:@encode(MirageSurfaceResponse)];
  }
  return out;
}

/// YES when `r` is attached to `ring`.
///
/// `dual` is NO for a shader declaring a single `#color-surface`, where there
/// is nothing to disambiguate and every mapping belongs to the one surface
/// whether or not it names a ring. That is what keeps a one-ring shader parsing
/// exactly as it did before the marker existed.
static inline BOOL MirageSurfaceResponseOnRing(MirageSurfaceResponse r,
                                               MirageColorSurfaceRing ring,
                                               BOOL dual) {
  if (!dual)
    return YES;
  return r.hasRing && r.ring == (int)ring;
}

/// The controls attached to one ring, keyed by uniform name.
static inline NSDictionary<NSString *, NSValue *> *
MirageSurfaceResponsesForRing(NSString *source, MirageColorSurfaceRing ring) {
  NSDictionary<NSString *, NSValue *> *all =
      MirageSurfaceResponsesForSource(source);
  if (MirageColorSurfaceRingsForSource(source).count <= 1)
    return all;
  NSMutableDictionary<NSString *, NSValue *> *out =
      [NSMutableDictionary dictionary];
  for (NSString *key in all) {
    MirageSurfaceResponse r;
    [all[key] getValue:&r];
    if (MirageSurfaceResponseOnRing(r, ring, YES))
      out[key] = all[key];
  }
  return out;
}

/// The surface's pucks, in the order their first control appears in the source,
/// as
/// `@{@"name": ..., @"symbol": ...}`. A shader with no `puck=` anywhere gets
/// one entry with an empty name: the single unnamed puck, so callers have one
/// code path.
///
/// Ordered by first appearance rather than by name, and derived from the source
/// rather than from the responses dictionary, because a dictionary's order is
/// arbitrary and the pucks' order decides which one a click lands on and how
/// they are drawn. Shadows, Midtones, Highlights should stay in the order the
/// author wrote them.
///
/// `filterRing` restricts the list to one ring's controls, which is what a
/// shader declaring both rings needs: each circle draws its own handles.
/// Passing NO gathers every puck in the shader.
static inline NSArray<NSDictionary<NSString *, NSString *> *> *
MirageSurfacePucksForSourceFiltered(NSString *source,
                                    MirageColorSurfaceRing ring,
                                    BOOL filterRing) {
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *out =
      [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  if (!source.length)
    return @[ @{@"name" : @"", @"symbol" : @"", @"track" : @""} ];
  NSRegularExpression *dirRe = [NSRegularExpression
      regularExpressionWithPattern:@"(?m)^[ \\t]*//[ \\t]*#[A-Za-z_][\\w-]*"
                                   @"([^\\n]*)$"
                           options:0
                             error:nil];
  for (NSTextCheckingResult *m in
       [dirRe matchesInString:source
                      options:0
                        range:NSMakeRange(0, source.length)]) {
    NSString *attrs = [source substringWithRange:[m rangeAtIndex:1]];
    MirageSurfaceResponse r = MirageParseSurfaceResponse(attrs);
    if (!r.present)
      continue;
    if (filterRing && !MirageSurfaceResponseOnRing(r, ring, YES))
      continue;
    NSString *name = @(r.puck) ?: @"";
    NSString *symbol = @(r.puckSymbol) ?: @"";
    NSString *track = r.track > 0.0 ? [@(r.track) stringValue] : @"";
    if ([seen containsObject:name]) {
      // A puck's icon and track are properties of the PUCK, but they are
      // written on one of its controls, and there is no reason that has to be
      // the first. Fill in whichever slot is still empty rather than making
      // declaration order load- bearing.
      for (NSUInteger i = 0; i < out.count; i++) {
        if (![out[i][@"name"] isEqualToString:name])
          continue;
        NSMutableDictionary *merged = [out[i] mutableCopy];
        if (symbol.length && ![merged[@"symbol"] length])
          merged[@"symbol"] = symbol;
        if (track.length && ![merged[@"track"] length])
          merged[@"track"] = track;
        out[i] = merged;
        break;
      }
      continue;
    }
    [seen addObject:name];
    [out addObject:@{@"name" : name, @"symbol" : symbol, @"track" : track}];
  }
  return out.count ? out
                   : @[ @{@"name" : @"", @"symbol" : @"", @"track" : @""} ];
}

static inline NSArray<NSDictionary<NSString *, NSString *> *> *
MirageSurfacePucksForSource(NSString *source) {
  return MirageSurfacePucksForSourceFiltered(source,
                                             MirageColorSurfaceRingPlain, NO);
}

/// One ring's pucks. A single-surface shader has one ring and every puck is on
/// it, so the filter is only applied once two are declared.
static inline NSArray<NSDictionary<NSString *, NSString *> *> *
MirageSurfacePucksForRing(NSString *source, MirageColorSurfaceRing ring) {
  return MirageSurfacePucksForSourceFiltered(
      source, ring, MirageColorSurfaceRingsForSource(source).count > 1);
}

// --- Attaching a control to a ring ---------------------------------------
//
// With two rings declared, `surface="x:+31 y:+17"` no longer says enough: the
// same gesture means a cast on one circle and an exposure on the other, and
// there is no reading of the shader that decides which. So it becomes an error
// and the author says it:
//
//     // #color-surface ring=hue
//     // #color-surface ring=light
//     // #float ... surface="hue x:+31 y:+17"
//     // #float ... surface="light y:+1.5"
//
// A shader with ONE surface is untouched: the marker is optional there, because
// there is only one thing it could name.

typedef NS_ENUM(NSInteger, MirageSurfaceRingBindingError) {
  MirageSurfaceRingBindingErrorNone = 0,
  /// A `surface=` with no ring word while two rings are declared.
  MirageSurfaceRingBindingErrorUnnamed,
  /// A `surface=` naming a ring this shader does not declare.
  MirageSurfaceRingBindingErrorUnknown,
};

/// The first control whose `surface=` cannot be attached to a ring, named by
/// its `label=` and falling back to its uniform, or nil when every mapping
/// resolves.
static inline NSString *
MirageFirstBadSurfaceRingBinding(NSString *source,
                                 MirageSurfaceRingBindingError *outKind) {
  if (outKind)
    *outKind = MirageSurfaceRingBindingErrorNone;
  NSArray<NSNumber *> *rings = MirageColorSurfaceRingsForSource(source);
  if (!source.length || !rings.count)
    return nil;
  BOOL dual = rings.count > 1;
  NSRegularExpression *dirRe = [NSRegularExpression
      regularExpressionWithPattern:@"(?m)^[ \\t]*//[ \\t]*#[A-Za-z_][\\w-]*"
                                   @"([^\\n]*)$"
                           options:0
                             error:nil];
  NSRegularExpression *uniRe = [NSRegularExpression
      regularExpressionWithPattern:
          @"\\buniform\\s+(?:float|int|vec2|vec3|vec4|bool)\\s+(\\w+)"
                           options:0
                             error:nil];
  NSArray<NSTextCheckingResult *> *dirs =
      [dirRe matchesInString:source
                     options:0
                       range:NSMakeRange(0, source.length)];
  for (NSUInteger i = 0; i < dirs.count; i++) {
    NSString *attrs = [source substringWithRange:[dirs[i] rangeAtIndex:1]];
    MirageSurfaceResponse r = MirageParseSurfaceResponse(attrs);
    if (!r.present)
      continue;
    MirageSurfaceRingBindingError kind = MirageSurfaceRingBindingErrorNone;
    if (r.hasRing) {
      BOOL declared = NO;
      for (NSNumber *boxed in rings)
        if (boxed.integerValue == r.ring)
          declared = YES;
      if (!declared)
        kind = MirageSurfaceRingBindingErrorUnknown;
    } else if (dual) {
      kind = MirageSurfaceRingBindingErrorUnnamed;
    }
    if (kind == MirageSurfaceRingBindingErrorNone)
      continue;
    if (outKind)
      *outKind = kind;
    NSString *label = MirageAttrString(attrs, @"label");
    if (label.length)
      return label;
    NSUInteger after = NSMaxRange(dirs[i].range);
    NSUInteger limit =
        (i + 1 < dirs.count) ? dirs[i + 1].range.location : source.length;
    NSTextCheckingResult *um =
        [uniRe firstMatchInString:source
                          options:0
                            range:NSMakeRange(after, limit - after)];
    return um ? [source substringWithRange:[um rangeAtIndex:1]] : @"?";
  }
  return nil;
}

// --- `pick=`: the eyedropper ---------------------------------------------
//
// What a control receives when the Color panel's eyedropper samples the
// picture:
//
//     // #float label="Target Hue" min=-180 max=180 default=0 pick=hue
//     // #color label="Key"                                   pick=color
//
// Deliberately NOT part of `surface=`. A picked colour is not a gesture on the
// wheel - it is a measurement of the footage - so a control can subscribe to
// the eyedropper without also being dragged by the puck, and one that does both
// is simply declaring two things. Parsing it separately is what keeps them from
// having to know about each other.
//
// Luma comes in two kinds because a control's value lives in one of two light
// spaces and only the shader knows which. `luma` is Rec.709 luma of the
// DISPLAY-ENCODED probe, which is the number the scope and the ring show and
// what a threshold compared against encoded pixels wants. `luma-linear` decodes
// the probe first and weights the LINEAR components, which is what a control
// consumed as light wants - a contrast pivot in `pivot * pow(c / pivot, k)`
// among them. The gap is not small: a face sampled at display 0.55 is linear
// 0.26, so a pivot fed the display number sits about a stop high and the
// contrast rotation happens around the wrong grey.

typedef NS_ENUM(NSInteger, MirageSurfacePickKind) {
  MirageSurfacePickKindNone = 0,
  MirageSurfacePickKindHue,
  MirageSurfacePickKindSaturation,
  MirageSurfacePickKindLuma,
  MirageSurfacePickKindColor,
  MirageSurfacePickKindLumaLinear,
};

/// Parse a `pick=` attribute. An unrecognised value is None rather than an
/// error: the control simply does not subscribe, which is the same thing a typo
/// in any other directive attribute costs.
static inline MirageSurfacePickKind MirageParseSurfacePick(NSString *attrs) {
  NSString *value = [MirageAttrWord(attrs, @"pick") lowercaseString];
  if (!value.length)
    return MirageSurfacePickKindNone;
  if ([value isEqualToString:@"hue"])
    return MirageSurfacePickKindHue;
  if ([value isEqualToString:@"saturation"])
    return MirageSurfacePickKindSaturation;
  if ([value isEqualToString:@"luma"])
    return MirageSurfacePickKindLuma;
  if ([value isEqualToString:@"luma-linear"])
    return MirageSurfacePickKindLumaLinear;
  if ([value isEqualToString:@"color"])
    return MirageSurfacePickKindColor;
  return MirageSurfacePickKindNone;
}

/// Every control in `source` that subscribes to the eyedropper, keyed by its
/// uniform name with a boxed MirageSurfacePickKind. Same directive-then-uniform
/// association as MirageSurfaceResponsesForSource: a directive with no uniform
/// after it is ignored.
static inline NSDictionary<NSString *, NSNumber *> *
MirageSurfacePicksForSource(NSString *source) {
  NSMutableDictionary<NSString *, NSNumber *> *out =
      [NSMutableDictionary dictionary];
  if (!source.length)
    return out;
  static NSRegularExpression *dirRe;
  static NSRegularExpression *uniRe;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dirRe = [NSRegularExpression
        regularExpressionWithPattern:@"(?m)^[ \\t]*//[ \\t]*#[A-Za-z_][\\w-]*"
                                     @"([^\\n]*)$"
                             options:0
                               error:nil];
    uniRe = [NSRegularExpression
        regularExpressionWithPattern:
            @"\\buniform\\s+(?:float|int|vec2|vec3|vec4|bool)\\s+(\\w+)"
                             options:0
                               error:nil];
  });
  NSArray<NSTextCheckingResult *> *dirs =
      [dirRe matchesInString:source
                     options:0
                       range:NSMakeRange(0, source.length)];
  for (NSUInteger i = 0; i < dirs.count; i++) {
    NSTextCheckingResult *dm = dirs[i];
    NSString *attrs = [source substringWithRange:[dm rangeAtIndex:1]];
    MirageSurfacePickKind kind = MirageParseSurfacePick(attrs);
    if (kind == MirageSurfacePickKindNone)
      continue;
    NSUInteger after = NSMaxRange(dm.range);
    NSUInteger limit =
        (i + 1 < dirs.count) ? dirs[i + 1].range.location : source.length;
    NSTextCheckingResult *um =
        [uniRe firstMatchInString:source
                          options:0
                            range:NSMakeRange(after, limit - after)];
    if (!um)
      continue;
    out[[source substringWithRange:[um rangeAtIndex:1]]] = @(kind);
  }
  return out;
}

// --- `preview=`: the controls the Color panel OWNS -----------------------
//
// Two markers, one idea. A marked control is PANEL SESSION STATE: it has no
// inspector row, it is never keyframed, and nothing about it is written to the
// project. The shader declares the uniform so the panel has something to drive,
// and the panel drives it straight into the preview.
//
//     // #bool label="Show Selection" preview=selection
//     uniform bool uShowSelection;
//
//     // #choice label="Preview Key" options="All,1,2,3" preview=active-key
//     uniform int uPreviewKey;
//
// `preview=selection` names the switch that shows the shader's SELECTION - the
// matte a qualifier keys - instead of the graded result. `preview=active-key`
// names the control that says WHICH key that matte is about: 0 for all of them,
// n for the nth instance of the repeatable group.
//
// Why they are not parameters. Both answer "what am I looking at right now",
// which is the question Before and Split answer, and those were never
// parameters either. Making them rows cost three things that all read as bugs:
// a press spent an undo entry, so stepping back through a grade walked through
// the times you glanced at the matte; the value persisted, so a project
// reopened weeks later came up showing a grey diagnostic instead of the shot;
// and the key one was a slider over a ceiling that had nothing to do with how
// many keys were live. Session state has none of those, and the key one needs
// no control at all - the matte follows the puck you are holding.
//
// What the shader sees when the panel is not driving it: the DECLARED DEFAULT,
// in the mini preview and in Final Cut's viewer alike, because no lane exists
// to say otherwise. So author them off - `default=false`, option 0 - and the
// diagnostic never appears in a render.
//
// One of each per shader. A second declaration is ignored rather than rejected:
// the panel has one button and one active handle, and the first control in the
// source is the one it drives.
//
// The marker on the wrong KIND is ignored the way a mistyped `pick=` is: the
// panel drives a specific widget from each, and there is no reading of
// `preview=selection` on a float, or of `preview=active-key` on a colour, that
// says what it would do.

typedef NS_ENUM(NSInteger, MirageSurfacePreviewKind) {
  MirageSurfacePreviewKindNone = 0,
  /// `preview=selection`: this switch renders the matte instead of the result.
  MirageSurfacePreviewKindSelection,
  /// `preview=active-key`: this integer says WHICH key the matte shows, with
  /// zero meaning all of them.
  MirageSurfacePreviewKindActiveKey,
};

/// Parse a `preview=` attribute. An unrecognised value is None, matching what a
/// typo in `pick=` costs: the control simply does not claim anything.
static inline MirageSurfacePreviewKind
MirageParseSurfacePreview(NSString *attrs) {
  NSString *value = [MirageAttrWord(attrs, @"preview") lowercaseString];
  if ([value isEqualToString:@"selection"])
    return MirageSurfacePreviewKindSelection;
  if ([value isEqualToString:@"active-key"])
    return MirageSurfacePreviewKindActiveKey;
  return MirageSurfacePreviewKindNone;
}

/// The uniform under the first control that declares `preview=<want>`, is of
/// `expectDirective` kind, and sits over a `uniform expectUniform`, or nil.
///
/// One walk for both markers, because they answer the same question about
/// different words and a second copy would be a second place for the
/// wrong-kind rule to drift. That rule: the marker on a control of any other
/// kind - and on a directive whose uniform disagrees with it - is IGNORED
/// rather than an error, the way a mistyped `pick=` is. The panel drives a
/// specific widget from each, and there is no reading of `preview=selection` on
/// a float, or of `preview=active-key` on a colour, that says what it would do.
///
/// The directive kind and the uniform type are two parameters rather than one
/// because they genuinely differ: `#choice` is delivered to the shader as an
/// `int`, so the control that says WHICH key is a choice above an integer.
static inline NSString *MirageSurfacePreviewControlForSource(
    NSString *source, MirageSurfacePreviewKind want, NSString *expectDirective,
    NSString *expectUniform) {
  if (!source.length)
    return nil;
  static NSRegularExpression *dirRe;
  static NSRegularExpression *uniRe;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dirRe = [NSRegularExpression
        regularExpressionWithPattern:@"(?m)^[ \\t]*//[ \\t]*#([A-Za-z_][\\w-]*)"
                                     @"([^\\n]*)$"
                             options:0
                               error:nil];
    uniRe = [NSRegularExpression
        regularExpressionWithPattern:
            @"\\buniform\\s+(float|int|vec2|vec3|vec4|bool)\\s+(\\w+)"
                             options:0
                               error:nil];
  });
  NSArray<NSTextCheckingResult *> *dirs =
      [dirRe matchesInString:source
                     options:0
                       range:NSMakeRange(0, source.length)];
  for (NSUInteger i = 0; i < dirs.count; i++) {
    NSTextCheckingResult *dm = dirs[i];
    NSString *kind =
        [[source substringWithRange:[dm rangeAtIndex:1]] lowercaseString];
    NSString *attrs = [source substringWithRange:[dm rangeAtIndex:2]];
    if (MirageParseSurfacePreview(attrs) != want)
      continue;
    if (![kind isEqualToString:expectDirective])
      continue;
    NSUInteger after = NSMaxRange(dm.range);
    NSUInteger limit =
        (i + 1 < dirs.count) ? dirs[i + 1].range.location : source.length;
    NSTextCheckingResult *um =
        [uniRe firstMatchInString:source
                          options:0
                            range:NSMakeRange(after, limit - after)];
    if (!um)
      continue;
    // The DECLARED type as well as the directive kind, so `// #bool ...
    // preview=selection` over a `uniform float` is ignored too - the pair
    // disagreeing is the same mistake as the marker being on the wrong kind.
    if (![[source substringWithRange:[um rangeAtIndex:1]]
            isEqualToString:expectUniform])
      continue;
    return [source substringWithRange:[um rangeAtIndex:2]];
  }
  return nil;
}

/// The uniform name of the shader's selection switch - which is also its lane
/// key - or nil when the shader declares none.
///
/// Only a BOOLEAN control can be it, and the marker on anything else is ignored
/// rather than an error. The panel's button is a two-state toggle: there is no
/// reading of `preview=selection` on a float that says what the button would
/// write, so the honest answer is that the shader declared nothing the panel
/// can show. That keeps a mistyped marker costing exactly what a mistyped
/// `pick=` costs - the feature quietly does not appear - instead of failing a
/// compile over a control the render does not care about.
static inline NSString *
MirageSurfaceSelectionToggleForSource(NSString *source) {
  return MirageSurfacePreviewControlForSource(
      source, MirageSurfacePreviewKindSelection, @"bool", @"bool");
}

/// The uniform name of the shader's active-key control - which is also its lane
/// key - or nil when the shader declares none.
///
/// A `#choice` and nothing else, for the reason only a `#bool` can be the
/// selection switch: the marker names a control the panel DRIVES, and it has to
/// know what shape it is driving. "Which key" is an enumeration - All, then one
/// entry per live key - not a quantity, so a slider was wrong twice over: it
/// offered a range instead of a set, and its range was the declared ceiling
/// rather than the keys that exist. The pill the kit already renders for a
/// choice is the shape, and the catalog trims its options to the live count.
///
/// So the marker on an `#int` is now IGNORED rather than an error, exactly like
/// the marker on any other kind - the same cost a mistyped `pick=` pays.
///
/// One per shader, first in the source wins: there is one active handle.
static inline NSString *
MirageSurfaceActiveKeyControlForSource(NSString *source) {
  // `choice` over `int`: a #choice is delivered to the shader as an integer.
  return MirageSurfacePreviewControlForSource(
      source, MirageSurfacePreviewKindActiveKey, @"choice", @"int");
}

/// Every uniform the Color panel OWNS - the union of the two markers - so the
/// lane catalog can leave them out and the render can ignore anything an older
/// project stored for them.
///
/// This is the whole of "panel-owned" as far as the rest of the code is
/// concerned: a name in here has no row, no keyframes and no stored value, and
/// whatever it reads is whatever the panel is pushing at that moment.
static inline NSSet<NSString *> *
MirageSurfacePreviewOwnedKeys(NSString *source) {
  NSMutableSet<NSString *> *out = [NSMutableSet set];
  NSString *selection = MirageSurfaceSelectionToggleForSource(source);
  if (selection.length)
    [out addObject:selection];
  NSString *activeKey = MirageSurfaceActiveKeyControlForSource(source);
  if (activeKey.length)
    [out addObject:activeKey];
  return out;
}

/// The puck each control names, keyed by uniform name, whether or not the
/// control also declares a `surface=`.
///
/// `puck=` is the HANDLE'S IDENTITY, and belonging to a handle is not the same
/// claim as responding to where that handle sits. A `pick=` target is exactly
/// the control that needs to say the first without the second: it is written by
/// a click on the footage, not dragged, so it has no response to declare - but
/// a three-slot shader still has to be able to say WHICH slot it belongs to, or
/// one click fills every slot with the same colour.
///
/// The parsed response carries `puck` too, but only for a control that declared
/// terms, so it cannot answer this on its own.
static inline NSDictionary<NSString *, NSString *> *
MirageSurfacePuckNamesForSource(NSString *source) {
  NSMutableDictionary<NSString *, NSString *> *out =
      [NSMutableDictionary dictionary];
  if (!source.length)
    return out;
  static NSRegularExpression *dirRe;
  static NSRegularExpression *uniRe;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    dirRe = [NSRegularExpression
        regularExpressionWithPattern:@"(?m)^[ \\t]*//[ \\t]*#[A-Za-z_][\\w-]*"
                                     @"([^\\n]*)$"
                             options:0
                               error:nil];
    uniRe = [NSRegularExpression
        regularExpressionWithPattern:
            @"\\buniform\\s+(?:float|int|vec2|vec3|vec4|bool)\\s+(\\w+)"
                             options:0
                               error:nil];
  });
  NSArray<NSTextCheckingResult *> *dirs =
      [dirRe matchesInString:source
                     options:0
                       range:NSMakeRange(0, source.length)];
  for (NSUInteger i = 0; i < dirs.count; i++) {
    NSTextCheckingResult *dm = dirs[i];
    NSString *attrs = [source substringWithRange:[dm rangeAtIndex:1]];
    char name[48] = {0}, symbol[48] = {0};
    MirageParseNamedPairAttr(attrs, @"puck", name, sizeof(name), symbol,
                             sizeof(symbol));
    if (!name[0])
      continue;
    NSUInteger after = NSMaxRange(dm.range);
    NSUInteger limit =
        (i + 1 < dirs.count) ? dirs[i + 1].range.location : source.length;
    NSTextCheckingResult *um =
        [uniRe firstMatchInString:source
                          options:0
                            range:NSMakeRange(after, limit - after)];
    if (!um)
      continue;
    out[[source substringWithRange:[um rangeAtIndex:1]]] = @(name);
  }
  return out;
}

/// YES when any control in `responses` declares a polar axis, which makes the
/// whole surface polar: `r:`/`a:` and `x:`/`y:` describe the same two degrees
/// of freedom, so the caller honours the polar mappings and skips the cartesian
/// ones rather than letting one gesture mean two things.
static inline BOOL
MirageSurfaceResponsesArePolar(NSDictionary<NSString *, NSValue *> *responses) {
  for (NSValue *boxed in responses.allValues) {
    MirageSurfaceResponse r;
    [boxed getValue:&r];
    if (fabs(r.r) > 0.0 || fabs(r.a) > 0.0)
      return YES;
  }
  return NO;
}

#endif
