/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKOnScreenControl+CoordinateSpace.h"
#import <FxPlug/FxPlugSDK.h>

@implementation KKOnScreenControl (KKCoordinateSpace)

- (CGPoint)canvasPointFromObjectPoint:(simd_float2)objectPoint {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  CGPoint canvas;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:objectPoint.x
                          fromY:objectPoint.y
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&canvas.x
                            toY:&canvas.y];
  return canvas;
}

- (simd_float2)objectPointFromCanvasPoint:(CGPoint)canvasPoint {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  double objX, objY;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:canvasPoint.x
                          fromY:canvasPoint.y
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&objX
                            toY:&objY];
  return (simd_float2){(float)objX, (float)objY};
}

- (float)canvasMinDimension {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return 500.0f;
  CGPoint topRight, bottomLeft;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:1.0
                          fromY:1.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&topRight.x
                            toY:&topRight.y];
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0.0
                          fromY:0.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&bottomLeft.x
                            toY:&bottomLeft.y];
  return fmin(fabs(topRight.x - bottomLeft.x), fabs(topRight.y - bottomLeft.y));
}

- (CGPoint)canvasPositionForParam:(UInt32)paramID atTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return CGPointZero;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double x = 0.5, y = 0.5;
  [paramGetAPI getXValue:&x YValue:&y fromParameter:paramID atTime:time];
  CGPoint canvas;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:x
                          fromY:y
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&canvas.x
                            toY:&canvas.y];
  return canvas;
}

- (simd_float2)objectPositionForParam:(UInt32)paramID atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double x = 0.5, y = 0.5;
  [paramGetAPI getXValue:&x YValue:&y fromParameter:paramID atTime:time];
  return (simd_float2){(float)x, (float)y};
}

- (float)floatValueForParam:(UInt32)paramID atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return 0.0f;
  double value = 0.0;
  [paramGetAPI getFloatValue:&value fromParameter:paramID atTime:time];
  return (float)value;
}

@end
