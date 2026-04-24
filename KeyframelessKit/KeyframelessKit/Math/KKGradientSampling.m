/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKGradientSampling.h"
#import "../Views/KKGradientBarView.h"
#import <AppKit/AppKit.h>

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
                                              colorWithRed:[d[@"r"] doubleValue]
                                                     green:[d[@"g"] doubleValue]
                                                      blue:[d[@"b"] doubleValue]
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
    NSColor *c = [NSColor colorWithRed:r green:g blue:b alpha:1.0];
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
