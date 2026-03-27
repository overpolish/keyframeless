/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKArcOSC.h"
#import "../../Style/KKTokens.h"
#import "../../Style/NSColor+KKColors.h"
#import "../Base/KKOSCShaderTypes.h"
#include <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

@implementation KKArcOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _oscRadius = 23.0f;
    _strokeWidth = 10.0f;
    _outlineWidth = KKBorderWidthXS + 0.75;
  }
  return self;
}

- (NSString *)pipelinePluginID {
  return @"co.overpolish.keyframelesskit.ArcOSC";
}
- (NSString *)fragmentFunctionName {
  return @"KKArcOSCFragment";
}

- (float)hitRadius {
  return _oscRadius + _outlineWidth;
}
- (float)oscSize {
  return (_oscRadius + _strokeWidth + _outlineWidth) / 2.0f;
}

- (void)drawAtCanvasPosition:(CGPoint)canvasPosition
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time {
  id<MTLRenderPipelineState> ps =
      [self pipelineStateForDestinationImage:destinationImage];
  if (!ps)
    return;

  float radius = isActive ? 31.0f : _oscRadius;
  float outerRadiusPixels = radius + _outlineWidth;

  KKArcOSCParams params = {
      .innerRadius = (radius - _strokeWidth) / outerRadiusPixels,
      .outlineWidth = _outlineWidth / outerRadiusPixels,
      .plusHalfLen = isActive ? 7.0f / outerRadiusPixels : 0.0f,
      .plusFillHalfWidth = 1.0f / outerRadiusPixels,
      .plusOutlineWidth = 2.0f / outerRadiusPixels,
      .fillColor = [[NSColor arcFill] simdFloat4],
      .strokeColor = [[NSColor arcStroke] simdFloat4]};

  [self drawQuadForDestinationImage:destinationImage
                     canvasPosition:canvasPosition
                      pipelineState:ps
                       fragmentData:&params
                   fragmentDataSize:sizeof(params)
                               size:outerRadiusPixels];
}

@end
