/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"

@implementation CanvasPlugin (Visibility)

- (void)updateParameterVisibilityAtTime:(CMTime)time {
  NSArray<NSNumber *> *allParams = @[
    @(kParamGroupStroke),     @(kParamStrokeEnabled),
    @(kParamStrokeWidth),     @(kParamStrokeColor),
    @(kParamGroupFill),       @(kParamFillEnabled),
    @(kParamFillColor),       @(kParamOpacity),
    @(kParamLineCap),         @(kParamLineJoin),
    @(kParamStrokeStyle),     @(kParamDashLength),
    @(kParamDashGap),         @(kParamDotGap),
    @(kParamClosedPath),      @(kParamCornerRadiusTL),
    @(kParamCornerRadiusTR),  @(kParamCornerRadiusBR),
    @(kParamCornerRadiusBL),  @(kParamGroupSketch),
    @(kParamSketchEnabled),   @(kParamSketchRoughness),
    @(kParamSketchBowing),    @(kParamSketchStrokes),
    @(kParamSketchFillStyle), @(kParamSketchFillGap),
    @(kParamSketchFillAngle), @(kParamSketchFillWeight),
    @(kParamSketchSeed),
  ];

  [self forceShowAllParametersIfEnabled:kParamForceShow
                               paramIDs:allParams
                                 atTime:time];
}

@end
