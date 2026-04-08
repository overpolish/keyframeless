/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"

@implementation GlowPlugin (Visibility)

- (void)updateParameterVisibilityAtTime:(CMTime)time {
  [self updateTimingParameterVisibility];
  [self updateColorParameterVisibility];

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  int colorMode = 0, gradType = 0;
  [paramGetAPI getIntValue:&colorMode
             fromParameter:kKKParamColorMode
                    atTime:time];
  [paramGetAPI getIntValue:&gradType
             fromParameter:kParamGradientType
                    atTime:time];

  BOOL isGradient = (colorMode == KKColorModeGradient);

  [paramSetAPI
      setParameterFlags:(isGradient ? (kFxParameterFlag_NOT_ANIMATABLE)
                                    : (kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE))
            toParameter:kParamGradientType];

  BOOL showAngle = isGradient && (gradType == 1);
  [paramSetAPI setParameterFlags:(showAngle ? kFxParameterFlag_DEFAULT
                                            : kFxParameterFlag_HIDDEN)
                     toParameter:kParamGradientAngle];
}

@end
