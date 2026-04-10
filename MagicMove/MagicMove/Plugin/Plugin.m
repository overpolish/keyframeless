/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KeyframelessKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"
@implementation MagicMovePlugin

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  self.log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
  [self.log
      info:@"MagicMovePlugin: initWithAPIManager called - plugin is loading"];
  self = [super initWithAPIManager:newApiManager];
  if (self != nil) {
    [self.log info:@"MagicMovePlugin: Successfully initialized"];
  }
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
  if (parameterID == kParamPreviewA || parameterID == kParamPreviewB ||
      parameterID == kParamPreviewDrift || parameterID == kParamPreviewExit) {
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    BOOL isOn = NO;
    [paramGetAPI getBoolValue:&isOn fromParameter:parameterID atTime:time];
    if (isOn) {
      const UInt32 allPreviews[] = {kParamPreviewA, kParamPreviewB,
                                    kParamPreviewDrift, kParamPreviewExit};
      for (int i = 0; i < 4; i++) {
        if (allPreviews[i] != parameterID)
          [paramSetAPI setBoolValue:NO toParameter:allPreviews[i] atTime:time];
      }
    }
  }
  [self handleLinkedParameterChanged:parameterID atTime:time];
  [self updateParameterVisibilityAtTime:time];
  return YES;
}

@end
#pragma clang diagnostic pop
