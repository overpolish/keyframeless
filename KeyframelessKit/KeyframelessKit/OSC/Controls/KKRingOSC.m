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

@implementation KKRingOSC {
  BOOL _cursorSet;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _ringRadius = 50.0f;
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
  return _ringRadius + _fillWidth / 2.0f + _ringOutlineWidth;
}

- (float)oscSize {
  return _ringRadius + _fillWidth / 2.0f + _ringOutlineWidth;
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
  CGPoint pos = _center;
  double dx = positionX - pos.x;
  double dy = positionY - pos.y;
  double dist = sqrt(dx * dx + dy * dy);
  double ringDist = fabs(dist - _ringRadius);
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
  float outerRadiusPixels = _ringRadius + fillWidth / 2.0f + outlineWidth;

  simd_float4 fillColor;
  simd_float4 strokeColor;
  if (isActive) {
    fillColor = [[NSColor ringActiveFill] simdFloat4];
    strokeColor = [[NSColor ringActiveStroke] simdFloat4];
  } else if (isHovered) {
    fillColor = [[NSColor ringHoverFill] simdFloat4];
    strokeColor = [[NSColor ringHoverStroke] simdFloat4];
  } else {
    fillColor = [[NSColor ringIdleFill] simdFloat4];
    strokeColor = [[NSColor ringIdleStroke] simdFloat4];
  }

  KKRingOSCParams params = {.ringRadius = _ringRadius / outerRadiusPixels,
                            .fillHalfWidth =
                                (fillWidth / 2.0f) / outerRadiusPixels,
                            .outlineWidth = outlineWidth / outerRadiusPixels,
                            .fillColor = fillColor,
                            .strokeColor = strokeColor};

  [self
      encodeRenderCommandsForDestinationImage:destinationImage
                               canvasPosition:canvasPosition
                             clearDestination:NO
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
