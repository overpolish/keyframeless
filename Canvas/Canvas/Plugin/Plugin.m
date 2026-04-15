/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "ObjectParams.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

@implementation CanvasPlugin {
  KKLog *_log;
}

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
  self = [super initWithAPIManager:newApiManager];
  return self;
}

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  *properties = @{
    kFxPropertyKey_MayRemapTime : @NO,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @YES
  };

  return YES;
}

- (BOOL)parameterChanged:(UInt32)parameterID
                  atTime:(CMTime)time
                   error:(NSError **)error {
  if (parameterID == kParamClosedPath) {
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    BOOL closed = YES;
    [getAPI getBoolValue:&closed
           fromParameter:kParamClosedPath
                  atTime:kCMTimeZero];
    KKSetLineCapVisible(setAPI, !closed);
  }

  if (parameterID == kParamCornerRadiusTL ||
      parameterID == kParamCornerRadiusTR ||
      parameterID == kParamCornerRadiusBR ||
      parameterID == kParamCornerRadiusBL) {
    CGEventFlags flags =
        CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    if (flags & kCGEventFlagMaskCommand) {
      id<FxParameterRetrievalAPI_v6> getAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      id<FxParameterSettingAPI_v5> setAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      double val = 0;
      [getAPI getFloatValue:&val fromParameter:parameterID atTime:time];
      const UInt32 allRadii[] = {kParamCornerRadiusTL, kParamCornerRadiusTR,
                                 kParamCornerRadiusBR, kParamCornerRadiusBL};
      for (int i = 0; i < 4; i++) {
        if (allRadii[i] != parameterID)
          [setAPI setFloatValue:val toParameter:allRadii[i] atTime:time];
      }
    }
  }

  return YES;
}

@end
#pragma clang diagnostic pop
