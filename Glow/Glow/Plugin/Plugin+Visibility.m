/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"

static void setFlagsIfChanged(id<FxParameterSettingAPI_v5> setAPI,
                              id<FxParameterRetrievalAPI_v6> getAPI,
                              FxParameterFlags newFlags, UInt32 paramID) {
  FxParameterFlags current = 0;
  [getAPI getParameterFlags:&current fromParameter:paramID];
  if (current != newFlags)
    [setAPI setParameterFlags:newFlags toParameter:paramID];
}

@implementation GlowPlugin (Visibility)

- (void)updateParameterVisibilityAtTime:(CMTime)time {
  static BOOL sUpdating = NO;
  if (sUpdating)
    return;
  sUpdating = YES;
  @try {
    [self updateTimingParameterVisibility];

    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

    BOOL forceShow = [self
        forceShowAllParametersIfEnabled:kParamForceShow
                               paramIDs:@[
                                 @(kParamNoise), @(kParamNoiseOffset),
                                 @(kParamNoiseSpeed), @(kKKParamColorMode),
                                 @(kKKParamColorSolid),
                                 @(kKKParamColorCustomUI),
                                 @(kParamGradientType), @(kParamGradientAngle)
                               ]
                                 atTime:time];
    if (forceShow)
      return;

    // --- Noise group ---
    BOOL noiseExpanded = NO;
    [paramGetAPI getBoolValue:&noiseExpanded
                fromParameter:kParamNoiseExpanded
                       atTime:kCMTimeZero];

    FxParameterFlags noiseFlags =
        noiseExpanded ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
    setFlagsIfChanged(paramSetAPI, paramGetAPI, noiseFlags, kParamNoise);
    setFlagsIfChanged(paramSetAPI, paramGetAPI, noiseFlags, kParamNoiseOffset);
    setFlagsIfChanged(paramSetAPI, paramGetAPI, noiseFlags, kParamNoiseSpeed);

    // --- Color group ---
    BOOL colorExpanded = NO;
    [paramGetAPI getBoolValue:&colorExpanded
                fromParameter:kKKParamColorExpanded
                       atTime:kCMTimeZero];

    if (colorExpanded) {
      [self updateColorParameterVisibility];

      int colorMode = 0, gradType = 0;
      [paramGetAPI getIntValue:&colorMode
                 fromParameter:kKKParamColorMode
                        atTime:time];
      [paramGetAPI getIntValue:&gradType
                 fromParameter:kParamGradientType
                        atTime:time];

      BOOL isGradient = (colorMode == 2); // Gradient (index 2 in modes array)

      setFlagsIfChanged(paramSetAPI, paramGetAPI,
                        isGradient ? kFxParameterFlag_NOT_ANIMATABLE
                                   : (kFxParameterFlag_HIDDEN |
                                      kFxParameterFlag_NOT_ANIMATABLE),
                        kParamGradientType);

      BOOL showAngle = isGradient && (gradType == 1);
      setFlagsIfChanged(paramSetAPI, paramGetAPI,
                        showAngle ? kFxParameterFlag_DEFAULT
                                  : kFxParameterFlag_HIDDEN,
                        kParamGradientAngle);
    } else {
      setFlagsIfChanged(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                        kKKParamColorMode);
      setFlagsIfChanged(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                        kKKParamColorSolid);
      setFlagsIfChanged(paramSetAPI, paramGetAPI,
                        kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_HIDDEN,
                        kKKParamColorCustomUI);
      setFlagsIfChanged(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                        kParamGradientType);
      setFlagsIfChanged(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                        kParamGradientAngle);
    }

  } @finally {
    sUpdating = NO;
  }
}

@end
