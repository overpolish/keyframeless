/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKSnapEngine.h"
#import "../Base/KKOnScreenControl+CoordinateSpace.h"
#import <FxPlug/FxPlugSDK.h>

@implementation KKSnapEngine

- (instancetype)init {
  self = [super init];
  if (self) {
    _threshold = 8.0f;
  }
  return self;
}

- (CGPoint)snapCanvasPoint:(CGPoint)point
                 toTargets:(const CGPoint *)targets
                     count:(NSUInteger)count {
  _snappedX = NO;
  _snappedY = NO;

  float bestDX = FLT_MAX, bestDY = FLT_MAX;
  float snapX = (float)point.x, snapY = (float)point.y;

  for (NSUInteger i = 0; i < count; i++) {
    float dx = (float)fabs(point.x - targets[i].x);
    float dy = (float)fabs(point.y - targets[i].y);
    if (dx < _threshold && dx < bestDX) {
      bestDX = dx;
      snapX = (float)targets[i].x;
    }
    if (dy < _threshold && dy < bestDY) {
      bestDY = dy;
      snapY = (float)targets[i].y;
    }
  }

  if (bestDX < FLT_MAX) {
    _snappedX = YES;
    _snapValueX = snapX;
    point.x = snapX;
  }
  if (bestDY < FLT_MAX) {
    _snappedY = YES;
    _snapValueY = snapY;
    point.y = snapY;
  }
  return point;
}

- (simd_float2)snapObjectPoint:(simd_float2)point
                     toTargets:(const simd_float2 *)targets
                         count:(NSUInteger)count
                 pixelsPerUnit:(float)pixelsPerUnit {
  _snappedX = NO;
  _snappedY = NO;

  float objThresh = (pixelsPerUnit > 0) ? _threshold / pixelsPerUnit : 0.005f;

  float bestDX = FLT_MAX, bestDY = FLT_MAX;
  float snapX = point.x, snapY = point.y;

  for (NSUInteger i = 0; i < count; i++) {
    float dx = fabsf(point.x - targets[i].x);
    float dy = fabsf(point.y - targets[i].y);
    if (dx < objThresh && dx < bestDX) {
      bestDX = dx;
      snapX = targets[i].x;
    }
    if (dy < objThresh && dy < bestDY) {
      bestDY = dy;
      snapY = targets[i].y;
    }
  }

  if (bestDX < FLT_MAX) {
    _snappedX = YES;
    _snapValueX = snapX;
    point.x = snapX;
  }
  if (bestDY < FLT_MAX) {
    _snappedY = YES;
    _snapValueY = snapY;
    point.y = snapY;
  }
  return point;
}

- (void)reset {
  _snappedX = NO;
  _snappedY = NO;
}

- (void)drawSnapGuidesWithOSC:(KKOnScreenControl *)osc
                isObjectSpace:(BOOL)isObjectSpace
             destinationImage:(FxImageTile *)destinationImage {
  if (!_snappedX && !_snappedY)
    return;

  CGPoint bottomLeft = [osc canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint topRight = [osc canvasPointFromObjectPoint:(simd_float2){1, 1}];
  float minX = fmin(bottomLeft.x, topRight.x);
  float maxX = fmax(bottomLeft.x, topRight.x);
  float minY = fmin(bottomLeft.y, topRight.y);
  float maxY = fmax(bottomLeft.y, topRight.y);
  simd_float4 yellow = {1, 1, 0, 1};

  if (_snappedX) {
    float canvasX = _snapValueX;
    if (isObjectSpace) {
      CGPoint c =
          [osc canvasPointFromObjectPoint:(simd_float2){_snapValueX, 0}];
      canvasX = (float)c.x;
    }
    [osc drawLineFrom:(CGPoint){canvasX, minY}
                      to:(CGPoint){canvasX, maxY}
                   color:yellow
               halfWidth:2.0f
        destinationImage:destinationImage];
  }
  if (_snappedY) {
    float canvasY = _snapValueY;
    if (isObjectSpace) {
      CGPoint c =
          [osc canvasPointFromObjectPoint:(simd_float2){0, _snapValueY}];
      canvasY = (float)c.y;
    }
    [osc drawLineFrom:(CGPoint){minX, canvasY}
                      to:(CGPoint){maxX, canvasY}
                   color:yellow
               halfWidth:2.0f
        destinationImage:destinationImage];
  }
}

@end
