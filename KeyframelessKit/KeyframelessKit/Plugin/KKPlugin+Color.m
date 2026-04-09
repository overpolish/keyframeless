/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKPlugin+Color.h"
#import "KKPlugin_Private.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKAlertView.h>
#import <KeyframelessKit/KKTokens.h>
#import <objc/runtime.h>

static const void *const kColorModesKey = &kColorModesKey;

static NSArray<NSNumber *> *_colorModes(KKPlugin *self) {
  return objc_getAssociatedObject([self class], kColorModesKey)
             ?: @[ @(KKColorModeSolid) ];
}

@implementation KKPlugin (Color)

- (BOOL)addColorParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                            modes:(NSArray<NSNumber *> *)modes
                            error:(NSError **)error {
  objc_setAssociatedObject([self class], kColorModesKey, modes,
                           OBJC_ASSOCIATION_COPY_NONATOMIC);

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
    if (![paramAPI
            addPopupMenuWithName:@"Color Mode"
                     parameterID:kKKParamColorMode
                    defaultValue:(UInt32)modes.firstObject.unsignedIntValue
                     menuEntries:titles
                  parameterFlags:kFxParameterFlag_NOT_ANIMATABLE])
      return NO;
  }

  if (hasSolid) {
    if (![paramAPI addColorParameterWithName:@"Color"
                                 parameterID:kKKParamColorSolid
                                  defaultRed:1.0
                                defaultGreen:1.0
                                 defaultBlue:1.0
                              parameterFlags:kFxParameterFlag_DEFAULT])
      return NO;
  }

  if (hasGradient) {
    if (![paramAPI addGradientWithName:@"Gradient"
                           parameterID:kKKParamColorGradient
                        parameterFlags:kFxParameterFlag_DEFAULT])
      return NO;
  }

  return YES;
}

- (KKColorResult *)colorAtTime:(CMTime)renderTime {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

  NSArray<NSNumber *> *modes = _colorModes(self);
  int modeIndex = 0;
  if (modes.count > 1)
    [paramGetAPI getIntValue:&modeIndex
               fromParameter:kKKParamColorMode
                      atTime:renderTime];
  KKColorMode mode = (modeIndex >= 0 && modeIndex < (int)modes.count)
                         ? (KKColorMode)modes[modeIndex].integerValue
                         : (KKColorMode)modes.firstObject.integerValue;

  if (mode == KKColorModeGradient) {
    float samples[KK_GRADIENT_LUT_SIZE * 4];
    [paramGetAPI getGradientSamples:samples
                         numSamples:KK_GRADIENT_LUT_SIZE
                              depth:kFxDepth_FLOAT32
                      fromParameter:kKKParamColorGradient
                             atTime:renderTime];
    simd_float3 lut[KK_GRADIENT_LUT_SIZE];
    for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++) {
      lut[i] =
          (simd_float3){samples[i * 4], samples[i * 4 + 1], samples[i * 4 + 2]};
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
