/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKPlugin+Color.h"
#import "KKPlugin_Private.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKAlertView.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKTokens.h>
#import <objc/runtime.h>

static const void *const kColorModesKey = &kColorModesKey;

static NSArray<NSNumber *> *_colorModes(KKPlugin *self) {
  return objc_getAssociatedObject([self class], kColorModesKey) ?: @[
    @(KKColorModeSolid), @(KKColorModeGradient), @(KKColorModeDynamic)
  ];
}

@implementation KKPlugin (Color)

- (BOOL)addColorParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                            modes:(NSArray<NSNumber *> *)modes
                            error:(NSError **)error {
  objc_setAssociatedObject([self class], kColorModesKey, modes,
                           OBJC_ASSOCIATION_COPY_NONATOMIC);

  if (![paramAPI
          addCustomParameterWithName:@""
                         parameterID:kKKParamColorGroup
                        defaultValue:@(kKKParamColorGroup)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH])
    return NO;

  if (![paramAPI addToggleButtonWithName:@""
                             parameterID:kKKParamColorExpanded
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_HIDDEN |
                                         kFxParameterFlag_NOT_ANIMATABLE])
    return NO;

  BOOL hasSolid = [modes containsObject:@(KKColorModeSolid)];
  BOOL hasGradient = [modes containsObject:@(KKColorModeGradient)];

  if (modes.count > 1) {
    NSMutableArray *titles = [NSMutableArray new];
    for (NSNumber *m in modes) {
      switch (m.integerValue) {
      case KKColorModeSolid:
        [titles addObject:@"Solid"];
        break;
      case KKColorModeGradient:
        [titles addObject:@"Gradient"];
        break;
      case KKColorModeDynamic:
        [titles addObject:@"Dynamic"];
        break;
      }
    }
    if (![paramAPI addPopupMenuWithName:@"Color Mode"
                            parameterID:kKKParamColorMode
                           defaultValue:0
                            menuEntries:titles
                         parameterFlags:kFxParameterFlag_HIDDEN |
                                        kFxParameterFlag_NOT_ANIMATABLE])
      return NO;
  }

  if (hasSolid) {
    if (![paramAPI addColorParameterWithName:@"Color"
                                 parameterID:kKKParamColorSolid
                                  defaultRed:1.0
                                defaultGreen:1.0
                                 defaultBlue:1.0
                              parameterFlags:kFxParameterFlag_HIDDEN])
      return NO;
  }

  if (hasGradient) {
    if (![paramAPI addGradientWithName:@"Gradient"
                           parameterID:kKKParamColorGradient
                        parameterFlags:kFxParameterFlag_HIDDEN])
      return NO;
  }

  return YES;
}

- (KKColorResult *)colorAtTime:(CMTime)renderTime {
  static KKLog *sLog;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    sLog = [KKLog loggerForPlugin:@"co.overpolish.keyframeless.Color"];
  });

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI) {
    [sLog warn:@"colorAtTime: paramGetAPI is nil"];
    return [KKColorResult resultWithMode:KKColorModeSolid
                              solidColor:(simd_float3){1, 1, 1}];
  }

  NSArray<NSNumber *> *modes = _colorModes(self);
  int modeIndex = 0;
  if (modes.count > 1)
    [paramGetAPI getIntValue:&modeIndex
               fromParameter:kKKParamColorMode
                      atTime:renderTime];
  KKColorMode mode = (modeIndex >= 0 && modeIndex < (int)modes.count)
                         ? (KKColorMode)modes[modeIndex].integerValue
                         : (KKColorMode)modes.firstObject.integerValue;

  [sLog verbose:@"colorAtTime: modeIndex=%d mode=%ld modes.count=%lu",
                modeIndex, (long)mode, (unsigned long)modes.count];

  if (mode == KKColorModeGradient) {
    float samples[KK_GRADIENT_LUT_SIZE * 4];
    memset(samples, 0, sizeof(samples));
    BOOL ok = [paramGetAPI getGradientSamples:samples
                                   numSamples:KK_GRADIENT_LUT_SIZE
                                        depth:kFxDepth_FLOAT32
                                fromParameter:kKKParamColorGradient
                                       atTime:renderTime];
    if (!ok) {
      [sLog error:@"getGradientSamples failed"];
      return [KKColorResult resultWithMode:KKColorModeSolid
                                solidColor:(simd_float3){1, 1, 1}];
    }
    simd_float3 lut[KK_GRADIENT_LUT_SIZE];
    for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++) {
      float r = samples[i * 4], g = samples[i * 4 + 1], b = samples[i * 4 + 2];
      if (!isfinite(r))
        r = 1;
      if (!isfinite(g))
        g = 1;
      if (!isfinite(b))
        b = 1;
      lut[i] = (simd_float3){r, g, b};
    }
    return [KKColorResult resultWithGradientLUT:lut];
  }

  double r = 1, g = 1, b = 1;
  if (mode == KKColorModeSolid) {
    [paramGetAPI getRedValue:&r
                  greenValue:&g
                   blueValue:&b
               fromParameter:kKKParamColorSolid
                      atTime:renderTime];
  }

  return [KKColorResult
      resultWithMode:mode
          solidColor:(simd_float3){(float)r, (float)g, (float)b}];
}

- (void)updateColorParameterVisibility {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  NSArray<NSNumber *> *modes = _colorModes(self);
  if (modes.count <= 1)
    return;

  FxParameterFlags modeFlags = 0;
  [paramGetAPI getParameterFlags:&modeFlags fromParameter:kKKParamColorMode];
  if (modeFlags != kFxParameterFlag_NOT_ANIMATABLE)
    [paramSetAPI setParameterFlags:kFxParameterFlag_NOT_ANIMATABLE
                       toParameter:kKKParamColorMode];

  int modeIndex = 0;
  [paramGetAPI getIntValue:&modeIndex
             fromParameter:kKKParamColorMode
                    atTime:kCMTimeZero];
  KKColorMode mode = (modeIndex >= 0 && modeIndex < (int)modes.count)
                         ? (KKColorMode)modes[modeIndex].integerValue
                         : (KKColorMode)modes.firstObject.integerValue;

  BOOL hasSolid = [modes containsObject:@(KKColorModeSolid)];
  BOOL hasGradient = [modes containsObject:@(KKColorModeGradient)];

  if (hasSolid) {
    FxParameterFlags want = (mode == KKColorModeSolid)
                                ? kFxParameterFlag_DEFAULT
                                : kFxParameterFlag_HIDDEN;
    FxParameterFlags cur = 0;
    [paramGetAPI getParameterFlags:&cur fromParameter:kKKParamColorSolid];
    if (cur != want)
      [paramSetAPI setParameterFlags:want toParameter:kKKParamColorSolid];
  }

  if (hasGradient) {
    FxParameterFlags want = (mode == KKColorModeGradient)
                                ? kFxParameterFlag_DEFAULT
                                : kFxParameterFlag_HIDDEN;
    FxParameterFlags cur = 0;
    [paramGetAPI getParameterFlags:&cur fromParameter:kKKParamColorGradient];
    if (cur != want)
      [paramSetAPI setParameterFlags:want toParameter:kKKParamColorGradient];
  }
}

@end
