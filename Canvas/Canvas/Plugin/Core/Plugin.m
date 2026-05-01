/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "KKParamSync.h"
#import "LayerList_Private.h"
#import "ObjectParams.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

@implementation CanvasPlugin

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  KKLogInfo(@"CanvasPlugin: initialized");
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
  if (parameterID == kParamClosedPath || parameterID == kParamSketchFillStyle ||
      parameterID == kParamStrokeColorMode ||
      parameterID == kParamFillColorMode ||
      parameterID == kParamStrokeGradientType ||
      parameterID == kParamFillGradientType) {
    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid)
      KKLayerStateForUUID(uuid).visHash = 0;
  }

  BOOL isColorMode = (parameterID == kParamStrokeColorMode ||
                      parameterID == kParamFillColorMode);
  BOOL isGradType = (parameterID == kParamStrokeGradientType ||
                     parameterID == kParamFillGradientType);
  if (isColorMode || isGradType) {
    BOOL isStroke = (parameterID == kParamStrokeColorMode ||
                     parameterID == kParamStrokeGradientType);
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    int value = 0;
    [getAPI getIntValue:&value fromParameter:parameterID atTime:time];
    NSString *defaultJSON = KKDefaultGradientJSON();
    KKModifySelectedPathProperty(self.apiManager, ^(KKBezierPath *p) {
      if (isColorMode) {
        if (isStroke) {
          p.strokeColorMode = (uint8_t)value;
          if (value == 1 && p.strokeGradientJSON.length == 0)
            p.strokeGradientJSON = defaultJSON;
        } else {
          p.fillColorMode = (uint8_t)value;
          if (value == 1 && p.fillGradientJSON.length == 0)
            p.fillGradientJSON = defaultJSON;
        }
      } else {
        if (isStroke)
          p.strokeGradientType = (uint8_t)value;
        else
          p.fillGradientType = (uint8_t)value;
      }
    });
    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid) {
      KKCanvasStore *store = KKLayerStateForUUID(uuid).store;
      [store performBatch:^{
        if (isColorMode) {
          if (isStroke)
            [store setStrokeColorMode:(uint8_t)value];
          else
            [store setFillColorMode:(uint8_t)value];
        } else {
          if (isStroke)
            [store setStrokeGradientType:(uint8_t)value];
          else
            [store setFillGradientType:(uint8_t)value];
        }
      }];
    }
  }

  if (parameterID == kParamForceShow) {
    // Invalidate the visibility hash so the sync engine re-applies flags
    // on the next drawOSC cycle with the updated forceShow state.
    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid) {
      BOOL fs = NO;
      id<FxParameterRetrievalAPI_v6> fsGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      [fsGetAPI getBoolValue:&fs
               fromParameter:kParamForceShow
                      atTime:kCMTimeZero];
      KKCanvasStore *store = KKLayerStateForUUID(uuid).store;
      [store performBatch:^{
        [store setForceShow:fs];
      }];
    }
    // Touch the blob to trigger a drawOSC redraw.
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    id<FxCustomParameterActionAPI_v4> actAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:self];
    NSString *str = nil;
    [getAPI getStringParameterValue:&str fromParameter:kParamPathData];
    [setAPI setStringParameterValue:str ?: @"" toParameter:kParamPathData];
    [actAPI endAction:self];
  }

  [self handleLinkedParameterChanged:parameterID atTime:time];

  return YES;
}

@end
#pragma clang diagnostic pop
