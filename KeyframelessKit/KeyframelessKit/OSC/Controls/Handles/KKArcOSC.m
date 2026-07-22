/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKArcOSC.h"
#import "KKOSCShaderTypes.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#include <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

static NSColor *arcFillColor(void) {
  return [NSColor colorWithRed:0xC1 / 255.0
                         green:0xC1 / 255.0
                          blue:0xC1 / 255.0
                         alpha:1.0f];
}
static NSColor *arcStrokeColor(void) {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:0.8f];
}

@implementation KKArcOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _oscRadius = 23.0f;
    _strokeWidth = 10.0f;
    _outlineWidth = KKBorderWidthXS + 0.75;
    _fillAlpha = 1.0f;
    _ghostAlpha = 1.0f;
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
      .fillColor = [[arcFillColor()
          colorWithAlphaComponent:_fillAlpha * _ghostAlpha] simdFloat4],
      .strokeColor = [[arcStrokeColor()
          colorWithAlphaComponent:0.8f * _ghostAlpha] simdFloat4]};

  [self drawQuadForDestinationImage:destinationImage
                     canvasPosition:canvasPosition
                      pipelineState:ps
                       fragmentData:&params
                   fragmentDataSize:sizeof(params)
                               size:outerRadiusPixels];
}

@end
