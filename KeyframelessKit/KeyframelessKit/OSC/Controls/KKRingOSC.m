/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKRingOSC.h"
#import "../../Style/NSColor+KKColors.h"
#import "../Base/KKOSCShaderTypes.h"
#import <AppKit/NSCursor.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

static NSCursor *resizeCursorForAngle(double radians) {
  double deg = radians * 180.0 / M_PI;
  if (deg < 0)
    deg += 360.0;

  int sector = ((int)round(deg / 45.0)) % 8;

  switch (sector) {
  case 0: // Right
  case 4: // Left
    return [NSCursor resizeLeftRightCursor];
  case 2: // Up
  case 6: // Down
    return [NSCursor resizeUpDownCursor];
  case 1:   // Top-right
  case 5: { // Bottom-left
    SEL sel = NSSelectorFromString(@"_windowResizeNorthEastSouthWestCursor");
    if ([NSCursor respondsToSelector:sel])
      return [NSCursor performSelector:sel];
    return [NSCursor resizeLeftRightCursor];
  }
  case 3:   // Top-left
  case 7: { // Bottom-right
    SEL sel = NSSelectorFromString(@"_windowResizeNorthWestSouthEastCursor");
    if ([NSCursor respondsToSelector:sel])
      return [NSCursor performSelector:sel];
    return [NSCursor resizeUpDownCursor];
  }
  default:
    return [NSCursor arrowCursor];
  }
}

static NSColor *ringIdleFillColor(void) {
  return [NSColor colorWithRed:0xCE / 255.0
                         green:0xCB / 255.0
                          blue:0xCE / 255.0
                         alpha:0xB1 / 255.0];
}
static NSColor *ringIdleStrokeColor(void) {
  return [NSColor colorWithRed:0x1B / 255.0
                         green:0x18 / 255.0
                          blue:0x1D / 255.0
                         alpha:0x9F / 255.0];
}
static NSColor *ringHoverFillColor(void) {
  return [NSColor colorWithRed:0xD0 / 255.0
                         green:0xCA / 255.0
                          blue:0xCD / 255.0
                         alpha:0xB2 / 255.0];
}
static NSColor *ringHoverStrokeColor(void) {
  return [NSColor colorWithRed:0x09 / 255.0
                         green:0x07 / 255.0
                          blue:0x0A / 255.0
                         alpha:0xAD / 255.0];
}
static NSColor *ringActiveFillColor(void) {
  return [NSColor colorWithRed:0xFF / 255.0
                         green:0xFF / 255.0
                          blue:0xFF / 255.0
                         alpha:1.0f];
}
static NSColor *ringActiveStrokeColor(void) {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:1.0f];
}

@implementation KKRingOSC {
  BOOL _cursorSet;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _ringRadius = 50.0f;
    _ringRadiusY = 50.0f;
    _fillWidth = 2.0f;
    _ringOutlineWidth = 1.5f;
  }
  return self;
}

- (NSString *)pipelinePluginID {
  return @"co.overpolish.keyframelesskit.RingOSC";
}

- (NSString *)fragmentFunctionName {
  return @"KKRingOSCFragment";
}

- (float)hitRadius {
  return fmaxf(_ringRadius, _ringRadiusY) + _fillWidth / 2.0f +
         _ringOutlineWidth;
}

- (float)oscSize {
  return fmaxf(_ringRadius, _ringRadiusY) + _fillWidth / 2.0f +
         _ringOutlineWidth;
}

- (void)updateCursorForMouseX:(double)positionX positionY:(double)positionY {
  double dx = positionX - _center.x;
  double dy = positionY - _center.y;
  double angle = atan2(dy, dx);
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  [oscAPI setCursor:resizeCursorForAngle(angle)];
}

- (BOOL)hitTestAtMousePositionX:(double)positionX
                      positionY:(double)positionY
                         atTime:(CMTime)time {
  if (_ringRadius < 1.0f && _ringRadiusY < 1.0f)
    return NO;

  CGPoint pos = _center;
  double dx = positionX - pos.x;
  double dy = positionY - pos.y;
  double nx = (_ringRadius > 0) ? dx / _ringRadius : 0;
  double ny = (_ringRadiusY > 0) ? dy / _ringRadiusY : 0;
  double ellipseDist = sqrt(nx * nx + ny * ny);
  double meanRadius = (_ringRadius + _ringRadiusY) * 0.5;
  double ringDist = fabs(ellipseDist - 1.0) * meanRadius;
  float hitWidth = _fillWidth / 2.0f + _ringOutlineWidth + 4.0f;

  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

  if (ringDist < hitWidth) {
    double angle = atan2(dy, dx);
    [oscAPI setCursor:resizeCursorForAngle(angle)];
    _cursorSet = YES;
    return YES;
  }

  if (_cursorSet) {
    [oscAPI setCursor:[NSCursor arrowCursor]];
    _cursorSet = NO;
  }
  return NO;
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

  float fillWidth = (isHovered || isActive) ? 2.5f : 2.0f;
  float outlineWidth = (isHovered || isActive) ? 1.5f : 1.0f;
  float outerX = _ringRadius + fillWidth / 2.0f + outlineWidth;
  float outerY = _ringRadiusY + fillWidth / 2.0f + outlineWidth;
  float outerRadiusPixels = fmaxf(outerX, outerY);

  simd_float4 fillColor;
  simd_float4 strokeColor;
  if (isActive) {
    fillColor = [ringActiveFillColor() simdFloat4];
    strokeColor = [ringActiveStrokeColor() simdFloat4];
  } else if (isHovered) {
    fillColor = [ringHoverFillColor() simdFloat4];
    strokeColor = [ringHoverStrokeColor() simdFloat4];
  } else {
    fillColor = [ringIdleFillColor() simdFloat4];
    strokeColor = [ringIdleStrokeColor() simdFloat4];
  }

  KKRingOSCParams params = {.ringRadiusX = _ringRadius / outerRadiusPixels,
                            .ringRadiusY = _ringRadiusY / outerRadiusPixels,
                            .fillHalfWidth =
                                (fillWidth / 2.0f) / outerRadiusPixels,
                            .outlineWidth = outlineWidth / outerRadiusPixels,
                            .fillColor = fillColor,
                            .strokeColor = strokeColor};

  [self drawQuadForDestinationImage:destinationImage
                     canvasPosition:canvasPosition
                   clearDestination:NO
                      pipelineState:ps
                       fragmentData:&params
                   fragmentDataSize:sizeof(params)
                               size:outerRadiusPixels];
}

@end
