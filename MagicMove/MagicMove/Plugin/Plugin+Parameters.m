/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KeyframelessKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMovePlugin (Parameters)

- (BOOL)addPointSectionWithName:(NSString *)name
                          group:(MagicMoveGroupIDs)group
                       defaultX:(double)defaultX
                       defaultY:(double)defaultY
                  defaultHidden:(BOOL)defaultHidden
                    customGroup:(BOOL)customGroup
                        withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                          error:(NSError **)error {
  FxParameterFlags flags =
      defaultHidden ? kFxParameterFlag_HIDDEN : kFxParameterFlag_DEFAULT;

  if (customGroup) {
    if (![paramAPI
            addCustomParameterWithName:@""
                           parameterID:group.group
                          defaultValue:@(group.group)
                        parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                       kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_USE_FULL_VIEW_WIDTH])
      return NO;
  } else {
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"circle.circle"
                              accessibilityDescription:nil];
    if (![self addSeparatorParameterWithText:name
                                        icon:icon
                                 parameterID:group.group
                                     withAPI:paramAPI
                                       error:error])
      return NO;
  }

  if (group.enable != 0) {
    if (![paramAPI addToggleButtonWithName:@"Enable"
                               parameterID:group.enable
                              defaultValue:NO
                            parameterFlags:flags])
      return NO;
  }

  if (group.preview != 0) {
    if (![paramAPI addToggleButtonWithName:@"Preview"
                               parameterID:group.preview
                              defaultValue:NO
                            parameterFlags:flags])
      return NO;
  }

  if (group.hideOSC != 0) {
    if (![paramAPI addToggleButtonWithName:@"Hide Controls"
                               parameterID:group.hideOSC
                              defaultValue:NO
                            parameterFlags:flags])
      return NO;
  }

  if (![paramAPI addPointParameterWithName:@"Position"
                               parameterID:group.params.point
                                  defaultX:defaultX
                                  defaultY:defaultY
                            parameterFlags:flags])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation"
                            parameterID:group.params.rotation
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:flags])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation X"
                            parameterID:group.params.rotationX
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:flags])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation Y"
                            parameterID:group.params.rotationY
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:flags])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Scale X"
                              parameterID:group.params.scaleX
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:10.0
                                sliderMin:0.0
                                sliderMax:5.0
                                    delta:0.01
                           parameterFlags:flags])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Scale Y"
                              parameterID:group.params.scaleY
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:10.0
                                sliderMin:0.0
                                sliderMax:5.0
                                    delta:0.01
                           parameterFlags:flags])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Opacity"
                              parameterID:group.params.opacity
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:1.0
                                sliderMin:0.0
                                sliderMax:1.0
                                    delta:0.01
                           parameterFlags:flags])
    return NO;

  return YES;
}

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

  if (![self addUpdateBannerParameterWithAPI:paramAPI error:error])
    return NO;

  if (![paramAPI
          addToggleButtonWithName:@"Force Show All Parameters"
                      parameterID:kParamForceShowAlerts
                     defaultValue:NO
                   parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                  kFxParameterFlag_DONT_DISPLAY_IN_DASHBOARD])
    return NO;

  NSMutableAttributedString *compoundText = [[NSMutableAttributedString alloc]
      initWithString:@"Create a Compound Clip "];
  [compoundText appendAttributedString:[KKKbd attributedStringWithKey:@"⌥ G"]];
  [compoundText
      appendAttributedString:[[NSAttributedString alloc]
                                 initWithString:@" before applying "
                                                @"to avoid clipping"]];
  if (![self
          addInfoParameterWithAttributedText:compoundText
                                        icon:[NSImage
                                                 imageWithSystemSymbolName:
                                                     @"info.circle"
                                                  accessibilityDescription:nil]
                                 parameterID:kParamInfoCompound
                                     withAPI:paramAPI
                                       error:error])
    return NO;

  if (![paramAPI
          addCustomParameterWithName:@""
                         parameterID:kParamPreviewWarning
                        defaultValue:@(kParamPreviewWarning)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH |
                                     kFxParameterFlag_DISABLED])
    return NO;

  if (![paramAPI
          addCustomParameterWithName:@""
                         parameterID:kParamHideOSCWarning
                        defaultValue:@(kParamHideOSCWarning)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH |
                                     kFxParameterFlag_DISABLED])
    return NO;

  if (![paramAPI addStringParameterWithName:@"Alert Selection"
                                parameterID:kParamAlertStackSelected
                               defaultValue:@""
                             parameterFlags:kFxParameterFlag_HIDDEN |
                                            kFxParameterFlag_NOT_ANIMATABLE])
    return NO;

  if (![self addAnimationParametersWithAPI:paramAPI error:error])
    return NO;

  if (![paramAPI addToggleButtonWithName:@"Rotate with Motion"
                             parameterID:kParamRotateWithMotion
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  self.timingGroupExtraParamIDs = @[ @(kParamRotateWithMotion) ];

  if (![self addPointSectionWithName:@"Point A"
                               group:kGroupA
                            defaultX:0.5
                            defaultY:0.5
                       defaultHidden:YES
                         customGroup:YES
                             withAPI:paramAPI
                               error:error])
    return NO;

  if (![self addPointSectionWithName:@"Point B"
                               group:kGroupB
                            defaultX:0.5
                            defaultY:0.5
                       defaultHidden:YES
                         customGroup:YES
                             withAPI:paramAPI
                               error:error])
    return NO;

  if (![self addPointSectionWithName:@"Drift"
                               group:kGroupDrift
                            defaultX:0.5
                            defaultY:0.5
                       defaultHidden:YES
                         customGroup:YES
                             withAPI:paramAPI
                               error:error])
    return NO;

  if (![self addPointSectionWithName:@"Exit"
                               group:kGroupExit
                            defaultX:0.5
                            defaultY:0.5
                       defaultHidden:YES
                         customGroup:YES
                             withAPI:paramAPI
                               error:error])
    return NO;

  UInt32 pathIDs[] = {kParamPathAB, kParamPathBDrift, kParamPathDriftExit,
                      kParamPathBExit, kParamPathDriftA};
  NSString *pathNames[] = {@"PathAB", @"PathBDrift", @"PathDriftExit",
                           @"PathBExit", @"PathDriftA"};
  for (int i = 0; i < 5; i++) {
    if (![paramAPI addStringParameterWithName:pathNames[i]
                                  parameterID:pathIDs[i]
                                 defaultValue:@""
                               parameterFlags:kFxParameterFlag_HIDDEN])
      return NO;
  }

  return YES;
}

@end
#pragma clang diagnostic pop
