/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"

@implementation CanvasPlugin (Visibility)

- (void)updateParameterVisibilityAtTime:(CMTime)time {
  NSArray<NSNumber *> *allParams = @[
    @(kParamStrokeEnabled),
    @(kParamStrokeWidth),
    @(kParamStrokeColor),
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
    @(kParamDrawOnOrigin),
    @(kParamMarchingAntsSpeed),
    @(kParamStartMarker),
    @(kParamEndMarker),
    @(kParamStartMarkerSize),
    @(kParamEndMarkerSize),
    @(kParamClosedPath),
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
    @(kParamFillColorMode),
    @(kParamFillGradientType),
    @(kParamFillGradientAngle),
    @(kParamTransformEnabled),
    @(kParamPosition),
    @(kParamRotation),
    @(kParamScaleX),
    @(kParamScaleY),
    @(kParamAnchor),
    @(kParamRotationX),
    @(kParamRotationY),
  ];

  [self forceShowAllParametersIfEnabled:kParamForceShow
                               paramIDs:allParams
                                 atTime:time];
}

@end
