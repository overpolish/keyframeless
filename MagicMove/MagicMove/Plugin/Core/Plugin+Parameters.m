/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Constants.h"
#import "Plugin_Private.h"
#import "MMCombinedPose.h"
#import "MMScalePose.h"
#import "MMScalarPose.h"
#import "MMRotationPose.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMovePlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error {
  id<FxParameterCreationAPI_v5> api =
      [self.apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
  BOOL ok = api && [api addToggleButtonWithName:@"Legacy Link Properties"
                                  parameterID:MMLinkProperties defaultValue:NO
                               parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_HIDDEN)];
  // A saved, non-animatable scratch value invalidates the host's cached frame.
  // DONT_SAVE writes propagate late in the host, so this value must be saved.
  ok = ok && [api addCustomParameterWithName:@"Host Refresh" parameterID:MMHostRefreshToken
      defaultValue:@"" parameterFlags:(kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE)];
  ok = ok && [api addCustomParameterWithName:@"" parameterID:MMHeaderControls defaultValue:@0
      parameterFlags:(kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_USE_FULL_VIEW_WIDTH | kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE)];
  ok = ok && [api addCustomParameterWithName:@"" parameterID:MMScaleControls
                                defaultValue:[[MMScalePose alloc] initWithX:100 y:100 authored:NO]
                              parameterFlags:(kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_USE_FULL_VIEW_WIDTH)];
  ok = ok && [api addCustomParameterWithName:@"" parameterID:MMCustomControls
                                defaultValue:[[MMCombinedPose alloc] initWithPositionX:0 scale:100 authored:NO]
                              parameterFlags:(kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_USE_FULL_VIEW_WIDTH)];
  for(MMPropertyLane *lane in MMPropertyLanes()) {
    ok = ok && [api addCustomParameterWithName:@"" parameterID:lane.parameterID defaultValue:(id)lane.defaultPose
        parameterFlags:(kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_USE_FULL_VIEW_WIDTH)];
    ok = ok && [api addStringParameterWithName:@"Property view cache" parameterID:lane.cacheTokenID defaultValue:@""
        parameterFlags:(kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE)];
  }
  ok = ok && [api addCustomParameterWithName:@"" parameterID:MMTimingControls defaultValue:@0
      parameterFlags:(kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_USE_FULL_VIEW_WIDTH | kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE)];
  ok = ok && [api addStringParameterWithName:@"Scale view cache" parameterID:MMScaleCacheToken
                                defaultValue:@"" parameterFlags:(kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE)];
  ok = ok && [api addToggleButtonWithName:@"Scale Proportional" parameterID:MMScaleProportional
                           defaultValue:YES parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_HIDDEN)];
  ok = ok && [api addStringParameterWithName:@"Combined view cache" parameterID:MMCombinedCacheToken
                                defaultValue:@"" parameterFlags:(kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE)];
  ok = ok && [api addToggleButtonWithName:@"Explicit Keypose Creation" parameterID:MMExplicitCreation
                           defaultValue:NO parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_HIDDEN)];
  ok = ok && [api addToggleButtonWithName:@"Motion Blur" parameterID:MMMotionBlur
                           defaultValue:NO parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_HIDDEN)];
  ok = ok && [api addIntSliderWithName:@"Motion Blur Samples" parameterID:MMMotionBlurSamples
                         defaultValue:MMMotionBlurDefaultSamples
                          parameterMin:MMMotionBlurMinSamples parameterMax:MMMotionBlurMaxSamples
                              sliderMin:MMMotionBlurMinSamples sliderMax:MMMotionBlurMaxSamples
                                  delta:1 parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_HIDDEN)];
  ok = ok && [api addIntSliderWithName:@"Motion Blur Shutter Angle" parameterID:MMMotionBlurShutterAngle
                         defaultValue:MMMotionBlurDefaultShutterAngle
                          parameterMin:MMMotionBlurMinShutterAngle parameterMax:MMMotionBlurMaxShutterAngle
                              sliderMin:MMMotionBlurMinShutterAngle sliderMax:MMMotionBlurMaxShutterAngle
                                  delta:1 parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_HIDDEN)];
  NSArray *motions = @[@"None", @"Wave", @"Wiggle", @"Handheld"];
  NSArray *easings = @[@"Smooth", @"Linear", @"Ease In", @"Ease Out"];
  FxParameterFlags editorFlags = kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE | kFxParameterFlag_DISABLED;
  ok = ok && [api addPopupMenuWithName:@"Combined Easing" parameterID:MMCombinedEasing
                        defaultValue:0 menuEntries:easings parameterFlags:editorFlags];
  ok = ok && [api addPopupMenuWithName:@"Combined Added Motion" parameterID:MMCombinedAddedMotion
                        defaultValue:0 menuEntries:motions parameterFlags:editorFlags];
  for (MMTimingLane *lane in self.timingLanes) {
    BOOL isScale = lane.valueID == MMScale;
    ok = ok &&
        [api addFloatSliderWithName:(isScale ? @"Scale" : @"Position X") parameterID:lane.valueID
                      defaultValue:(isScale ? 100 : 0) parameterMin:(isScale ? 0 : -200)
                      parameterMax:(isScale ? 400 : 200)
                         sliderMin:(isScale ? 0 : -200) sliderMax:(isScale ? 400 : 200)
                             delta:0.01 parameterFlags:kFxParameterFlag_HIDDEN] &&
        [api addPopupMenuWithName:@"Added Motion" parameterID:lane.addedMotionID defaultValue:0
                     menuEntries:motions parameterFlags:editorFlags] &&
        [api addPopupMenuWithName:@"Easing" parameterID:lane.easingID defaultValue:0
                     menuEntries:easings parameterFlags:editorFlags] &&
        [api addToggleButtonWithName:@"Link this pose" parameterID:lane.linkEditorID
                       defaultValue:NO
                     parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE | kFxParameterFlag_HIDDEN |
                                     kFxParameterFlag_DISABLED)] &&
        [api addToggleButtonWithName:@"Match In/Out" parameterID:lane.matchEditorID defaultValue:NO
                     parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE | kFxParameterFlag_HIDDEN | kFxParameterFlag_DISABLED)] &&
        [api addToggleButtonWithName:@"Legacy Match Out" parameterID:(isScale ? MMScaleLegacyMatchOut : MMPositionLegacyMatchOut) defaultValue:NO
                     parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE | kFxParameterFlag_HIDDEN)] &&
        [api addToggleButtonWithName:@"Use available time" parameterID:lane.availableTimeID
                       defaultValue:NO
                     parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE | kFxParameterFlag_HIDDEN |
                                     kFxParameterFlag_DISABLED)] &&
        [api addFloatSliderWithName:@"Duration" parameterID:lane.durationID
                      defaultValue:1.2 parameterMin:0 parameterMax:60
                         sliderMin:0 sliderMax:60 delta:0.01
                    parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE | kFxParameterFlag_HIDDEN |
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
