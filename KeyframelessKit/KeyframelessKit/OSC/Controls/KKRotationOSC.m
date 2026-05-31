/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKRotationOSC.h"
#import "../../Style/KKTokens.h"
#import "../../Style/NSColor+KKColors.h"
#import "../Base/KKOSCShaderTypes.h"
#import "../Base/KKRotationOSCMath.h"
#include <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

static const int kRingSamples = 192;
static const float kHitThresholdPixels = 10.0f;

@implementation KKRotationOSC {
  NSInteger _activeAxis; // -1 / 0 / 1 / 2
  double _pressAngle;    // ring t-angle at press point
  double _pressTangentX; // screen tangent at press (unit)
  double _pressTangentY;
  float _pressRotX; // original angles at press for redo math
  float _pressRotY;
  float _pressRotZ;
}

@synthesize colorX = _colorX;
@synthesize colorY = _colorY;
@synthesize colorZ = _colorZ;
@synthesize outlineColor = _outlineColor;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _radius = 90.0f;
    _ringHalfWidth = 2.5f;
    _outlineWidth = 1.0f;
    _backDim = 0.3f;
    _activeAxis = -1;
    _showX = YES;
    _showY = YES;
    _showZ = YES;
    _colorX = [NSColor colorWithRed:1.0 green:0.30 blue:0.30 alpha:1.0];
    _colorY = [NSColor colorWithRed:0.35 green:0.85 blue:0.40 alpha:1.0];
    _colorZ = [NSColor colorWithRed:0.40 green:0.55 blue:1.0 alpha:1.0];
    _outlineColor = [NSColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.75];
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
  return _radius + _ringHalfWidth + _outlineWidth + kHitThresholdPixels;
}
- (float)oscSize {
  return _radius + _ringHalfWidth + _outlineWidth + 2.0f;
}

- (BOOL)hitTestAtMousePositionX:(double)positionX
                      positionY:(double)positionY
                         atTime:(CMTime)time {
  KKRotMatrix3 m = KKBuildRotationMatrix(_rotX, _rotY, _rotZ);
  // Hit-test in Y-DOWN screen space so it agrees with both the shader's
  // textureCoordinate.y and the renderer's internal screen convention. The
  // canvas itself is Y-UP (positionY increases upward), so negate Y when
  // forming the local-relative point.
  CGPoint local = CGPointMake(positionX - _center.x, _center.y - positionY);
  // Front-only: the shader visibly dims the back half, so back portions
  // are easy to mistake for empty space. Only the bright front hemisphere
  // is grabbable - what you see is what you can hit.
  double bestFront = 1e9;
  NSInteger bestFrontK = -1;
  double bestFrontT = 0;
  const BOOL ringShown[3] = {_showX, _showY, _showZ};
  for (int k = 0; k < 3; k++) {
    if (!ringShown[k])
      continue; // hidden ring is not grabbable
    KKRingHit h = KKClosestAngleOnRing(m, k, _radius, local, kRingSamples);
    if (h.frontDist < bestFront) {
      bestFront = h.frontDist;
      bestFrontK = k;
      bestFrontT = h.frontT;
    }
  }
  if (bestFrontK < 0 || bestFront > kHitThresholdPixels) {
    _activeAxis = -1;
    return NO;
  }
  _activeAxis = bestFrontK;
  _pressAngle = bestFrontT;
  return YES;
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
  // Lock the tangent + rotation values at press time so dragging is
  // consistent even if rotX/Y/Z get nudged mid-drag by something else.
  _pressRotX = _rotX;
  _pressRotY = _rotY;
  _pressRotZ = _rotZ;
  if (_activeAxis < 0)
    return;
  KKRotMatrix3 m = KKBuildRotationMatrix(_rotX, _rotY, _rotZ);
  simd_float3 U, V;
  KKRingBasis(m, (int)_activeAxis, &U, &V);
  double t = _pressAngle;
  // Screen-space tangent at the ring point = derivative w.r.t. t, projected.
  double tx = -sin(t) * U.x + cos(t) * V.x;
  double ty = -sin(t) * U.y + cos(t) * V.y;
  double len = sqrt(tx * tx + ty * ty);
  if (len > 1e-6) {
    tx /= len;
    ty /= len;
  }
  _pressTangentX = tx;
  _pressTangentY = ty;
}

- (double)angleDeltaFromPressPoint:(CGPoint)pressPoint
                      currentPoint:(CGPoint)currentPoint {
  if (_activeAxis < 0 || _radius <= 0)
    return 0.0;
  double dx = currentPoint.x - pressPoint.x;
  // Mouse y comes in canvas Y-UP; the press tangent was captured in
  // Y-DOWN screen space (same convention as the shader / hit-test), so
  // negate dy before projecting.
  double dy = pressPoint.y - currentPoint.y;
  double projected = dx * _pressTangentX + dy * _pressTangentY;
  // Per-axis sign tuned to user-natural drag direction.
  static const double kAxisSign[3] = {+1.0, -1.0, +1.0};
  double sign = kAxisSign[_activeAxis];
  return sign * projected / (double)_radius;
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

  float quadHalf = _radius + _ringHalfWidth + _outlineWidth + 2.0f;

  KKRotMatrix3 m = KKBuildRotationMatrix(_rotX, _rotY, _rotZ);

  KKRotationOSCParams params = {
      .rotCol0 = m.col0,
      .rotCol1 = m.col1,
      .rotCol2 = m.col2,
      .radius = _radius / quadHalf,
      .ringHalfWidth = _ringHalfWidth / quadHalf,
      .outlineWidth = _outlineWidth / quadHalf,
      .backDim = _backDim,
      .ringColorX = [_colorX simdFloat4],
      .ringColorY = [_colorY simdFloat4],
      .ringColorZ = [_colorZ simdFloat4],
      .outlineColor = [_outlineColor simdFloat4],
      .activeRing = (int)((isActive || isHovered) ? _activeAxis : -1),
      .activeBoost = isActive ? 0.35f : (isHovered ? 0.15f : 0.0f),
      .ringVisible = (vector_float3){_showX ? 1.0f : 0.0f, _showY ? 1.0f : 0.0f,
                                     _showZ ? 1.0f : 0.0f},
  };

  [self drawQuadForDestinationImage:destinationImage
                     canvasPosition:canvasPosition
                   clearDestination:NO
                      pipelineState:ps
                       fragmentData:&params
                   fragmentDataSize:sizeof(params)
                               size:quadHalf];
}

@end
