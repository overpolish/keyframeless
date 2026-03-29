/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKPointOSC.h"
#import "../../Style/KKTokens.h"
#import "../../Style/NSColor+KKColors.h"
#import "../Base/KKOSCShaderTypes.h"
#include <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

static NSString *kPointOSCPluginID = @"co.overpolish.keyframelesskit.PointOSC";

static NSColor *pointFillColor(void) {
  return [NSColor colorWithRed:0xB3 / 255.0
                         green:0xB3 / 255.0
                          blue:0xB3 / 255.0
                         alpha:0.65f];
}
static NSColor *pointFillHoverColor(void) {
  return [NSColor colorWithRed:0xB3 / 255.0
                         green:0xB3 / 255.0
                          blue:0xB3 / 255.0
                         alpha:0.8f];
}
static NSColor *pointFillActiveColor(void) {
  return [NSColor colorWithRed:0xB3 / 255.0
                         green:0xB3 / 255.0
                          blue:0xB3 / 255.0
                         alpha:0.95f];
}
static NSColor *pointStrokeColor(void) {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:0.8f];
}

@implementation KKPointOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _oscRadius = KKRadiusMD;
    _outlineWidth = KKBorderWidthXS;
  }
  return self;
}

- (NSString *)pipelinePluginID {
  return @"co.overpolish.keyframelesskit.PointOSC";
}
- (NSString *)fragmentFunctionName {
  return @"KKPointOSCFragment";
}

- (float)hitRadius {
  return _oscRadius + _outlineWidth;
}
- (float)oscSize {
  return _oscRadius + _outlineWidth;
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

  float outerRadiusPixels = _oscRadius + _outlineWidth;

  KKPointOSCParams params = {
      .outlineWidth = _outlineWidth / outerRadiusPixels,
      .fillColor = isActive    ? [pointFillActiveColor() simdFloat4]
                   : isHovered ? [pointFillHoverColor() simdFloat4]
                               : [pointFillColor() simdFloat4],
      .strokeColor = [pointStrokeColor() simdFloat4]};

  [self drawQuadForDestinationImage:destinationImage
                     canvasPosition:canvasPosition
                      pipelineState:ps
                       fragmentData:&params
                   fragmentDataSize:sizeof(params)
                               size:outerRadiusPixels];
}

@end
