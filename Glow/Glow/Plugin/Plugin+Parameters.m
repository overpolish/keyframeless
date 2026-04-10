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

  if (![self addUpdateBannerParameterWithAPI:paramAPI error:error]) {
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

  if (![self addAnimationParametersWithAPI:paramAPI error:error])
    return NO;

  UInt32 animParams[] = {
      kParamInRadius,      kParamInIntensity,     kParamInFalloff,
      kParamInNoise,       kParamInOffset,        kParamInColor,
      kParamInNoiseOffset, kParamHoldRadius,      kParamHoldIntensity,
      kParamHoldFalloff,   kParamHoldNoise,       kParamHoldOffset,
      kParamHoldColor,     kParamHoldNoiseOffset, kParamOutRadius,
      kParamOutIntensity,  kParamOutFalloff,      kParamOutNoise,
      kParamOutOffset,     kParamOutColor,        kParamOutNoiseOffset,
  };
  NSString *animNames[] = {
      @"In Radius",       @"In Intensity",      @"In Falloff",
      @"In Noise",        @"In Offset",         @"In Color",
      @"In Noise Offset", @"Hold Radius",       @"Hold Intensity",
      @"Hold Falloff",    @"Hold Noise",        @"Hold Offset",
      @"Hold Color",      @"Hold Noise Offset", @"Out Radius",
      @"Out Intensity",   @"Out Falloff",       @"Out Noise",
      @"Out Offset",      @"Out Color",         @"Out Noise Offset",
  };
  for (int i = 0; i < 21; i++) {
    if (![paramAPI addToggleButtonWithName:animNames[i]
                               parameterID:animParams[i]
                              defaultValue:YES
                            parameterFlags:kFxParameterFlag_HIDDEN])
      return NO;
  }

  if (![paramAPI addColorParameterWithName:@"In Color"
                               parameterID:kParamTimingInColor
                                defaultRed:1.0
                              defaultGreen:1.0
                               defaultBlue:1.0
                            parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addColorParameterWithName:@"Hold Color"
                               parameterID:kParamTimingHoldColor
                                defaultRed:1.0
                              defaultGreen:1.0
                               defaultBlue:1.0
                            parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addColorParameterWithName:@"Out Color"
                               parameterID:kParamTimingOutColor
                                defaultRed:1.0
                              defaultGreen:1.0
                               defaultBlue:1.0
                            parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addGradientWithName:@"In Gradient"
                         parameterID:kParamTimingInGradient
                      parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addGradientWithName:@"Hold Gradient"
                         parameterID:kParamTimingHoldGradient
                      parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addGradientWithName:@"Out Gradient"
                         parameterID:kParamTimingOutGradient
                      parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  self.linkedParameterPairs = @[ @[ @(kParamRadiusX), @(kParamRadiusY) ] ];

  return YES;
}

@end
#pragma clang diagnostic pop
