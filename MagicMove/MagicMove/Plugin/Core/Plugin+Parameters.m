/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Constants.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMovePlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error {
  id<FxParameterCreationAPI_v5> api =
      [self.apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
  BOOL ok = api && [api addToggleButtonWithName:@"Legacy Link Properties"
                                  parameterID:MMLinkProperties defaultValue:NO
                               parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_HIDDEN)];
  for (MMTimingLane *lane in self.timingLanes) {
    BOOL isScale = lane.valueID == MMScale;
    ok = ok &&
        [api addFloatSliderWithName:(isScale ? @"Scale" : @"Position X") parameterID:lane.valueID
                      defaultValue:(isScale ? 100 : 0) parameterMin:(isScale ? 0 : -200)
                      parameterMax:(isScale ? 400 : 200)
                         sliderMin:(isScale ? 0 : -200) sliderMax:(isScale ? 400 : 200)
                             delta:0.01 parameterFlags:0] &&
        [api addToggleButtonWithName:@"Link this pose" parameterID:lane.linkEditorID
                       defaultValue:NO
                     parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE |
                                     kFxParameterFlag_DISABLED)] &&
        [api addToggleButtonWithName:@"Match In/Out" parameterID:lane.matchEditorID defaultValue:NO
                     parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE | kFxParameterFlag_DISABLED)] &&
        [api addToggleButtonWithName:@"Legacy Match Out" parameterID:(isScale ? MMScaleLegacyMatchOut : MMPositionLegacyMatchOut) defaultValue:NO
                     parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE | kFxParameterFlag_HIDDEN)] &&
        [api addToggleButtonWithName:@"Use available time" parameterID:lane.availableTimeID
                       defaultValue:NO
                     parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE |
                                     kFxParameterFlag_DISABLED)] &&
        [api addFloatSliderWithName:@"Duration" parameterID:lane.durationID
                      defaultValue:1.2 parameterMin:0 parameterMax:60
                         sliderMin:0 sliderMax:60 delta:0.01
                    parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE |
                                    kFxParameterFlag_DISABLED)] &&
        [api addCustomParameterWithName:(isScale ? @"Scale Duration Data" : @"Duration Data")
                           parameterID:lane.dataID defaultValue:(id)[KKDataBlob blobWithString:@"[]"]
                         parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_HIDDEN)];
  }
  if (!ok && error) {
    *error = [NSError errorWithDomain:FxPlugErrorDomain code:kFxError_APIUnavailable
                            userInfo:@{NSLocalizedDescriptionKey: @"Unable to create Magic Move controls"}];
  }
  return ok;
}
@end
#pragma clang diagnostic pop
