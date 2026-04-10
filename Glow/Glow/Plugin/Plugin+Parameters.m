/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation GlowPlugin (Parameters)

- (BOOL)addParametersWithError:(NSError **)error {
  id<FxParameterCreationAPI_v5> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
  if (paramAPI == nil) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:FxPlugErrorDomain
                                   code:kFxError_APIUnavailable
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to obtain an FxPlug API Object"
                               }];
    }
    return NO;
  }

  if (![self addUpdateBannerParameterWithAPI:paramAPI error:error]) {
    return NO;
  }

  if (![paramAPI
          addToggleButtonWithName:@"Force Show All Parameters"
                      parameterID:kParamForceShow
                     defaultValue:NO
                   parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                  kFxParameterFlag_DONT_DISPLAY_IN_DASHBOARD])
    return NO;

  if (![paramAPI addFloatSliderWithName:@"Radius X"
                            parameterID:kParamRadiusX
                           defaultValue:100.0
                           parameterMin:0.0
                           parameterMax:500.0
                              sliderMin:0.0
                              sliderMax:300.0
                                  delta:1.0
                         parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addFloatSliderWithName:@"Radius Y"
                            parameterID:kParamRadiusY
                           defaultValue:100.0
                           parameterMin:0.0
                           parameterMax:500.0
                              sliderMin:0.0
                              sliderMax:300.0
                                  delta:1.0
                         parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Intensity"
                              parameterID:kParamIntensity
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:5.0
                                sliderMin:0.0
                                sliderMax:3.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Falloff"
                              parameterID:kParamFalloff
                             defaultValue:0.0
                             parameterMin:0.0
                             parameterMax:4.0
                                sliderMin:0.0
                                sliderMax:2.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Noise"
                              parameterID:kParamNoise
                             defaultValue:0.0
                             parameterMin:0.0
                             parameterMax:5.0
                                sliderMin:0.0
                                sliderMax:5.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Noise Offset"
                              parameterID:kParamNoiseOffset
                             defaultValue:0.0
                             parameterMin:0.0
                             parameterMax:1.0
                                sliderMin:0.0
                                sliderMax:1.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  // --- Offset group ---
  if (![paramAPI
          addCustomParameterWithName:@""
                         parameterID:kParamOffsetGroup
                        defaultValue:@(kParamOffsetGroup)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH])
    return NO;

  if (![paramAPI addToggleButtonWithName:@""
                             parameterID:kParamOffsetExpanded
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_HIDDEN |
                                         kFxParameterFlag_NOT_ANIMATABLE])
    return NO;

  if (![paramAPI addFloatSliderWithName:@"Offset X"
                            parameterID:kParamOffsetX
                           defaultValue:0.0
                           parameterMin:-5.0
                           parameterMax:5.0
                              sliderMin:-1.0
                              sliderMax:1.0
                                  delta:0.01
                         parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addFloatSliderWithName:@"Offset Y"
                            parameterID:kParamOffsetY
                           defaultValue:0.0
                           parameterMin:-5.0
                           parameterMax:5.0
                              sliderMin:-1.0
                              sliderMax:1.0
                                  delta:0.01
                         parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![self addColorParametersWithAPI:paramAPI
                                 modes:@[
                                   @(KKColorModeSolid), @(KKColorModeGradient),
                                   @(KKColorModeDynamic)
                                 ]
                                 error:error])
    return NO;

  if (![paramAPI addPopupMenuWithName:@"Gradient Type"
                          parameterID:kParamGradientType
                         defaultValue:0
                          menuEntries:@[ @"Radial", @"Linear" ]
                       parameterFlags:kFxParameterFlag_HIDDEN |
                                      kFxParameterFlag_NOT_ANIMATABLE])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Angle"
                            parameterID:kParamGradientAngle
                         defaultDegrees:0.0
                    parameterMinDegrees:-360.0
                    parameterMaxDegrees:360.0
                         parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![self addAnimationParametersWithAPI:paramAPI error:error])
    return NO;

  UInt32 holdParams[] = {kParamHoldRadius, kParamHoldIntensity,
                         kParamHoldFalloff, kParamHoldNoise, kParamHoldOffset};
  NSString *holdNames[] = {@"Hold Radius", @"Hold Intensity", @"Hold Falloff",
                           @"Hold Noise", @"Hold Offset"};
  for (int i = 0; i < 5; i++) {
    if (![paramAPI addToggleButtonWithName:holdNames[i]
                               parameterID:holdParams[i]
                              defaultValue:YES
                            parameterFlags:kFxParameterFlag_HIDDEN])
      return NO;
  }

  return YES;
}

@end
#pragma clang diagnostic pop
