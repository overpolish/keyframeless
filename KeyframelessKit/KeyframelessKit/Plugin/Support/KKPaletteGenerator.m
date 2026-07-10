/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPaletteGenerator.h"

#import <math.h>

// Approach adapted from David Aerne's "poline" (MIT, github.com/meodai/poline):
// colours live in a disk where HUE is the angle, LIGHTNESS is the radius, and
// SATURATION is a third axis. A palette is a straight-line walk between a few
// anchor points in that disk - so a wide hue sweep naturally dips toward the
// centre (richer, slightly darker mids) instead of interpolating through grey.
// Locked swatches ARE the anchors: the unlocked colours interpolate between
// them, so pinning two colours fills a gradient through them.

typedef struct {
  double h; // 0-360
  double s; // 0-1
  double l; // 0-1
} KKHsl;

static double kkRand(double lo, double hi) {
  double u = (double)arc4random() / (double)UINT32_MAX;
  return lo + u * (hi - lo);
}

static double kkClamp(double v, double lo, double hi) {
  return v < lo ? lo : (v > hi ? hi : v);
}

static double kkNorm360(double h) {
  double m = fmod(h, 360.0);
  return m < 0 ? m + 360.0 : m;
}

// Signed shortest hue delta a -> b, in [-180, 180].
static double kkHueDiff(double a, double b) {
  return fmod(b - a + 540.0, 360.0) - 180.0;
}

static double kkLerp(double a, double b, double t) { return a + (b - a) * t; }

// t-reshaping curves (a subset of poline's position functions).
static double kkEase(int mode, double t) {
  switch (mode) {
  case 1:
    return t * t * (3.0 - 2.0 * t); // smoothstep
  case 2:
    return sin(t * M_PI / 2.0); // sinusoidal
  case 3:
    return 1.0 - sqrt(fmax(0.0, 1.0 - t)); // arc
  default:
    return t; // linear
  }
}

// HSL disk mapping (poline): hue = angle, lightness = radius, saturation = z.
static void kkHslToPoint(KKHsl c, double *x, double *y, double *z) {
  double rad = c.h * M_PI / 180.0;
  double dist = c.l * 0.5;
  *x = 0.5 + dist * cos(rad);
  *y = 0.5 + dist * sin(rad);
  *z = c.s;
}

static KKHsl kkPointToHsl(double x, double y, double z) {
  double deg = kkNorm360(atan2(y - 0.5, x - 0.5) * 180.0 / M_PI);
  double dist = hypot(x - 0.5, y - 0.5);
  return (KKHsl){deg, z, dist / 0.5};
}

static double kkHue2Rgb(double p, double q, double t) {
  if (t < 0)
    t += 1;
  if (t > 1)
    t -= 1;
  if (t < 1.0 / 6.0)
    return p + (q - p) * 6.0 * t;
  if (t < 1.0 / 2.0)
    return q;
  if (t < 2.0 / 3.0)
    return p + (q - p) * (2.0 / 3.0 - t) * 6.0;
  return p;
}

static NSColor *kkHslToColor(KKHsl c) {
  double h = kkNorm360(c.h) / 360.0;
  double s = kkClamp(c.s, 0.0, 1.0);
  double l = kkClamp(c.l, 0.0, 1.0);
  double r, g, b;
  if (s == 0.0) {
    r = g = b = l;
  } else {
    double q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    double p = 2.0 * l - q;
    r = kkHue2Rgb(p, q, h + 1.0 / 3.0);
    g = kkHue2Rgb(p, q, h);
    b = kkHue2Rgb(p, q, h - 1.0 / 3.0);
  }
  return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
}

static KKHsl kkColorToHsl(NSColor *color) {
  NSColor *c = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  if (!c)
    c = color;
  double r = c.redComponent, g = c.greenComponent, b = c.blueComponent;
  double mx = fmax(r, fmax(g, b)), mn = fmin(r, fmin(g, b));
  double l = (mx + mn) / 2.0, s = 0.0, h = 0.0;
  if (mx != mn) {
    double d = mx - mn;
    s = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn);
    if (mx == r)
      h = (g - b) / d + (g < b ? 6.0 : 0.0);
    else if (mx == g)
      h = (b - r) / d + 2.0;
    else
      h = (r - g) / d + 4.0;
    h *= 60.0;
  }
  return (KKHsl){kkNorm360(h), s, l};
}

// Per-mode anchor recipe. Anchors are placed by walking `hueGap` degrees at a
// time from a start hue, alternating light / dark lightness (poline's pair /
// triple defaults) unless `sameHue` (one hue, Shades).
typedef struct {
  int anchors;               // 2 or 3
  double hueGapLo, hueGapHi; // per-gap hue advance (degrees)
  double satLo, satHi;
  double lightLo, lightHi; // "light" anchor lightness range
  double darkLo, darkHi;   // "dark" anchor lightness range
  BOOL sameHue;            // one hue: a radial dark -> light ramp
  int easing;              // 0 linear, 1 smoothstep, 2 sinusoidal, 3 arc
} KKModeCfg;

static KKModeCfg kkCfgForMode(KKPaletteMode mode) {
  switch (mode) {
  case KKPaletteModeBright: // light + saturated moderate journey
    return (KKModeCfg){2, 40, 95, 0.60, 0.90, 0.70, 0.82, 0.50, 0.62, NO, 2};
  case KKPaletteModeDull: // muted + darker moderate journey
    return (KKModeCfg){2, 45, 105, 0.20, 0.40, 0.62, 0.74, 0.34, 0.46, NO, 1};
  case KKPaletteModeShades: // one hue, deep to light
    return (KKModeCfg){2, 0, 0, 0.50, 0.72, 0.86, 0.95, 0.12, 0.20, YES, 1};
  case KKPaletteModeChaotic: // bold three-anchor journey (light-dark-light)
  default:
    return (KKModeCfg){3, 55, 150, 0.55, 0.90, 0.80, 0.90, 0.28, 0.42, NO, 2};
  }
}

// A synthetic endpoint anchor extending the locked journey past its ends.
static KKHsl kkSynthAnchor(double hue, KKModeCfg cfg, BOOL lightEnd) {
  double l = lightEnd ? kkRand(cfg.lightLo, cfg.lightHi)
                      : kkRand(cfg.darkLo, cfg.darkHi);
  return (KKHsl){kkNorm360(hue), kkRand(cfg.satLo, cfg.satHi), l};
}

@implementation KKPaletteGenerator

+ (NSArray<NSColor *> *)paletteWithMode:(KKPaletteMode)mode
                                  count:(NSInteger)count
                                 locked:(NSArray *)locked {
  if (count <= 0)
    return @[];

  KKModeCfg cfg = kkCfgForMode(mode);

  BOOL *isLocked = calloc((size_t)count, sizeof(BOOL));
  KKHsl *lockedHsl = calloc((size_t)count, sizeof(KKHsl));
  NSInteger *lockedIdx = calloc((size_t)count, sizeof(NSInteger));
  NSInteger k = 0;
  for (NSInteger i = 0; i < count; i++) {
    id entry = (locked && i < (NSInteger)locked.count) ? locked[i] : nil;
    if ([entry isKindOfClass:[NSColor class]]) {
      isLocked[i] = YES;
      lockedHsl[i] = kkColorToHsl((NSColor *)entry);
      lockedIdx[k++] = i;
    }
  }

  NSMutableArray<NSColor *> *out = [NSMutableArray arrayWithCapacity:count];

  if (k == 0) {
    // No anchors pinned: invent the whole journey from the mode.
    double startHue = kkRand(0, 360);
    double dir = arc4random_uniform(2) ? 1.0 : -1.0;
    double px[3], py[3], pz[3];
    double h = startHue;
    for (int a = 0; a < cfg.anchors; a++) {
      if (a > 0 && !cfg.sameHue)
        h += kkRand(cfg.hueGapLo, cfg.hueGapHi) * dir;
      double al;
      if (cfg.sameHue)
        al = (a == 0) ? kkRand(cfg.darkLo, cfg.darkHi)
                      : kkRand(cfg.lightLo, cfg.lightHi);
      else
        al = (a % 2 == 0) ? kkRand(cfg.lightLo, cfg.lightHi)
                          : kkRand(cfg.darkLo, cfg.darkHi);
      KKHsl anchor = {kkNorm360(cfg.sameHue ? startHue : h),
                      kkRand(cfg.satLo, cfg.satHi), al};
      kkHslToPoint(anchor, &px[a], &py[a], &pz[a]);
    }
    for (NSInteger i = 0; i < count; i++) {
      double t = count > 1 ? (double)i / (count - 1) : 0.5;
      double scaled = t * (cfg.anchors - 1);
      int seg = (int)floor(scaled);
      if (seg > cfg.anchors - 2)
        seg = cfg.anchors - 2;
      if (seg < 0)
        seg = 0;
      double te = kkEase(cfg.easing, scaled - seg);
      [out addObject:kkHslToColor(
                         kkPointToHsl(kkLerp(px[seg], px[seg + 1], te),
                                      kkLerp(py[seg], py[seg + 1], te),
                                      kkLerp(pz[seg], pz[seg + 1], te)))];
    }
  } else {
    // Locked colours are the anchors; unlocked colours interpolate between
    // them. Endpoints not pinned get a synthetic anchor extending the journey.
    NSInteger cap = k + 2, nA = 0;
    NSInteger *aIdx = calloc((size_t)cap, sizeof(NSInteger));
    double *aX = calloc((size_t)cap, sizeof(double));
    double *aY = calloc((size_t)cap, sizeof(double));
    double *aZ = calloc((size_t)cap, sizeof(double));
    double hFirst = lockedHsl[lockedIdx[0]].h;
    double hLast = lockedHsl[lockedIdx[k - 1]].h;
    double dir = (k >= 2) ? (kkHueDiff(hFirst, hLast) >= 0 ? 1.0 : -1.0)
                          : (arc4random_uniform(2) ? 1.0 : -1.0);

    if (!isLocked[0]) {
      double gap = cfg.sameHue ? 0 : kkRand(cfg.hueGapLo, cfg.hueGapHi);
      KKHsl e = kkSynthAnchor(hFirst - dir * gap, cfg, NO);
      aIdx[nA] = 0;
      kkHslToPoint(e, &aX[nA], &aY[nA], &aZ[nA]);
      nA++;
    }
    for (NSInteger j = 0; j < k; j++) {
      aIdx[nA] = lockedIdx[j];
      kkHslToPoint(lockedHsl[lockedIdx[j]], &aX[nA], &aY[nA], &aZ[nA]);
      nA++;
    }
    if (!isLocked[count - 1]) {
      double gap = cfg.sameHue ? 0 : kkRand(cfg.hueGapLo, cfg.hueGapHi);
      KKHsl e = kkSynthAnchor(hLast + dir * gap, cfg, YES);
      aIdx[nA] = count - 1;
      kkHslToPoint(e, &aX[nA], &aY[nA], &aZ[nA]);
      nA++;
    }

    for (NSInteger i = 0; i < count; i++) {
      if (isLocked[i]) {
        [out addObject:(NSColor *)locked[i]];
        continue;
      }
      NSInteger s = 0;
      for (; s < nA - 1; s++)
        if (aIdx[s] <= i && i <= aIdx[s + 1])
          break;
      double denom = (double)(aIdx[s + 1] - aIdx[s]);
      double local = denom > 0 ? (double)(i - aIdx[s]) / denom : 0.0;
      double te = kkEase(cfg.easing, local);
      [out addObject:kkHslToColor(kkPointToHsl(kkLerp(aX[s], aX[s + 1], te),
                                               kkLerp(aY[s], aY[s + 1], te),
                                               kkLerp(aZ[s], aZ[s + 1], te)))];
    }
    free(aIdx);
    free(aX);
    free(aY);
    free(aZ);
  }

  free(isLocked);
  free(lockedHsl);
  free(lockedIdx);
  return out;
}

+ (NSArray<NSColor *> *)refinedPaletteFrom:(NSArray<NSColor *> *)current
                                    locked:(NSArray *)locked {
  NSMutableArray<NSColor *> *out =
      [NSMutableArray arrayWithCapacity:current.count];
  for (NSInteger i = 0; i < (NSInteger)current.count; i++) {
    id lk = (locked && i < (NSInteger)locked.count) ? locked[i] : nil;
    if ([lk isKindOfClass:[NSColor class]]) {
      [out addObject:current[i]];
      continue;
    }
    KKHsl c = kkColorToHsl(current[i]);
    c.h = kkNorm360(c.h + kkRand(-12.0, 12.0));
    c.s = kkClamp(c.s + kkRand(-0.06, 0.06), 0.0, 1.0);
    c.l = kkClamp(c.l + kkRand(-0.05, 0.05), 0.04, 0.97);
    [out addObject:kkHslToColor(c)];
  }
  return out;
}

@end
