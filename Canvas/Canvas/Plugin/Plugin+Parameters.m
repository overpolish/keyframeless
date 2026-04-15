/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation CanvasPlugin (Parameters)

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

  [paramAPI addCustomParameterWithName:@""
                           parameterID:kParamLayerList
                          defaultValue:@(kParamLayerList)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_NOT_ANIMATABLE |
                                       kFxParameterFlag_USE_FULL_VIEW_WIDTH];

  [paramAPI addStringParameterWithName:@"PathData"
                           parameterID:kParamPathData
                          defaultValue:@""
                        parameterFlags:kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addToggleButtonWithName:@"Stroke"
                        parameterID:kParamStrokeEnabled
                       defaultValue:YES
                     parameterFlags:kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addFloatSliderWithName:@"Stroke Width"
                       parameterID:kParamStrokeWidth
                      defaultValue:8.0
                      parameterMin:0.5
                      parameterMax:10000.0
                         sliderMin:0.5
                         sliderMax:100.0
                             delta:0.5
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addColorParameterWithName:@"Stroke Color"
                          parameterID:kParamStrokeColor
                           defaultRed:1.0
                         defaultGreen:0.0
                          defaultBlue:0.0
                       parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addToggleButtonWithName:@"Fill"
                        parameterID:kParamFillEnabled
                       defaultValue:NO
                     parameterFlags:kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addColorParameterWithName:@"Fill Color"
                          parameterID:kParamFillColor
                           defaultRed:1.0
                         defaultGreen:1.0
                          defaultBlue:1.0
                       parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addFloatSliderWithName:@"Opacity"
                       parameterID:kParamOpacity
                      defaultValue:100.0
                      parameterMin:0.0
                      parameterMax:100.0
                         sliderMin:0.0
                         sliderMax:100.0
                             delta:1.0
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addCustomParameterWithName:@"Line Cap"
                           parameterID:kParamLineCap
                          defaultValue:@(0)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addCustomParameterWithName:@"Line Join"
                           parameterID:kParamLineJoin
                          defaultValue:@(0)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addCustomParameterWithName:@"Stroke Style"
                           parameterID:kParamStrokeStyle
                          defaultValue:@(0)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addFloatSliderWithName:@"Dash Length"
                       parameterID:kParamDashLength
                      defaultValue:20.0
                      parameterMin:1.0
                      parameterMax:200.0
                         sliderMin:1.0
                         sliderMax:200.0
                             delta:1.0
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addFloatSliderWithName:@"Dash Gap"
                       parameterID:kParamDashGap
                      defaultValue:10.0
                      parameterMin:1.0
                      parameterMax:200.0
                         sliderMin:1.0
                         sliderMax:200.0
                             delta:1.0
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addFloatSliderWithName:@"Dot Gap"
                       parameterID:kParamDotGap
                      defaultValue:10.0
                      parameterMin:1.0
                      parameterMax:200.0
                         sliderMin:1.0
                         sliderMax:200.0
                             delta:1.0
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addFloatSliderWithName:@"LastSelectedIndex"
                       parameterID:kParamLastSelectedIndex
                      defaultValue:-1.0
                      parameterMin:-1.0
                      parameterMax:10000.0
                         sliderMin:-1.0
                         sliderMax:10000.0
                             delta:1.0
                    parameterFlags:kFxParameterFlag_HIDDEN |
                                   kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addStringParameterWithName:@"InstanceID"
                           parameterID:kParamInstanceID
                          defaultValue:@""
                        parameterFlags:kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

  return YES;
}

@end
#pragma clang diagnostic pop
