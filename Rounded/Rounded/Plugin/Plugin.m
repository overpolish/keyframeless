/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
  if (parameterID == kParamCropExpanded || parameterID == kParamForceShow)
    [self syncGroupHeaderExpandedForExpandedParamID:kParamCropExpanded];

  // Host cmd-Z reverts `kKKParamMultiStageData` outside our action scopes,
  // so the pump's hot path doesn't see the change. Force a re-read + push
  // when FCP/Motion notifies us the param value changed externally.
  if (parameterID == kKKParamMultiStageData)
    [KKPlugin multiStageRefreshFromParamForAPI:self.apiManager];
  if (parameterID == kKKParamTimingLoopEnabled)
    [KKPlugin multiStageRefreshLoopFromParamForAPI:self.apiManager];

  // Live-update the timing lane's selected segment when an animatable
  // slider changes. paramID → (label, values) is plugin-owned — no
  // `KKAnimatableProperty` lookup.
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (paramGetAPI) {
    if (parameterID == kParamRadius) {
      double v = 0;
      [paramGetAPI getFloatValue:&v fromParameter:kParamRadius atTime:time];
      [self multiStageUpdateSelectedSegmentForLabel:@"Radius" values:@[ @(v) ]];
    } else if (parameterID == kParamCropTop ||
               parameterID == kParamCropBottom ||
               parameterID == kParamCropLeft ||
               parameterID == kParamCropRight) {
      double t = 0, b = 0, l = 0, r = 0;
      [paramGetAPI getFloatValue:&t fromParameter:kParamCropTop atTime:time];
      [paramGetAPI getFloatValue:&b fromParameter:kParamCropBottom atTime:time];
      [paramGetAPI getFloatValue:&l fromParameter:kParamCropLeft atTime:time];
      [paramGetAPI getFloatValue:&r fromParameter:kParamCropRight atTime:time];
      [self
          multiStageUpdateSelectedSegmentForLabel:@"Crop"
                                           values:@[ @(t), @(b), @(l), @(r) ]];
    }
  }
  return YES;
}

- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  if (parameterID == kParamCropExpanded)
    return [NSSet setWithObject:[KKDataBlob class]];
  return [super classesForCustomParameterID:parameterID];
}

@end
#pragma clang diagnostic pop
