/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMDefaults.h"
#import "Constants.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMovePlugin (Parameters)
- (BOOL)addParametersWithError:(NSError **)error {
  id<FxParameterCreationAPI_v5> api =
      [self.apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
  BOOL ok = api && KFAddHostRefreshToken(api, @"Host Refresh", MMHostRefreshToken);
  ok = ok && KFAddCustomUIPanel(api, MMHeaderControls);
  for (KFPropertyLane *lane in KFPropertyLanes()) {
    ok = ok && KFAddCustomUIParameter(api, lane.parameterID,
                                      KFPoseWithCreationDefaults(lane.defaultPose));
    ok = ok && KFAddCacheToken(api, [lane.displayName stringByAppendingString:@" view cache"],
                               lane.cacheTokenID);
    // Match In/Out is lane-wide, so each property keeps one saved toggle rather
    // than repeating the setting in every keyframed pose.
    ok = ok && KFAddHiddenToggle(api, [lane.displayName stringByAppendingString:@" Match In/Out"],
                                 lane.matchToggleID, NO);
    if (lane.proportionalToggleID)
      ok = ok && KFAddHiddenToggle(api, [lane.displayName stringByAppendingString:@" Proportional"],
                                   lane.proportionalToggleID, YES);
    // Saved per effect so one clip can hide its handles, but the registered
    // default is the last toggled value, which is how a new effect inherits it.
    if (lane.visibilityToggleID)
      ok = ok && KFAddHiddenToggle(api,
                                   [NSString stringWithFormat:@"Show %@ On-Screen Control", lane.displayName],
                                   lane.visibilityToggleID,
                                   MMReadOSCVisibilityDefault(lane.visibilityToggleID));
  }
  ok = ok && KFAddCustomUIPanel(api, MMTimingControls);
  ok = ok && KFAddHiddenToggle(api, @"Explicit Keypose Creation", MMExplicitCreation, NO);
  ok = ok && KFAddHiddenToggle(api, @"Motion Blur", MMMotionBlur, NO);
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
  if (!ok && error) {
    *error = [NSError errorWithDomain:FxPlugErrorDomain code:kFxError_APIUnavailable
                            userInfo:@{NSLocalizedDescriptionKey: @"Unable to create Magic Move controls"}];
  }
  return ok;
}
@end
#pragma clang diagnostic pop
