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

- (BOOL)parameterChanged:(UInt32)parameterID
                  atTime:(CMTime)time
                   error:(NSError **)error {
  if (parameterID == kParamUIState) {
    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSString *json = KKReadCustomParamString(getAPI, kParamUIState);
    [actionAPI endAction:self];
    NSDictionary *state =
        (json.length ? [NSJSONSerialization
                           JSONObjectWithData:
                               [json dataUsingEncoding:NSUTF8StringEncoding]
                                      options:0
                                        error:nil]
                     : nil)
            ?: @{};
    BOOL enabled = [state[@"loopEnabled"] boolValue];
    NSInteger tab = [state[@"activeTab"] integerValue];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.inspectorView setLoopEnabled:enabled];
      [self.inspectorView setActiveTab:tab];
    });
  }
  return YES;
}

- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  if (parameterID == kKKParamTimelineData || parameterID == kParamUIState)
    return [NSSet setWithObject:[KKDataBlob class]];
  return [super classesForCustomParameterID:parameterID];
}

#pragma clang diagnostic pop
@end
