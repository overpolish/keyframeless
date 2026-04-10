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
                                 @(kParamOffsetX), @(kParamOffsetY),
                                 @(kKKParamColorMode), @(kKKParamColorSolid),
                                 @(kKKParamColorGradient),
                                 @(kParamGradientType), @(kParamGradientAngle)
                               ]
                                 atTime:time];
    if (forceShow)
      return;

    // --- Offset group ---
    BOOL offsetExpanded = NO;
    [paramGetAPI getBoolValue:&offsetExpanded
                fromParameter:kParamOffsetExpanded
                       atTime:kCMTimeZero];

    FxParameterFlags offsetFlags =
        offsetExpanded ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
    setFlagsIfChanged(paramSetAPI, paramGetAPI, offsetFlags, kParamOffsetX);
    setFlagsIfChanged(paramSetAPI, paramGetAPI, offsetFlags, kParamOffsetY);

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

      BOOL isGradient = (colorMode == KKColorModeGradient);

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
      setFlagsIfChanged(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                        kKKParamColorGradient);
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
