/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKMarkup.h>

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

  if (![self addLogoBannerParameterWithAPI:paramAPI error:error]) {
    return NO;
  }

  NSAttributedString *infoText = [KKMarkup
      attributedStringFromMarkup:
          @"Use on an Adjustment Clip <kbd>⌥ A</kbd> or a Compound Clip "
          @"<kbd>⌥ G</kbd>"];
  if (![self
          addInfoParameterWithAttributedText:infoText
                                        icon:[NSImage
                                                 imageWithSystemSymbolName:
                                                     @"info.circle"
                                                  accessibilityDescription:nil]
                                 parameterID:kParamInfoUsage
                                     withAPI:paramAPI
                                       error:error]) {
    return NO;
  }

  if (![paramAPI
          addToggleButtonWithName:@"Force Show All Parameters"
                      parameterID:kParamForceShow
                     defaultValue:NO
                   parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                  kFxParameterFlag_DONT_DISPLAY_IN_DASHBOARD])
    return NO;

  if (![paramAPI addPopupMenuWithName:@"Preset"
                          parameterID:kParamPreset
                         defaultValue:GlowPresetSoftGlow
                          menuEntries:@[ @"Soft Glow", @"Shadow", @"Fire" ]
                       parameterFlags:kFxParameterFlag_NOT_ANIMATABLE])
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

  if (![paramAPI addPointParameterWithName:@"Position"
                               parameterID:kParamPosition
                                  defaultX:0.5
                                  defaultY:0.5
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

  if (![paramAPI addPercentSliderWithName:@"Threshold"
                              parameterID:kParamThreshold
                             defaultValue:0.0
                             parameterMin:0.0
                             parameterMax:1.0
                                sliderMin:0.0
                                sliderMax:1.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![self addColorParametersWithAPI:paramAPI
                                 modes:@[
                                   @(KKColorModeDynamic), @(KKColorModeSolid),
                                   @(KKColorModeGradient)
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

  // --- Noise group ---
  if (![paramAPI
          addCustomParameterWithName:@""
                         parameterID:kParamNoiseGroup
                        defaultValue:@(kParamNoiseGroup)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH])
    return NO;

  if (![paramAPI addToggleButtonWithName:@""
                             parameterID:kParamNoiseExpanded
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_HIDDEN |
                                         kFxParameterFlag_NOT_ANIMATABLE])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Amount"
                              parameterID:kParamNoise
                             defaultValue:0.0
                             parameterMin:0.0
                             parameterMax:5.0
                                sliderMin:0.0
                                sliderMax:5.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Offset"
                              parameterID:kParamNoiseOffset
                             defaultValue:0.0
                             parameterMin:0.0
                             parameterMax:1.0
                                sliderMin:0.0
                                sliderMax:1.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Speed"
                              parameterID:kParamNoiseSpeed
                             defaultValue:0.0
                             parameterMin:0.0
                             parameterMax:5.0
                                sliderMin:0.0
                                sliderMax:2.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![self addMultiStageParametersWithAPI:paramAPI error:error])
    return NO;

  self.linkedParameterPairs = @[ @[ @(kParamRadiusX), @(kParamRadiusY) ] ];

  return YES;
}

@end
#pragma clang diagnostic pop
