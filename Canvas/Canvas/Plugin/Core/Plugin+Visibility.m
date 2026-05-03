/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"

@implementation CanvasPlugin (Visibility)

- (void)updateParameterVisibilityAtTime:(CMTime)time {
  NSArray<NSNumber *> *allParams = @[
    @(kParamGroupStroke),
    @(kParamStrokeEnabled),
    @(kParamStrokeWidth),
    @(kParamStrokeColor),
    @(kParamGroupFill),
    @(kParamFillEnabled),
    @(kParamFillColor),
    @(kParamOpacity),
    @(kParamLineCap),
    @(kParamLineJoin),
    @(kParamStrokeStyle),
    @(kParamDashLength),
    @(kParamDashGap),
    @(kParamDotGap),
    @(kParamDrawOnStart),
    @(kParamDrawOnEnd),
    @(kParamMarchingAntsSpeed),
    @(kParamStartMarker),
    @(kParamEndMarker),
    @(kParamStartMarkerSize),
    @(kParamEndMarkerSize),
    @(kParamClosedPath),
    @(kParamGroupSketch),
    @(kParamSketchEnabled),
    @(kParamSketchRoughness),
    @(kParamSketchBowing),
    @(kParamSketchStrokes),
    @(kParamSketchFillStyle),
    @(kParamSketchFillGap),
    @(kParamSketchFillAngle),
    @(kParamSketchFillWeight),
    @(kParamSketchSeed),
    @(kParamStrokeColorMode),
    @(kParamStrokeGradientType),
    @(kParamStrokeGradientAngle),
    @(kParamStrokeGradientData),
    @(kParamFillColorMode),
    @(kParamFillGradientType),
    @(kParamFillGradientAngle),
    @(kParamFillGradientData),
    @(kParamGroupTransform),
    @(kParamTransformEnabled),
    @(kParamPosition),
  ];

  [self forceShowAllParametersIfEnabled:kParamForceShow
                               paramIDs:allParams
                                 atTime:time];
}

@end
