/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKSnapEngine.h"
#import "KKOnScreenControl+CoordinateSpace.h"
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

- (simd_float2)snapPoint:(simd_float2)point
          canvasAnchorsX:(const float *)cxs
                  countX:(NSUInteger)nCx
          canvasAnchorsY:(const float *)cys
                  countY:(NSUInteger)nCy
           objectTargets:(const simd_float2 *)objs
                   count:(NSUInteger)nObj
              thresholdX:(float)thrX
              thresholdY:(float)thrY {
  _snappedX = NO;
  _snappedY = NO;
  _snapXFromObject = NO;
  _snapYFromObject = NO;

  float bestDX = FLT_MAX, bestDY = FLT_MAX;
  float snapX = point.x, snapY = point.y;
  BOOL xFromObj = NO, yFromObj = NO;

  for (NSUInteger i = 0; i < nCx; i++) {
    float d = fabsf(point.x - cxs[i]);
    if (d < thrX && d < bestDX) {
      bestDX = d;
      snapX = cxs[i];
      xFromObj = NO;
    }
  }
  for (NSUInteger i = 0; i < nCy; i++) {
    float d = fabsf(point.y - cys[i]);
    if (d < thrY && d < bestDY) {
      bestDY = d;
      snapY = cys[i];
      yFromObj = NO;
    }
  }
  for (NSUInteger i = 0; i < nObj; i++) {
    float dx = fabsf(point.x - objs[i].x);
    if (dx < thrX && dx < bestDX) {
      bestDX = dx;
      snapX = objs[i].x;
      xFromObj = YES;
    }
    float dy = fabsf(point.y - objs[i].y);
    if (dy < thrY && dy < bestDY) {
      bestDY = dy;
      snapY = objs[i].y;
      yFromObj = YES;
    }
  }

  if (bestDX < FLT_MAX) {
    _snappedX = YES;
    _snapValueX = snapX;
    _snapXFromObject = xFromObj;
    point.x = snapX;
  }
  if (bestDY < FLT_MAX) {
    _snappedY = YES;
    _snapValueY = snapY;
    _snapYFromObject = yFromObj;
    point.y = snapY;
  }
  return point;
}

- (void)drawSnapGuidesWithOSC:(KKOnScreenControl *)osc
                isObjectSpace:(BOOL)isObjectSpace
                  canvasColor:(simd_float4)canvasColor
                  objectColor:(simd_float4)objectColor
             destinationImage:(FxImageTile *)destinationImage {
  if (!_snappedX && !_snappedY)
    return;
  CGPoint bl = [osc canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint tr = [osc canvasPointFromObjectPoint:(simd_float2){1, 1}];
  float minX = fmin(bl.x, tr.x), maxX = fmax(bl.x, tr.x);
  float minY = fmin(bl.y, tr.y), maxY = fmax(bl.y, tr.y);
  if (_snappedX) {
    float cx = _snapValueX;
    if (isObjectSpace) {
      CGPoint c =
          [osc canvasPointFromObjectPoint:(simd_float2){_snapValueX, 0}];
      cx = (float)c.x;
    }
    [osc drawLineFrom:(CGPoint){cx, minY}
                      to:(CGPoint){cx, maxY}
                   color:(_snapXFromObject ? objectColor : canvasColor)halfWidth
                        :2.0f
        destinationImage:destinationImage];
  }
  if (_snappedY) {
    float cy = _snapValueY;
    if (isObjectSpace) {
      CGPoint c =
          [osc canvasPointFromObjectPoint:(simd_float2){0, _snapValueY}];
      cy = (float)c.y;
    }
    [osc drawLineFrom:(CGPoint){minX, cy}
                      to:(CGPoint){maxX, cy}
                   color:(_snapYFromObject ? objectColor : canvasColor)halfWidth
                        :2.0f
        destinationImage:destinationImage];
  }
}

- (void)reset {
  _snappedX = NO;
  _snappedY = NO;
  _snapXFromObject = NO;
  _snapYFromObject = NO;
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
