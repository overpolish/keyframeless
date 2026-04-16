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

  [paramAPI addToggleButtonWithName:@"Force Show All Parameters"
                        parameterID:kParamForceShow
                       defaultValue:NO
                     parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                    kFxParameterFlag_DONT_DISPLAY_IN_DASHBOARD];

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

  [paramAPI addFloatSliderWithName:@"Opacity"
                       parameterID:kParamOpacity
                      defaultValue:100.0
                      parameterMin:0.0
                      parameterMax:100.0
                         sliderMin:0.0
                         sliderMax:100.0
                             delta:1.0
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addToggleButtonWithName:@"Closed Path"
                        parameterID:kParamClosedPath
                       defaultValue:YES
                     parameterFlags:kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addCustomParameterWithName:@""
                           parameterID:kParamGroupStroke
                          defaultValue:@(kParamGroupStroke)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_NOT_ANIMATABLE |
                                       kFxParameterFlag_USE_FULL_VIEW_WIDTH];

  [paramAPI addToggleButtonWithName:@""
                        parameterID:kParamExpandedStroke
                       defaultValue:NO
                     parameterFlags:kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addToggleButtonWithName:@"Stroke"
                        parameterID:kParamStrokeEnabled
                       defaultValue:YES
                     parameterFlags:kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addFloatSliderWithName:@"Start Width"
                       parameterID:kParamStrokeWidth
                      defaultValue:8.0
                      parameterMin:0.5
                      parameterMax:10000.0
                         sliderMin:0.5
                         sliderMax:100.0
                             delta:0.5
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addFloatSliderWithName:@"End Width"
                       parameterID:kParamEndWidth
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

  [paramAPI addCustomParameterWithName:@"Start Marker"
                           parameterID:kParamStartMarker
                          defaultValue:@(0)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addCustomParameterWithName:@"End Marker"
                           parameterID:kParamEndMarker
                          defaultValue:@(0)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addPercentSliderWithName:@"Start Size"
                         parameterID:kParamStartMarkerSize
                        defaultValue:3.0
                        parameterMin:0.5
                        parameterMax:5.0
                           sliderMin:0.5
                           sliderMax:5.0
                               delta:0.1
                      parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addPercentSliderWithName:@"End Size"
                         parameterID:kParamEndMarkerSize
                        defaultValue:3.0
                        parameterMin:0.5
                        parameterMax:5.0
                           sliderMin:0.5
                           sliderMax:5.0
                               delta:0.1
                      parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addCustomParameterWithName:@""
                           parameterID:kParamGroupFill
                          defaultValue:@(kParamGroupFill)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_NOT_ANIMATABLE |
                                       kFxParameterFlag_USE_FULL_VIEW_WIDTH];

  [paramAPI addToggleButtonWithName:@""
                        parameterID:kParamExpandedFill
                       defaultValue:NO
                     parameterFlags:kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE];

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

  [paramAPI addCustomParameterWithName:@"Fill Style"
                           parameterID:kParamSketchFillStyle
                          defaultValue:@(0)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addFloatSliderWithName:@"Fill Gap"
                       parameterID:kParamSketchFillGap
                      defaultValue:kSketchFillGapDefault
                      parameterMin:1.0
                      parameterMax:100.0
                         sliderMin:1.0
                         sliderMax:100.0
                             delta:1.0
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addAngleSliderWithName:@"Fill Angle"
                       parameterID:kParamSketchFillAngle
                    defaultDegrees:kSketchFillAngleDefault
               parameterMinDegrees:-360.0
               parameterMaxDegrees:360.0
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addFloatSliderWithName:@"Fill Weight"
                       parameterID:kParamSketchFillWeight
                      defaultValue:kSketchFillWeightDefault
                      parameterMin:0.5
                      parameterMax:20.0
                         sliderMin:0.5
                         sliderMax:20.0
                             delta:0.5
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addCustomParameterWithName:@""
                           parameterID:kParamGroupSketch
                          defaultValue:@(kParamGroupSketch)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_NOT_ANIMATABLE |
                                       kFxParameterFlag_USE_FULL_VIEW_WIDTH];

  [paramAPI addToggleButtonWithName:@""
                        parameterID:kParamExpandedSketch
                       defaultValue:NO
                     parameterFlags:kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addToggleButtonWithName:@"Sketch"
                        parameterID:kParamSketchEnabled
                       defaultValue:NO
                     parameterFlags:kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addFloatSliderWithName:@"Roughness"
                       parameterID:kParamSketchRoughness
                      defaultValue:kSketchRoughnessDefault
                      parameterMin:0.0
                      parameterMax:3.0
                         sliderMin:0.0
                         sliderMax:3.0
                             delta:0.1
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addFloatSliderWithName:@"Bowing"
                       parameterID:kParamSketchBowing
                      defaultValue:kSketchBowingDefault
                      parameterMin:0.0
                      parameterMax:3.0
                         sliderMin:0.0
                         sliderMax:3.0
                             delta:0.1
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addIntSliderWithName:@"Strokes"
                     parameterID:kParamSketchStrokes
                    defaultValue:kSketchStrokesDefault
                    parameterMin:1
                    parameterMax:2
                       sliderMin:1
                       sliderMax:2
                           delta:1
                  parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addCustomParameterWithName:@"Seed"
                           parameterID:kParamSketchSeed
                          defaultValue:@(0)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

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

  self.linkedParameterPairs = @[
    @[ @(kParamStrokeWidth), @(kParamEndWidth) ],
  ];

  return YES;
}

@end
#pragma clang diagnostic pop
