/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCurveDefaults.h"
#import "KKEasing.h"
#import "KKScopedDefaults.h"
#import "KKTimeline.h"

static NSString *const kCurveField = @"curve";
static NSString *const kModulationField = @"modulation";

const KKCurveDefault KKCurveDefaultBuiltIn = {
    .curve = KKIntervalCurveEaseInOut,
    .intensity = 0.5,
    .frequency = 0.5,
};

const KKCurveDefault KKModulationDefaultBuiltIn = {
    .curve = KKIntervalModulationNone,
    .intensity = 0.5,
    .frequency = 0.5,
};

static KKCurveDefault KKCurveDefaultsReadField(NSString *field, NSString *scope,
                                               KKCurveDefault builtIn,
                                               NSInteger curveCount) {
  id raw = KKScopedDefaultRead(field, scope);
  if (![raw isKindOfClass:[NSDictionary class]])
    return builtIn;
  NSDictionary *stored = raw;
  KKCurveDefault value = builtIn;
  if ([stored[@"curve"] isKindOfClass:[NSNumber class]]) {
    NSInteger curve = [stored[@"curve"] integerValue];
    if (curve >= 0 && curve < curveCount)
      value.curve = curve;
  }
  if ([stored[@"intensity"] isKindOfClass:[NSNumber class]])
    value.intensity = fmin(1.0, fmax(0.0, [stored[@"intensity"] doubleValue]));
  if ([stored[@"frequency"] isKindOfClass:[NSNumber class]])
    value.frequency = fmin(1.0, fmax(0.0, [stored[@"frequency"] doubleValue]));
  return value;
}

static void KKCurveDefaultsWriteField(NSString *field, KKCurveDefault value,
                                      NSString *scope) {
  KKScopedDefaultWrite(@{
    @"curve" : @(value.curve),
    @"intensity" : @(value.intensity),
    @"frequency" : @(value.frequency),
  },
                       field, scope);
}

KKCurveDefault KKCurveDefaultsRead(NSString *scope) {
  return KKCurveDefaultsReadField(kCurveField, scope, KKCurveDefaultBuiltIn,
                                  KKEasingCurveCount);
}

void KKCurveDefaultsWrite(KKCurveDefault value, NSString *scope) {
  KKCurveDefaultsWriteField(kCurveField, value, scope);
}

BOOL KKCurveDefaultsHasCustom(NSString *scope) {
  return KKScopedDefaultRead(kCurveField, scope) != nil;
}

void KKCurveDefaultsClear(NSString *scope) {
  KKScopedDefaultWrite(nil, kCurveField, scope);
}

// KKIntervalModulationHandheld is the last case, so the count is one past it.
KKCurveDefault KKModulationDefaultsRead(NSString *scope) {
  return KKCurveDefaultsReadField(kModulationField, scope,
                                  KKModulationDefaultBuiltIn,
                                  KKIntervalModulationHandheld + 1);
}

void KKModulationDefaultsWrite(KKCurveDefault value, NSString *scope) {
  KKCurveDefaultsWriteField(kModulationField, value, scope);
}

NSInteger KKModulationToPill(NSInteger modulation) {
  switch (modulation) {
  case KKIntervalModulationWiggle:
    return KKHoldEffectWiggle;
  case KKIntervalModulationOscillate:
    return KKHoldEffectBounce;
  case KKIntervalModulationHandheld:
    return KKHoldEffectHandheld;
  default:
    return KKHoldEffectNone;
  }
}

NSInteger KKPillToModulation(NSInteger pill) {
  switch (pill) {
  case KKHoldEffectWiggle:
    return KKIntervalModulationWiggle;
  case KKHoldEffectBounce:
    return KKIntervalModulationOscillate;
  case KKHoldEffectHandheld:
    return KKIntervalModulationHandheld;
  default:
    return KKIntervalModulationNone;
  }
}
