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

  if (![paramAPI addFloatSliderWithName:@"Radius"
                            parameterID:kParamRadius
                           defaultValue:20.0
                           parameterMin:0.0
                           parameterMax:FLT_MAX
                              sliderMin:0.0
                              sliderMax:100.0
                                  delta:1.0
                         parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Intensity"
                              parameterID:kParamIntensity
                             defaultValue:1.5
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

  if (![paramAPI addPopupMenuWithName:@"Color Mode"
                          parameterID:kParamColorMode
                         defaultValue:kColorModeSolid
                          menuEntries:@[ @"Solid", @"Dynamic" ]
                       parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addColorParameterWithName:@"Color"
                               parameterID:kParamColor
                                defaultRed:1.0
                              defaultGreen:1.0
                               defaultBlue:1.0
                            parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![self addAnimationParametersWithAPI:paramAPI error:error])
    return NO;

  UInt32 holdParams[] = {kParamHoldRadius, kParamHoldIntensity,
                         kParamHoldFalloff};
  NSString *holdNames[] = {@"Hold Radius", @"Hold Intensity", @"Hold Falloff"};
  for (int i = 0; i < 3; i++) {
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
