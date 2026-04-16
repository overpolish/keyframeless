/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "LayerList_Private.h"
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
    BOOL strokeOn = NO, strokeExp = NO;
    [getAPI getBoolValue:&strokeOn
           fromParameter:kParamStrokeEnabled
                  atTime:kCMTimeZero];
    [getAPI getBoolValue:&strokeExp
           fromParameter:kParamExpandedStroke
                  atTime:kCMTimeZero];
    KKSetLineCapVisible(setAPI, !closed && strokeOn && strokeExp);
  }

  if (parameterID == kParamSketchFillStyle) {
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    BOOL fillOn = NO, fillExp = NO;
    [getAPI getBoolValue:&fillOn
           fromParameter:kParamFillEnabled
                  atTime:kCMTimeZero];
    [getAPI getBoolValue:&fillExp
           fromParameter:kParamExpandedFill
                  atTime:kCMTimeZero];
    if (fillOn && fillExp) {
      int fillStyle = KKReadSelectedFillStyle(getAPI);
      KKSetFillStyleParamsVisible(setAPI, YES, fillStyle);
    }
  }

  if (parameterID == kParamForceShow) {
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    BOOL forceShow = NO;
    [getAPI getBoolValue:&forceShow
           fromParameter:kParamForceShow
                  atTime:kCMTimeZero];
    if (forceShow) {
      KKShowObjectParams(setAPI);
      KKSetStrokeChildrenVisible(setAPI, YES, YES);
      KKSetLineCapVisible(setAPI, YES);
      KKSetMarkersVisible(setAPI, YES);
      KKSetMarkerSizeVisible(setAPI, 1, 1);
      KKSetLineJoinVisible(setAPI, YES);
      KKSetStrokeStyleVisible(setAPI, YES);
      [setAPI setParameterFlags:kFxParameterFlag_DEFAULT
                    toParameter:kParamDashLength];
      [setAPI setParameterFlags:kFxParameterFlag_DEFAULT
                    toParameter:kParamDashGap];
      [setAPI setParameterFlags:kFxParameterFlag_DEFAULT
                    toParameter:kParamDotGap];
      KKSetFillChildrenVisible(setAPI, YES, YES);
      KKSetFillStyleParamsVisible(setAPI, YES, 1);
      KKSetSketchChildrenVisible(setAPI, YES, YES);
    } else {
      NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
      if (uuid)
        KKLayerStateForUUID(uuid).forceRefresh = YES;
      id<FxCustomParameterActionAPI_v4> actAPI = [self.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:self];
      NSString *str = nil;
      [getAPI getStringParameterValue:&str fromParameter:kParamPathData];
      [setAPI setStringParameterValue:str ?: @"" toParameter:kParamPathData];
      [actAPI endAction:self];
    }
  }

  return YES;
}

@end
#pragma clang diagnostic pop
