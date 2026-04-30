/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

@implementation GlowPlugin

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  KKLogInfo(@"GlowPlugin: initialized");
  self = [super initWithAPIManager:newApiManager];
  return self;
}

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  *properties = @{
    kFxPropertyKey_MayRemapTime : @NO,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @YES,
    kFxPropertyKey_ChangesOutputSize : @YES,
    kFxPropertyKey_NeedsFullBuffer : @YES
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
              fromParameter:kParamForceShow
                     atTime:kCMTimeZero];
  return on;
}

- (BOOL)parameterChanged:(UInt32)parameterID
                  atTime:(CMTime)time
                   error:(NSError **)error {
  [self multiStageHandleParameterChanged:parameterID atTime:time];
  [self multiStageRefreshLaneVisibility];
  switch (parameterID) {
  case kKKParamColorMode:
  case kParamGradientType:
  case kParamForceShow:
  case kKKParamTimingExpanded:
  case kParamNoiseExpanded:
  case kKKParamColorExpanded:
  case kKKParamMotionBlurExpanded:
    [self updateMotionBlurParameterVisibility];
    [self updateParameterVisibilityAtTime:time];
    break;
  case kParamPreset:
    [self applyPresetAtTime:time];
    break;
  default:
    [self handleLinkedParameterChanged:parameterID atTime:time];
    break;
  }
  return YES;
}

@end
#pragma clang diagnostic pop
