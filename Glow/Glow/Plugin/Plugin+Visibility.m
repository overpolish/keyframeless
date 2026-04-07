/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"

@implementation GlowPlugin (Visibility)

- (void)updateParameterVisibilityAtTime:(CMTime)time {
  [self updateTimingParameterVisibility];

  NSArray<NSNumber *> *hideableParams = @[
    @(kParamColor),
  ];

  if ([self forceShowAllParametersIfEnabled:kParamForceShow
                                   paramIDs:hideableParams
                                     atTime:time])
    return;

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  int colorMode = kColorModeSolid;
  [paramGetAPI getIntValue:&colorMode
             fromParameter:kParamColorMode
                    atTime:time];

  [paramSetAPI setParameterFlags:(colorMode == kColorModeSolid)
                                     ? kFxParameterFlag_DEFAULT
                                     : kFxParameterFlag_HIDDEN
                     toParameter:kParamColor];
}

@end
