/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

@implementation RoundedPlugin

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  KKLogInfo(@"RoundedPlugin: initialized");
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
              fromParameter:kParamForceShow
                     atTime:kCMTimeZero];
  return on;
}

- (BOOL)parameterChanged:(UInt32)parameterID
                  atTime:(CMTime)time
                   error:(NSError **)error {
  // `updateTimingParameterVisibility` is gated to specific params — its
  // deferred body has been pruned to just the curve-preview flag write so it
  // no longer triggers the cascade documented in
  // project_published_custom_ui_cascade.md, but firing it on every
  // `parameterChanged:` (incl. initial-render param hydration) was the
  // historical crash trigger. Only call it when the input would change the
  // outcome.
  if (parameterID == kParamForceShow || parameterID == kKKParamTimingExpanded)
    [self updateTimingParameterVisibility];
  [self updateMotionBlurParameterVisibility];
  [self updateCropParameterVisibility];
  [self multiStageHandleParameterChanged:parameterID atTime:time];
  return YES;
}

@end
#pragma clang diagnostic pop
