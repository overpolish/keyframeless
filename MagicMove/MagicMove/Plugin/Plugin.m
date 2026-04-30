/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KeyframelessKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"
@implementation MagicMovePlugin

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  KKLogInfo(@"MagicMovePlugin: initialized");
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

- (BOOL)forceShowAllParameters {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return NO;
  BOOL on = NO;
  [paramGetAPI getBoolValue:&on
              fromParameter:kParamForceShowAlerts
                     atTime:kCMTimeZero];
  return on;
}

- (BOOL)parameterChanged:(UInt32)parameterID
                  atTime:(CMTime)time
                   error:(NSError **)error {
  [self handleLinkedParameterChanged:parameterID atTime:time];
  [self updateTimingParameterVisibility];
  [self updateMotionBlurParameterVisibility];
  [self updateParameterVisibilityAtTime:time];
  [self multiStageHandleParameterChanged:parameterID atTime:time];
  return YES;
}

@end
#pragma clang diagnostic pop
