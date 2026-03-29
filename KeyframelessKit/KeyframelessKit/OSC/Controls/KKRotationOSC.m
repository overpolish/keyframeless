/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKRotationOSC.h"
#import "../../Style/KKTokens.h"
#import "../../Style/NSColor+KKColors.h"
#import "../Base/KKOSCShaderTypes.h"
#include <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

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
static NSColor *donutFillColor(void) {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:0.13f];
}
static NSColor *donutStrokeColor(void) {
  return [NSColor colorWithRed:0xFF / 255.0
                         green:0xFF / 255.0
                          blue:0xFF / 255.0
                         alpha:0.2f];
}

@implementation KKRotationOSC {
  float _initialAngle;
  BOOL _wasActive;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _armLength = 105.0f;
    _centerOffset = 26.0f;
    _circleRadius = 9.0f;
    _lineWidth = 2.5f;
    _outlineWidth = KKBorderWidthXS + 0.75;
    _angle = 0.0f;
  }
  return self;
}

- (NSString *)pipelinePluginID {
  return @"co.overpolish.keyframelesskit.RotationOSC";
}
- (NSString *)fragmentFunctionName {
  return @"KKRotationOSCFragment";
}

- (float)hitRadius {
  return _armLength + _circleRadius + _outlineWidth;
}
- (float)oscSize {
  return _armLength + _circleRadius + _outlineWidth;
}

- (BOOL)hitTestAtMousePositionX:(double)positionX
                      positionY:(double)positionY
                         atTime:(CMTime)time {
  double circleX = _center.x + _armLength * cos(_angle);
  double circleY = _center.y - _armLength * sin(_angle);
  double dx = positionX - circleX;
  double dy = positionY - circleY;
  double dist = sqrt(dx * dx + dy * dy);
  return dist < (_circleRadius + _outlineWidth + 4.0);
}

- (void)drawAtCanvasPosition:(CGPoint)canvasPosition
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time {
  if (isActive && !_wasActive)
    _initialAngle = _angle;
  _wasActive = isActive;

  id<MTLRenderPipelineState> ps =
      [self pipelineStateForDestinationImage:destinationImage];
  if (!ps)
    return;

  float outerRadiusPixels = _armLength + _circleRadius + _outlineWidth;

  BOOL showDonut = isHovered || isActive;
  float donutFillHW = _circleRadius;
  float donutOuterFill =
      _armLength + _circleRadius - 2.0f - _outlineWidth * 2.0f;
  float donutR = donutOuterFill - donutFillHW;
  float donutOW = KKBorderWidthSM;

  KKRotationOSCParams params = {
      .armLength = _armLength / outerRadiusPixels,
      .centerOffset = _centerOffset / outerRadiusPixels,
      .circleRadius = _circleRadius / outerRadiusPixels,
      .lineHalfWidth = (_lineWidth / 2.0f) / outerRadiusPixels,
      .outlineWidth = _outlineWidth / outerRadiusPixels,
      .angle = _angle,
      .fillColor = isActive    ? [pointFillActiveColor() simdFloat4]
                   : isHovered ? [pointFillHoverColor() simdFloat4]
                               : [pointFillColor() simdFloat4],
      .strokeColor = [pointStrokeColor() simdFloat4],
      .donutRadius = showDonut ? donutR / outerRadiusPixels : 0.0f,
      .donutFillHalfWidth = donutFillHW / outerRadiusPixels,
      .donutOutlineWidth = donutOW / outerRadiusPixels,
      .donutFillColor = [donutFillColor() simdFloat4],
      .donutStrokeColor = [donutStrokeColor() simdFloat4],
      .markerAngle = _initialAngle,
      .markerRadius = isActive ? 4.0f / outerRadiusPixels : 0.0f,
      .markerOutlineWidth = KKBorderWidthXS / outerRadiusPixels,
      .markerFillColor = [pointFillColor() simdFloat4],
      .markerStrokeColor = [pointStrokeColor() simdFloat4],
  };

  [self drawQuadForDestinationImage:destinationImage
                     canvasPosition:canvasPosition
                   clearDestination:NO
                      pipelineState:ps
                       fragmentData:&params
                   fragmentDataSize:sizeof(params)
                               size:outerRadiusPixels];
}

@end
