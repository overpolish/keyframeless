/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKSquarePointOSC.h"
#import "KKOSCShaderTypes.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#include <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

// Fill/stroke come from the SHARED glyph style (KKOSCGlyphStyle.h) - same
// palette as the point dot, so viewer + mini squares can't drift.
#import "KKOSCGlyphStyle.h"

static NSColor *squarePointFillColor(void) {
  return KKOSCColorFromSimd(KKOSCPointFill());
}
static NSColor *squarePointStrokeColor(void) {
  return KKOSCColorFromSimd(KKOSCPointStroke());
}
static NSColor *squarePointShadowColor(void) {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:0.5f];
}

@implementation KKSquarePointOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _oscSize = 6.0f;
    _cornerRadius = KKRadiusSM;
    _outlineWidth = KKBorderWidthXS + 0.5f;
    _ghostAlpha = 1.0f;
  }
  return self;
}

- (NSString *)pipelinePluginID {
  return @"com.keyframeless.kit.SquarePointOSC";
}
- (NSString *)fragmentFunctionName {
  return @"KKSquarePointOSCFragment";
}

- (float)hitRadius {
  return _oscSize + _outlineWidth + 4.0f;
}
- (float)oscSize {
  return _oscSize + _outlineWidth + 3.0f;
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

  float outerRadiusPixels = _oscSize + _outlineWidth + 3.0f;

  float g = _ghostAlpha;
  simd_float4 fill = [squarePointFillColor() simdFloat4];
  simd_float4 stroke = [squarePointStrokeColor() simdFloat4];
  simd_float4 shadow = [squarePointShadowColor() simdFloat4];
  fill.w *= g;
  stroke.w *= g;
  shadow.w *= g;
  KKSquarePointOSCParams params = {
      .cornerRadius = _cornerRadius / outerRadiusPixels,
      .outlineWidth = _outlineWidth / outerRadiusPixels,
      .shadowOffset = 1.5f / outerRadiusPixels,
      .shadowRadius = 2.5f / outerRadiusPixels,
      .fillColor = fill,
      .strokeColor = stroke,
      .shadowColor = shadow,
  };

  [self drawQuadForDestinationImage:destinationImage
                     canvasPosition:canvasPosition
                      pipelineState:ps
                       fragmentData:&params
                   fragmentDataSize:sizeof(params)
                               size:outerRadiusPixels];
}

@end
