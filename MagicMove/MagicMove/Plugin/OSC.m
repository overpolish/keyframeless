/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import "Constants.h"
#import <FxPlug/FxPlugSDK.h>

@interface KKArcOSC (FxOSC) <FxOnScreenControl_v4>
@end

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

static BOOL getCenterAndMinDim(id<PROAPIAccessing> apiManager, CGPoint *center,
                               float *minDim) {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return NO;

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

  *center = CGPointMake((topRight.x + bottomLeft.x) / 2.0,
                        (topRight.y + bottomLeft.y) / 2.0);
  *minDim =
      fmin(fabs(topRight.x - bottomLeft.x), fabs(topRight.y - bottomLeft.y));
  return YES;
}

@implementation MagicMoveOSC {
  KKOSCLabel *_label;
  KKRingOSC *_ringOSC;
  KKRotationOSC *_rotationOSC;
  BOOL _ringIsHovered;
  BOOL _ringIsDragging;
  BOOL _rotationIsHovered;
  BOOL _rotationIsDragging;
  double _rotationDragPrevAngle;
  double _rotationDragAccum;
  double _ringDragStartDistance;
  double _ringDragStartValue;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _label = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    _label.text = @"Point A";
    _ringOSC = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rotationOSC = [[KKRotationOSC alloc] initWithAPIManager:apiManager];
  }
  return self;
}

- (float)rotationAngleAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return 0.0f;
  double degrees = 0.0;
  [paramGetAPI getFloatValue:&degrees fromParameter:kParamRotation atTime:time];
  return (float)(degrees * M_PI / 180.0);
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return CGPointZero;

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double x = 0.5, y = 0.5;
  [paramGetAPI getXValue:&x YValue:&y fromParameter:kParamPointA atTime:time];

  CGPoint canvas;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:x
                          fromY:y
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&canvas.x
                            toY:&canvas.y];
  return canvas;
}

- (float)ringRadiusAtTime:(CMTime)time {
  CGPoint center;
  float minDim;
  if (!getCenterAndMinDim(self.apiManager, &center, &minDim))
    return 50.0f;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double scale = 1.0;
  [paramGetAPI getFloatValue:&scale fromParameter:kParamScale atTime:time];
  return minDim * 0.2f * (float)scale;
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  CGPoint position = [self oscPositionAtTime:time];

  [self drawAtCanvasPosition:position
                   isHovered:self.isHovered
                    isActive:self.isDragging
            destinationImage:destinationImage
                      atTime:time];

  float arcOuter = self.oscRadius + self.outlineWidth;
  float labelPadding = 4.0f;
  CGPoint labelPos =
      CGPointMake(position.x, position.y - arcOuter - labelPadding -
                                  _label.size.height / 2.0f);
  [_label drawAtCanvasPosition:labelPos destinationImage:destinationImage];

  _ringOSC.center = position;
  _ringOSC.ringRadius = [self ringRadiusAtTime:time];
  [_ringOSC drawAtCanvasPosition:position
                       isHovered:_ringIsHovered
                        isActive:_ringIsDragging
                destinationImage:destinationImage
                          atTime:time];

  _rotationOSC.center = position;
  _rotationOSC.angle = [self rotationAngleAtTime:time];
  [_rotationOSC drawAtCanvasPosition:position
                           isHovered:_rotationIsHovered
                            isActive:_rotationIsDragging
                    destinationImage:destinationImage
                              atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  _ringIsHovered = NO;
  _rotationIsHovered = NO;

  [super hitTestOSCAtMousePositionX:positionX
                     mousePositionY:positionY
                         activePart:activePart
                             atTime:time];

  _ringOSC.center = [self oscPositionAtTime:time];
  _ringOSC.ringRadius = [self ringRadiusAtTime:time];
  if ([_ringOSC hitTestAtMousePositionX:positionX
                              positionY:positionY
                                 atTime:time]) {
    _ringIsHovered = YES;
    *activePart = 2;
  }

  _rotationOSC.center = [self oscPositionAtTime:time];
  _rotationOSC.angle = [self rotationAngleAtTime:time];
  if ([_rotationOSC hitTestAtMousePositionX:positionX
                                  positionY:positionY
                                     atTime:time]) {
    _rotationIsHovered = YES;
    *activePart = 3;
  }
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  if (activePart == 3) {
    _rotationIsDragging = YES;
    CGPoint center = [self oscPositionAtTime:time];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    _rotationDragPrevAngle = atan2(-dy, dx) * 180.0 / M_PI;
    _rotationDragAccum = [self rotationAngleAtTime:time] * 180.0 / M_PI;
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI setCursor:[NSCursor crosshairCursor]];
    *forceUpdate = YES;
  } else if (activePart == 2) {
    _ringIsDragging = YES;
    CGPoint center = [self oscPositionAtTime:time];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    _ringDragStartDistance = sqrt(dx * dx + dy * dy);
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    double currentScale = 1.0;
    [paramGetAPI getFloatValue:&currentScale
                 fromParameter:kParamScale
                        atTime:time];
    _ringDragStartValue = currentScale;
    [_ringOSC updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
  } else {
    [super mouseDownAtPositionX:positionX
                      positionY:positionY
                     activePart:activePart
                      modifiers:modifiers
                    forceUpdate:forceUpdate
                         atTime:time];
    if (activePart == 1) {
      id<FxOnScreenControlAPI_v4> oscAPI =
          [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
      [oscAPI setCursor:[NSCursor openHandCursor]];
    }
  }
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  if (activePart == 3) {
    CGPoint center = [self oscPositionAtTime:time];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    double currentAngle = atan2(-dy, dx) * 180.0 / M_PI;

    double delta = currentAngle - _rotationDragPrevAngle;
    if (delta > 180.0)
      delta -= 360.0;
    else if (delta < -180.0)
      delta += 360.0;

    _rotationDragAccum += delta;
    _rotationDragPrevAngle = currentAngle;

    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI) {
      [paramSetAPI setFloatValue:_rotationDragAccum
                     toParameter:kParamRotation
                          atTime:time];
    }
    *forceUpdate = YES;
  } else if (activePart == 2) {
    CGPoint center = [self oscPositionAtTime:time];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    double currentDistance = sqrt(dx * dx + dy * dy);
    if (_ringDragStartDistance > 0) {
      double newValue =
          _ringDragStartValue * (currentDistance / _ringDragStartDistance);
      newValue = CLAMP(newValue, 0.0, 10.0);
      id<FxParameterSettingAPI_v5> paramSetAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      if (paramSetAPI) {
        [paramSetAPI setFloatValue:newValue
                       toParameter:kParamScale
                            atTime:time];
      }
    }
    [_ringOSC updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
  } else if (activePart == 1) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    if (oscAPI) {
      double objX, objY;
      [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                              fromX:positionX
                              fromY:positionY
                            toSpace:kFxDrawingCoordinates_OBJECT
                                toX:&objX
                                toY:&objY];
      id<FxParameterSettingAPI_v5> paramSetAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      if (paramSetAPI) {
        [paramSetAPI setXValue:objX
                        YValue:objY
                   toParameter:kParamPointA
                        atTime:time];
      }
    }
    *forceUpdate = YES;
  } else {
    [super mouseDraggedAtPositionX:positionX
                         positionY:positionY
                        activePart:activePart
                         modifiers:modifiers
                       forceUpdate:forceUpdate
                            atTime:time];
  }
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  _ringIsDragging = NO;
  _rotationIsDragging = NO;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  [oscAPI setCursor:[NSCursor arrowCursor]];
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

@end
