/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKGradientSampling.h"
#import "KKColor.h"
#import "KKGradientBarView.h"
#import <AppKit/AppKit.h>

static void _KKStopSRGBA(KKGradientStop *s, CGFloat *r, CGFloat *g, CGFloat *b,
                         CGFloat *a) {
  NSColor *c =
      [s.color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] ?: s.color;
  [c getRed:r green:g blue:b alpha:a];
}

// The gradient's colour at position p (0..1), via its rasterised LUT (which
// bakes in midpoints). Used to resample two gradients onto a common set of stop
// positions so they can be blended even when their stop counts differ.
static NSColor *_KKGradientColorAtPosition(NSArray<KKGradientStop *> *stops,
                                           double p) {
  simd_float3 lut[KK_GRADIENT_LUT_SIZE];
  KKGradientSampleStopsToLUT(stops, lut, KK_GRADIENT_LUT_SIZE);
  double x = MAX(0.0, MIN(1.0, p)) * (KK_GRADIENT_LUT_SIZE - 1);
  int i0 = (int)floor(x);
  int i1 = i0 + 1 < KK_GRADIENT_LUT_SIZE ? i0 + 1 : i0;
  double f = x - i0;
  return [NSColor colorWithSRGBRed:lut[i0].x * (1 - f) + lut[i1].x * f
                             green:lut[i0].y * (1 - f) + lut[i1].y * f
                              blue:lut[i0].z * (1 - f) + lut[i1].z * f
                             alpha:1.0];
}

// Resample `stops` to one stop per position in `positions` (sorted, 0..1).
// Stops landing on the gradient curve don't change its look, so resampling at
// the union of two gradients' positions keeps each endpoint accurate.
static NSArray<KKGradientStop *> *
_KKResampleStopsAtPositions(NSArray<KKGradientStop *> *stops,
                            NSArray<NSNumber *> *positions) {
  NSMutableArray<KKGradientStop *> *out =
      [NSMutableArray arrayWithCapacity:positions.count];
  for (NSNumber *pn in positions)
    [out addObject:[KKGradientStop stopWithPosition:pn.doubleValue
                                              color:_KKGradientColorAtPosition(
                                                        stops, pn.doubleValue)
                                           midpoint:0.5]];
  return out;
}

NSArray<NSNumber *> *KKGradientStopsInterp(NSArray<NSNumber *> *fromFlat,
                                           NSArray<NSNumber *> *toFlat,
                                           double t) {
  NSArray<KKGradientStop *> *aStops = KKGradientStopsFromFlat(fromFlat);
  NSArray<KKGradientStop *> *bStops = KKGradientStopsFromFlat(toFlat);
  if (!aStops.count)
    return fromFlat;

  // When the two keyframes have different stop counts, resample both onto the
  // union of their stop positions so the colours still blend (rather than
  // holding the first keyframe). Equal counts interpolate stop-for-stop.
  NSArray<KKGradientStop *> *ra = aStops, *rb = bStops;
  if (aStops.count && bStops.count && aStops.count != bStops.count) {
    NSMutableArray<NSNumber *> *positions = [NSMutableArray array];
    for (KKGradientStop *s in aStops)
      [positions addObject:@(s.position)];
    for (KKGradientStop *s in bStops)
      [positions addObject:@(s.position)];
    [positions sortUsingSelector:@selector(compare:)];
    NSMutableArray<NSNumber *> *uniq = [NSMutableArray array];
    for (NSNumber *p in positions)
      if (uniq.count == 0 ||
          fabs(uniq.lastObject.doubleValue - p.doubleValue) > 1e-4)
        [uniq addObject:p];
    ra = _KKResampleStopsAtPositions(aStops, uniq);
    rb = _KKResampleStopsAtPositions(bStops, uniq);
  }

  if (!ra.count || ra.count != rb.count)
    return KKGradientFlatFromStops(ra);

  NSMutableArray<KKGradientStop *> *m =
      [NSMutableArray arrayWithCapacity:ra.count];
  for (NSUInteger i = 0; i < ra.count; i++) {
    KKGradientStop *sa = ra[i], *sb = rb[i];
    CGFloat ar, ag, ab, aa, br, bg, bb, ba;
    _KKStopSRGBA(sa, &ar, &ag, &ab, &aa);
    _KKStopSRGBA(sb, &br, &bg, &bb, &ba);
    NSColor *c = [NSColor colorWithSRGBRed:ar + (br - ar) * t
                                     green:ag + (bg - ag) * t
                                      blue:ab + (bb - ab) * t
                                     alpha:aa + (ba - aa) * t];
    [m addObject:[KKGradientStop
                     stopWithPosition:sa.position +
                                      (sb.position - sa.position) * t
                                color:c
                             midpoint:sa.midpoint +
                                      (sb.midpoint - sa.midpoint) * t]];
  }
  return KKGradientFlatFromStops(m);
}

NSArray<NSNumber *> *KKGradientCompositeInterp(NSArray<NSNumber *> *from,
                                               NSArray<NSNumber *> *to,
                                               double t) {
  if (from.count < 2)
    return from;
  double type = from[0].doubleValue; // held - never interpolated
  double aAngle = from[1].doubleValue;
  double bAngle = to.count >= 2 ? to[1].doubleValue : aAngle;
  double angle = aAngle + (bAngle - aAngle) * t;

  NSArray<NSNumber *> *aFlat =
      from.count > 2 ? [from subarrayWithRange:NSMakeRange(2, from.count - 2)]
                     : @[];
  NSArray<NSNumber *> *bFlat =
      to.count > 2 ? [to subarrayWithRange:NSMakeRange(2, to.count - 2)] : @[];

  NSMutableArray<NSNumber *> *out = [@[ @(type), @(angle) ] mutableCopy];
  [out addObjectsFromArray:KKGradientStopsInterp(aFlat, bFlat, t)];
  return out;
}

double KKGradientStopsSignature(NSArray<KKGradientStop *> *stops) {
  if (!stops.count)
    return 0.0;
  double acc = 0.0;
  for (KKGradientStop *s in stops) {
    CGFloat r, g, b, a;
    _KKStopSRGBA(s, &r, &g, &b, &a);
    double lum = 0.299 * r + 0.587 * g + 0.114 * b;
    // Spread the weights so position / colour / midpoint changes all move the
    // result and rarely cancel - a continuous "fingerprint" of the gradient.
    acc += s.position * 0.31 + lum * 0.37 + s.midpoint * 0.13 + r * 0.07 +
           g * 0.11 + b * 0.09 + a * 0.05;
  }
  double v = acc / (double)stops.count;
  return MAX(0.0, MIN(1.0, v));
}

NSString *KKDefaultGradientJSON(void) {
  return @"[{\"p\":0,\"r\":0,\"g\":0,\"b\":0},"
         @"{\"p\":1,\"r\":1,\"g\":1,\"b\":1}]";
}

NSArray<KKGradientStop *> *KKGradientStopsFromJSON(NSString *json) {
  if (!json.length)
    return nil;
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  if (!data)
    return nil;
  NSArray *arr = [NSJSONSerialization JSONObjectWithData:data
                                                 options:0
                                                   error:nil];
  if (![arr isKindOfClass:[NSArray class]])
    return nil;
  NSMutableArray<KKGradientStop *> *stops = [NSMutableArray new];
  for (NSDictionary *d in arr) {
    if (![d isKindOfClass:[NSDictionary class]])
      continue;
    CGFloat midpoint = d[@"m"] ? [d[@"m"] doubleValue] : 0.5;
    [stops addObject:[KKGradientStop
                         stopWithPosition:[d[@"p"] doubleValue]
                                    color:[NSColor
                                              colorWithSRGBRed:[d[@"r"]
                                                                   doubleValue]
                                                         green:[d[@"g"]
                                                                   doubleValue]
                                                          blue:[d[@"b"]
                                                                   doubleValue]
                                                         alpha:1.0]
                                 midpoint:midpoint]];
  }
  return stops.count >= 2 ? stops : nil;
}

NSString *KKGradientJSONFromStops(NSArray<KKGradientStop *> *stops) {
  NSMutableArray *arr = [NSMutableArray new];
  for (KKGradientStop *s in stops) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    NSColor *c = [s.color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (c)
      [c getRed:&r green:&g blue:&b alpha:&a];
    else
      [s.color getRed:&r green:&g blue:&b alpha:&a];
    [arr addObject:@{
      @"p" : @((double)s.position),
      @"r" : @((double)r),
      @"g" : @((double)g),
      @"b" : @((double)b),
      @"m" : @((double)s.midpoint)
    }];
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:arr
                                                 options:0
                                                   error:nil];
  if (!data)
    return nil;
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

void KKGradientSampleStopsToLUT(NSArray<KKGradientStop *> *stops,
                                simd_float3 *lut, int size) {
  if (size <= 0)
    return;
  NSArray<KKGradientStop *> *sorted = [stops
      sortedArrayUsingComparator:^(KKGradientStop *a, KKGradientStop *b) {
        if (a.position < b.position)
          return NSOrderedAscending;
        if (a.position > b.position)
          return NSOrderedDescending;
        return NSOrderedSame;
      }];
  if (sorted.count < 2) {
    simd_float3 fill = (simd_float3){1, 1, 1};
    if (sorted.count == 1) {
      CGFloat r = 0, g = 0, b = 0, a = 0;
      NSColor *c = [sorted.firstObject.color
          colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
      [(c ?: sorted.firstObject.color) getRed:&r green:&g blue:&b alpha:&a];
      fill = (simd_float3){(float)r, (float)g, (float)b};
    }
    for (int i = 0; i < size; i++)
      lut[i] = fill;
    return;
  }
  for (int i = 0; i < size; i++) {
    CGFloat t = (CGFloat)i / (CGFloat)(size - 1);
    KKGradientStop *lo = sorted.firstObject;
    KKGradientStop *hi = sorted.lastObject;
    for (NSUInteger j = 0; j < sorted.count - 1; j++) {
      if (t >= sorted[j].position && t <= sorted[j + 1].position) {
        lo = sorted[j];
        hi = sorted[j + 1];
        break;
      }
    }
    CGFloat f = (hi.position > lo.position)
                    ? (t - lo.position) / (hi.position - lo.position)
                    : 0.0;
    f = fmax(0.0, fmin(1.0, f));
    CGFloat m = lo.midpoint;
    if (m > 0.0 && m < 1.0) {
      if (f <= m)
        f = 0.5 * (f / m);
      else
        f = 0.5 + 0.5 * ((f - m) / (1.0 - m));
    }
    NSColor *blended = [lo.color blendedColorWithFraction:f ofColor:hi.color];
    NSColor *rgb = [blended colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    lut[i] =
        (simd_float3){(float)[rgb redComponent], (float)[rgb greenComponent],
                      (float)[rgb blueComponent]};
  }
}

NSArray<NSNumber *> *KKGradientFlatFromStops(NSArray<KKGradientStop *> *stops) {
  NSMutableArray<NSNumber *> *flat =
      [NSMutableArray arrayWithCapacity:stops.count * 5];
  for (KKGradientStop *s in stops) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    NSColor *c = [s.color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    [(c ?: s.color) getRed:&r green:&g blue:&b alpha:&a];
    [flat addObject:@((double)s.position)];
    [flat addObject:@((double)r)];
    [flat addObject:@((double)g)];
    [flat addObject:@((double)b)];
    [flat addObject:@((double)s.midpoint)];
  }
  return flat;
}

NSArray<NSNumber *> *
KKGradientFlatLUTFromStops(NSArray<KKGradientStop *> *stops, int size) {
  if (size <= 0)
    return @[];
  simd_float3 *lut = (simd_float3 *)malloc(sizeof(simd_float3) * (size_t)size);
  KKGradientSampleStopsToLUT(stops, lut, size);
  NSMutableArray<NSNumber *> *out =
      [NSMutableArray arrayWithCapacity:(NSUInteger)size * 3];
  for (int i = 0; i < size; i++) {
    [out addObject:@((double)lut[i].x)];
    [out addObject:@((double)lut[i].y)];
    [out addObject:@((double)lut[i].z)];
  }
  free(lut);
  return out;
}

NSArray<KKGradientStop *> *KKGradientStopsFromFlat(NSArray<NSNumber *> *flat) {
  if (flat.count < 10 || (flat.count % 5) != 0)
    return nil;
  NSMutableArray<KKGradientStop *> *stops =
      [NSMutableArray arrayWithCapacity:flat.count / 5];
  for (NSUInteger i = 0; i < flat.count; i += 5) {
    double p = flat[i].doubleValue;
    double r = flat[i + 1].doubleValue;
    double g = flat[i + 2].doubleValue;
    double b = flat[i + 3].doubleValue;
    double m = flat[i + 4].doubleValue;
    NSColor *c = [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
    [stops addObject:[KKGradientStop stopWithPosition:p color:c midpoint:m]];
  }
  return stops;
}

NSArray<NSNumber *> *KKGradientInterpFlatLUT(NSArray<NSNumber *> *fromFlat,
                                             NSArray<NSNumber *> *toFlat,
                                             double t, int size) {
  BOOL structural = fromFlat.count >= 10 && fromFlat.count == toFlat.count &&
                    (fromFlat.count % 5) == 0;
  if (structural) {
    NSMutableArray<NSNumber *> *blended =
        [NSMutableArray arrayWithCapacity:fromFlat.count];
    for (NSUInteger i = 0; i < fromFlat.count; i++) {
      double a = fromFlat[i].doubleValue;
      double b = toFlat[i].doubleValue;
      [blended addObject:@(a + (b - a) * t)];
    }
    NSArray<KKGradientStop *> *stops = KKGradientStopsFromFlat(blended);
    return KKGradientFlatLUTFromStops(stops ?: @[], size);
  }
  simd_float3 *lutA = (simd_float3 *)malloc(sizeof(simd_float3) * (size_t)size);
  simd_float3 *lutB = (simd_float3 *)malloc(sizeof(simd_float3) * (size_t)size);
  KKGradientSampleStopsToLUT(KKGradientStopsFromFlat(fromFlat) ?: @[], lutA,
                             size);
  KKGradientSampleStopsToLUT(KKGradientStopsFromFlat(toFlat) ?: @[], lutB,
                             size);
  NSMutableArray<NSNumber *> *out =
      [NSMutableArray arrayWithCapacity:(NSUInteger)size * 3];
  for (int i = 0; i < size; i++) {
    simd_float3 v = lutA[i] + (lutB[i] - lutA[i]) * (float)t;
    [out addObject:@((double)v.x)];
    [out addObject:@((double)v.y)];
    [out addObject:@((double)v.z)];
  }
  free(lutA);
  free(lutB);
  return out;
}
