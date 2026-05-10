/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"

static void registerGradientSubParams(id<FxParameterCreationAPI_v5> paramAPI,
                                      NSString *typeName, UInt32 typeID,
                                      NSString *angleName, UInt32 angleID,
                                      NSString *dataName, UInt32 dataID,
                                      UInt32 dataMirrorID, UInt32 uiID) {
  // Inspector display order: picker (gradient stops bar) → type → angle,
  // matching Glow.
  [paramAPI addCustomParameterWithName:@"Gradient"
                           parameterID:uiID
                          defaultValue:@(uiID)
                        parameterFlags:kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_CUSTOM_UI];
  [paramAPI addPopupMenuWithName:typeName
                     parameterID:typeID
                    defaultValue:1
                     menuEntries:@[ @"Radial", @"Linear" ]
                  parameterFlags:kFxParameterFlag_HIDDEN |
                                 kFxParameterFlag_NOT_ANIMATABLE];
  [paramAPI addAngleSliderWithName:angleName
                       parameterID:angleID
                    defaultDegrees:0.0
               parameterMinDegrees:-360.0
               parameterMaxDegrees:360.0
                    parameterFlags:kFxParameterFlag_HIDDEN];
  // KKDataBlob so writes route through the undoable
  // setCustomParameterValue:atTime: path. NOT_ANIMATABLE deliberately
  // omitted — it would re-exclude the param from undo.
  [paramAPI addCustomParameterWithName:dataName
                           parameterID:dataID
                          defaultValue:[KKDataBlob blobWithData:nil]
                        parameterFlags:kFxParameterFlag_HIDDEN];
  // Native-string mirror — readable from OSC/render scope where the
  // KKDataBlob would return nil. Written in lockstep with the blob via
  // KKWriteGradientParamsFromPath.
  [paramAPI addStringParameterWithName:@""
                           parameterID:dataMirrorID
                          defaultValue:@""
                        parameterFlags:kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];
}

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

  if (![self addLogoBannerParameterWithAPI:paramAPI error:error]) {
    return NO;
  }

  [paramAPI addToggleButtonWithName:@"Force Show All Parameters"
                        parameterID:kParamForceShow
                       defaultValue:NO
                     parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                    kFxParameterFlag_DONT_DISPLAY_IN_DASHBOARD];

  [paramAPI addToggleButtonWithName:@"Hide OSC"
                        parameterID:kParamHideOSC
                       defaultValue:NO
                     parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                    kFxParameterFlag_DONT_DISPLAY_IN_DASHBOARD];

  [paramAPI addToggleButtonWithName:@"Auto Select"
                        parameterID:kParamAutoSelect
                       defaultValue:YES
                     parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                    kFxParameterFlag_DONT_DISPLAY_IN_DASHBOARD];

  [paramAPI addToggleButtonWithName:@"Grid Enabled"
                        parameterID:kParamGridEnabled
                       defaultValue:NO
                     parameterFlags:kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addIntSliderWithName:@"Grid Spacing"
                     parameterID:kParamGridSpacing
                    defaultValue:10
                    parameterMin:1
                    parameterMax:1000
                       sliderMin:1
                       sliderMax:1000
                           delta:1
                  parameterFlags:kFxParameterFlag_HIDDEN |
                                 kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addToggleButtonWithName:@"Grid Adaptive"
                        parameterID:kParamGridAdaptive
                       defaultValue:YES
                     parameterFlags:kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addToggleButtonWithName:@"Snap to Grid"
                        parameterID:kParamSnapToGrid
                       defaultValue:NO
                     parameterFlags:kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE];

  // NOT_ANIMATABLE deliberately omitted — that flag excludes a param from
  // FCP's undo stack, so tool-bar clicks (`setIntValue:atTime:`) wouldn't
  // be reversible. Same caveat that applies to KKDataBlob params.
  [paramAPI addIntSliderWithName:@"Last Tool"
                     parameterID:kParamLastTool
                    defaultValue:kOSCToolbarCursor
                    parameterMin:0
                    parameterMax:100
                       sliderMin:0
                       sliderMax:100
                           delta:1
                  parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addCustomParameterWithName:@""
                           parameterID:kParamLayerList
                          defaultValue:@(kParamLayerList)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_NOT_ANIMATABLE |
                                       kFxParameterFlag_USE_FULL_VIEW_WIDTH];

  // KKDataBlob wraps the base64 path blob so writes route through
  // `setCustomParameterValue:atTime:` (undoable) instead of
  // `setStringParameterValue:` (filtered off FCP's undo stack).
  // NOT_ANIMATABLE deliberately omitted — it re-excludes blob writes
  // from undo. See project_kkdatablob_custom_param.md.
  [paramAPI addCustomParameterWithName:@"PathData"
                           parameterID:kParamPathData
                          defaultValue:[KKDataBlob blobWithData:nil]
                        parameterFlags:kFxParameterFlag_HIDDEN];

  // Native-string mirror — readable from OSC and render scopes where
  // KKDataBlob reads return nil. Written in lockstep with the blob via
  // KKCanvasWritePathData. See kParamPathDataMirror declaration.
  [paramAPI addStringParameterWithName:@""
                           parameterID:kParamPathDataMirror
                          defaultValue:@""
                        parameterFlags:kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

  // Timing (multi-stage sequencer) and Motion Blur sit above the stroke
  // group so the visible portion of the inspector doesn't get pushed down
  // as Stroke / Fill / Sketch expand. Opacity / Closed Path follow Motion
  // Blur so that when group selection hides them, the two custom-UI
  // panels above don't jump around.
  if (![self addMultiStageParametersWithAPI:paramAPI error:error])
    return NO;
  if (![self addMotionBlurParametersWithAPI:paramAPI error:error])
    return NO;

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
                           parameterID:kParamGroupTransform
                          defaultValue:@(kParamGroupTransform)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_NOT_ANIMATABLE |
                                       kFxParameterFlag_USE_FULL_VIEW_WIDTH];

  // KKDataBlob-backed expand state (matches Glow/Rounded/MagicMove). The
  // legacy `addToggleButton` + `setBoolValue:atTime:` path doesn't survive
  // FCP's undo stack reliably for hidden header toggles; routing through
  // setCustomParameterValue:atTime: gives the same undo coverage as other
  // blob params. See project_kkdatablob_custom_param.md.
  [paramAPI addCustomParameterWithName:@""
                           parameterID:kParamExpandedTransform
                          defaultValue:[KKDataBlob blobWithString:@"0"]
                        parameterFlags:kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addToggleButtonWithName:@"Transform"
                        parameterID:kParamTransformEnabled
                       defaultValue:YES
                     parameterFlags:kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addPointParameterWithName:@"Position"
                          parameterID:kParamPosition
                             defaultX:0.5
                             defaultY:0.5
                       parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addToggleButtonWithName:@"Rotate with Motion"
                        parameterID:kParamRotateWithMotion
                       defaultValue:NO
                     parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addPercentSliderWithName:@"Scale X"
                         parameterID:kParamScaleX
                        defaultValue:1.0
                        parameterMin:0.0
                        parameterMax:10.0
                           sliderMin:0.0
                           sliderMax:5.0
                               delta:0.01
                      parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addPercentSliderWithName:@"Scale Y"
                         parameterID:kParamScaleY
                        defaultValue:1.0
                        parameterMin:0.0
                        parameterMax:10.0
                           sliderMin:0.0
                           sliderMax:5.0
                               delta:0.01
                      parameterFlags:kFxParameterFlag_HIDDEN];

  // Anchor is an offset from bbox center (matches Position's neutral-at-0
  // semantics for the path: "no offset" = at the layer's center).
  [paramAPI addPointParameterWithName:@"Anchor"
                          parameterID:kParamAnchor
                             defaultX:0.0
                             defaultY:0.0
                       parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addAngleSliderWithName:@"Rotation Z"
                       parameterID:kParamRotation
                    defaultDegrees:0.0
               parameterMinDegrees:-FLT_MAX
               parameterMaxDegrees:FLT_MAX
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addAngleSliderWithName:@"Rotation X"
                       parameterID:kParamRotationX
                    defaultDegrees:0.0
               parameterMinDegrees:-FLT_MAX
               parameterMaxDegrees:FLT_MAX
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addAngleSliderWithName:@"Rotation Y"
                       parameterID:kParamRotationY
                    defaultDegrees:0.0
               parameterMinDegrees:-FLT_MAX
               parameterMaxDegrees:FLT_MAX
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addCustomParameterWithName:@""
                           parameterID:kParamGroupStroke
                          defaultValue:@(kParamGroupStroke)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_NOT_ANIMATABLE |
                                       kFxParameterFlag_USE_FULL_VIEW_WIDTH];

  [paramAPI addCustomParameterWithName:@""
                           parameterID:kParamExpandedStroke
                          defaultValue:[KKDataBlob blobWithString:@"0"]
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

  [paramAPI addPopupMenuWithName:@"Color Mode"
                     parameterID:kParamStrokeColorMode
                    defaultValue:0
                     menuEntries:@[ @"Solid", @"Gradient" ]
                  parameterFlags:kFxParameterFlag_HIDDEN |
                                 kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addColorParameterWithName:@"Stroke Color"
                          parameterID:kParamStrokeColor
                           defaultRed:1.0
                         defaultGreen:0.0
                          defaultBlue:0.0
                       parameterFlags:kFxParameterFlag_HIDDEN];

  registerGradientSubParams(
      paramAPI, @"Gradient Type", kParamStrokeGradientType, @"Gradient Angle",
      kParamStrokeGradientAngle, @"StrokeGradientData",
      kParamStrokeGradientData, kParamStrokeGradientDataMirror,
      kParamStrokeGradientUI);

  [paramAPI addCustomParameterWithName:@"Line Cap"
                           parameterID:kParamLineCap
                          defaultValue:@(0)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_HIDDEN];

  [paramAPI addCustomParameterWithName:@"Line Join"
                           parameterID:kParamLineJoin
                          defaultValue:@(0)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_HIDDEN];

  [paramAPI addCustomParameterWithName:@"Stroke Style"
                           parameterID:kParamStrokeStyle
                          defaultValue:@(0)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_HIDDEN];

  [paramAPI addPercentSliderWithName:@"Draw On Start"
                         parameterID:kParamDrawOnStart
                        defaultValue:0.0
                        parameterMin:0.0
                        parameterMax:1.0
                           sliderMin:0.0
                           sliderMax:1.0
                               delta:0.01
                      parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addPercentSliderWithName:@"Draw On End"
                         parameterID:kParamDrawOnEnd
                        defaultValue:1.0
                        parameterMin:0.0
                        parameterMax:1.0
                           sliderMin:0.0
                           sliderMax:1.0
                               delta:0.01
                      parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addPercentSliderWithName:@"Draw On Origin"
                         parameterID:kParamDrawOnOrigin
                        defaultValue:0.0
                        parameterMin:0.0
                        parameterMax:1.0
                           sliderMin:0.0
                           sliderMax:1.0
                               delta:0.01
                      parameterFlags:kFxParameterFlag_HIDDEN];

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

  [paramAPI addPercentSliderWithName:@"Ants Speed"
                         parameterID:kParamMarchingAntsSpeed
                        defaultValue:0.0
                        parameterMin:0.0
                        parameterMax:5.0
                           sliderMin:0.0
                           sliderMax:2.0
                               delta:0.01
                      parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addCustomParameterWithName:@"Start Marker"
                           parameterID:kParamStartMarker
                          defaultValue:@(0)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_HIDDEN];

  [paramAPI addCustomParameterWithName:@"End Marker"
                           parameterID:kParamEndMarker
                          defaultValue:@(0)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_HIDDEN];

  [paramAPI addPercentSliderWithName:@"Start Size"
                         parameterID:kParamStartMarkerSize
                        defaultValue:3.0
                        parameterMin:0.5
                        parameterMax:FLT_MAX
                           sliderMin:0.5
                           sliderMax:5.0
                               delta:0.1
                      parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addPercentSliderWithName:@"End Size"
                         parameterID:kParamEndMarkerSize
                        defaultValue:3.0
                        parameterMin:0.5
                        parameterMax:FLT_MAX
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

  [paramAPI addCustomParameterWithName:@""
                           parameterID:kParamExpandedFill
                          defaultValue:[KKDataBlob blobWithString:@"0"]
                        parameterFlags:kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addToggleButtonWithName:@"Fill"
                        parameterID:kParamFillEnabled
                       defaultValue:NO
                     parameterFlags:kFxParameterFlag_HIDDEN |
                                    kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addPopupMenuWithName:@"Fill Mode"
                     parameterID:kParamFillColorMode
                    defaultValue:0
                     menuEntries:@[ @"Solid", @"Gradient" ]
                  parameterFlags:kFxParameterFlag_HIDDEN |
                                 kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addColorParameterWithName:@"Fill Color"
                          parameterID:kParamFillColor
                           defaultRed:1.0
                         defaultGreen:1.0
                          defaultBlue:1.0
                       parameterFlags:kFxParameterFlag_HIDDEN];

  registerGradientSubParams(paramAPI, @"Fill Gradient Type",
                            kParamFillGradientType, @"Fill Gradient Angle",
                            kParamFillGradientAngle, @"FillGradientData",
                            kParamFillGradientData,
                            kParamFillGradientDataMirror, kParamFillGradientUI);

  [paramAPI addCustomParameterWithName:@"Fill Style"
                           parameterID:kParamSketchFillStyle
                          defaultValue:@(0)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_HIDDEN];

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

  [paramAPI addFloatSliderWithName:@"Fill Tint"
                       parameterID:kParamFillTint
                      defaultValue:100.0
                      parameterMin:0.0
                      parameterMax:100.0
                         sliderMin:0.0
                         sliderMax:100.0
                             delta:1.0
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addCustomParameterWithName:@""
                           parameterID:kParamGroupSketch
                          defaultValue:@(kParamGroupSketch)
                        parameterFlags:kFxParameterFlag_CUSTOM_UI |
                                       kFxParameterFlag_NOT_ANIMATABLE |
                                       kFxParameterFlag_USE_FULL_VIEW_WIDTH];

  [paramAPI addCustomParameterWithName:@""
                           parameterID:kParamExpandedSketch
                          defaultValue:[KKDataBlob blobWithString:@"0"]
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
                                       kFxParameterFlag_HIDDEN];

  // Animatable so selection changes go on the host undo stack. Without
  // this, an inspector value edit on path A followed by selecting path B
  // and pressing cmd-Z reverts the value param while B is selected — the
  // mutation hook then applies the reverted value to B (wrong path).
  // Making selectedIndex undoable means cmd-Z first restores the prior
  // selection (back to A), so the next cmd-Z reverts the value with A
  // active and the mutation hook writes to the correct path.
  [paramAPI addFloatSliderWithName:@"LastSelectedIndex"
                       parameterID:kParamLastSelectedIndex
                      defaultValue:-1.0
                      parameterMin:-1.0
                      parameterMax:10000.0
                         sliderMin:-1.0
                         sliderMax:10000.0
                             delta:1.0
                    parameterFlags:kFxParameterFlag_HIDDEN];

  [paramAPI addStringParameterWithName:@"InstanceID"
                           parameterID:kParamInstanceID
                          defaultValue:@""
                        parameterFlags:kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addStringParameterWithName:@"CanvasSelection"
                           parameterID:kParamCanvasSelection
                          defaultValue:@""
                        parameterFlags:kFxParameterFlag_HIDDEN |
                                       kFxParameterFlag_NOT_ANIMATABLE];

  [paramAPI addStringParameterWithName:@"CollapsedGroups"
                           parameterID:kParamCollapsedGroups
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
