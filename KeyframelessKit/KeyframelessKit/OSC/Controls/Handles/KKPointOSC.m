/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPointOSC.h"
#import "KKOSCShaderTypes.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#include <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

static NSString *kPointOSCPluginID = @"com.keyframeless.kit.PointOSC";

// Fill/stroke come from the SHARED glyph style (KKOSCGlyphStyle.h) so the
// mini-viewer's dot encode and this viewer OSC can never drift apart.
#import "KKOSCGlyphStyle.h"

static NSColor *pointFillColor(void) {
  return KKOSCColorFromSimd(KKOSCPointFill());
}
static NSColor *pointStrokeColor(void) {
  return KKOSCColorFromSimd(KKOSCPointStroke());
}

@implementation KKPointOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _oscRadius = KKRadiusMD;
    _outlineWidth = KKBorderWidthXS;
    _ghostAlpha = 1.0f;
  }
  return self;
}

- (NSString *)pipelinePluginID {
  return @"com.keyframeless.kit.PointOSC";
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

  NSColor *fill = _fillColorOverride ? _fillColorOverride : pointFillColor();
  simd_float4 fillC = [fill simdFloat4];
  simd_float4 strokeC = [pointStrokeColor() simdFloat4];
  fillC.w *= _ghostAlpha;
  strokeC.w *= _ghostAlpha;
  KKPointOSCParams params = {.outlineWidth = _outlineWidth / outerRadiusPixels,
                             .fillColor = fillC,
                             .strokeColor = strokeC};

  [self drawQuadForDestinationImage:destinationImage
                     canvasPosition:canvasPosition
                      pipelineState:ps
                       fragmentData:&params
                   fragmentDataSize:sizeof(params)
                               size:outerRadiusPixels];
}

@end
