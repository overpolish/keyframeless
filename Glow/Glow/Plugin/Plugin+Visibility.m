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

  [self updateTimingParameterVisibility];
  [self updateColorParameterVisibility];

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  if ([self
          forceShowAllParametersIfEnabled:kParamForceShow
                                 paramIDs:@[
                                   @(kParamGradientType), @(kParamGradientAngle)
                                 ]
                                   atTime:time]) {
    sUpdating = NO;
    return;
  }

  int colorMode = 0, gradType = 0;
  [paramGetAPI getIntValue:&colorMode
             fromParameter:kKKParamColorMode
                    atTime:time];
  [paramGetAPI getIntValue:&gradType
             fromParameter:kParamGradientType
                    atTime:time];

  BOOL isGradient = (colorMode == KKColorModeGradient);

  setFlagsIfChanged(
      paramSetAPI, paramGetAPI,
      isGradient ? kFxParameterFlag_NOT_ANIMATABLE
                 : (kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE),
      kParamGradientType);

  BOOL showAngle = isGradient && (gradType == 1);
  setFlagsIfChanged(paramSetAPI, paramGetAPI,
                    showAngle ? kFxParameterFlag_DEFAULT
                              : kFxParameterFlag_HIDDEN,
                    kParamGradientAngle);

  sUpdating = NO;
}

@end
