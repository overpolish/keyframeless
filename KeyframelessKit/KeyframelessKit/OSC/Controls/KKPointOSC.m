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
      .fillColor = isActive    ? [[NSColor pointFillActive] simdFloat4]
                   : isHovered ? [[NSColor pointFillHover] simdFloat4]
                               : [[NSColor pointFill] simdFloat4],
      .strokeColor = [[NSColor pointStroke] simdFloat4]};

  [self
      encodeRenderCommandsForDestinationImage:destinationImage
                               canvasPosition:canvasPosition
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         CGPoint metalPosition,
                                         simd_uint2 viewportSize) {
                                       KKVertex2D quadVertices[6];
                                       [KKRenderPrimitives
                                           generateQuadVertices:quadVertices
                                                         center:metalPosition
                                                           size:
                                                               outerRadiusPixels];

                                       [encoder setRenderPipelineState:ps];
                                       [encoder
                                           setVertexBytes:quadVertices
                                                   length:sizeof(quadVertices)
                                                  atIndex:
                                                      KKVertexInputIndex_Vertices];
                                       [encoder
                                           setVertexBytes:&viewportSize
                                                   length:sizeof(viewportSize)
                                                  atIndex:
                                                      KKVertexInputIndex_ViewportSize];
                                       [encoder
                                           setFragmentBytes:&params
                                                     length:sizeof(params)
                                                    atIndex:
                                                        KKOSCFragmentIndex_DrawColor];
                                       [encoder drawPrimitives:
                                                    MTLPrimitiveTypeTriangle
                                                   vertexStart:0
                                                   vertexCount:6];
                                     }];
}

@end
