/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import "Constants.h"
#import <FxPlug/FxPlugSDK.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

@interface KKArcOSC (FxOSC) <FxOnScreenControl_v4>
@end

@implementation GlowOSC {
  BOOL _arcHovered;
  BOOL _arcDragging;
  BOOL _ringHovered;
  BOOL _ringDragging;
  double _arcDragStartX, _arcDragStartY;
  double _ringDragStartDist, _ringDragStartVal;
  KKSnapEngine *_offsetSnap;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;

    _radiusRing = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _radiusRing.clearsOnDraw = NO;
    _radiusRing.hoverCursor = [NSCursor resizeLeftRightCursor];
    _offsetSnap = [[KKSnapEngine alloc] init];
  }
  return self;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  simd_float2 obj = [self objectPositionForParam:kParamOffset atTime:time];
  return [self
      canvasPointFromObjectPoint:(simd_float2){1.0f - obj.x, 1.0f - obj.y}];
}

- (void)updateRingAtTime:(CMTime)time {
  float minDim = [self canvasMinDimension];
  float radius = [self floatValueForParam:kParamRadius atTime:time];
  float ringPx = minDim * 0.012f * sqrtf(radius);
  _radiusRing.ringRadius = ringPx;
  _radiusRing.ringRadiusY = ringPx;
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  [_offsetSnap drawSnapGuidesWithOSC:self
                       isObjectSpace:NO
                    destinationImage:destinationImage];

  CGPoint center = [self oscPositionAtTime:time];
  [self updateRingAtTime:time];

  _radiusRing.center = center;
  [_radiusRing drawAtCanvasPosition:center
                          isHovered:_ringHovered
                           isActive:_ringDragging
                   destinationImage:destinationImage
                             atTime:time];

  [self drawAtCanvasPosition:center
                   isHovered:_arcHovered
                    isActive:_arcDragging
            destinationImage:destinationImage
                      atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  _arcHovered = NO;
  _ringHovered = NO;

  CGPoint center = [self oscPositionAtTime:time];

  double dx = positionX - center.x;
  double dy = positionY - center.y;
  if (sqrt(dx * dx + dy * dy) < self.hitRadius) {
    _arcHovered = YES;
    *activePart = kOSCOffsetPart;
  }

  [self updateRingAtTime:time];
  _radiusRing.center = center;
  if ([_radiusRing hitTestAtMousePositionX:positionX
                                 positionY:positionY
                                    atTime:time]) {
    _ringHovered = YES;
    *activePart = kOSCRadiusPart;
  }
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

  if (activePart == kOSCRadiusPart) {
    _ringDragging = YES;
    CGPoint center = [self oscPositionAtTime:time];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    _ringDragStartDist = sqrt(dx * dx + dy * dy);
    _ringDragStartVal = [self floatValueForParam:kParamRadius atTime:time];
    [_radiusRing updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCOffsetPart) {
    _arcDragging = YES;
    _arcDragStartX = positionX;
    _arcDragStartY = positionY;
    [oscAPI setCursor:[NSCursor openHandCursor]];
    *forceUpdate = YES;
    return;
  }

  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  if (activePart == kOSCRadiusPart) {
    CGPoint center = [self oscPositionAtTime:time];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    double dist = sqrt(dx * dx + dy * dy);
    if (_ringDragStartDist > 0) {
      double ratio = dist / _ringDragStartDist;
      double newVal = CLAMP(_ringDragStartVal * ratio, 0.0, 500.0);
      id<FxParameterSettingAPI_v5> paramSetAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      if (paramSetAPI)
        [paramSetAPI setFloatValue:newVal toParameter:kParamRadius atTime:time];
    }
    [_radiusRing updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCOffsetPart) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    if (!oscAPI)
      return;

    CGPoint canvasCenter;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:0.5
                            fromY:0.5
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&canvasCenter.x
                              toY:&canvasCenter.y];

    CGPoint snapTargets[] = {canvasCenter};
    CGPoint snapped =
        [_offsetSnap snapCanvasPoint:(CGPoint){positionX, positionY}
                           toTargets:snapTargets
                               count:1];
    positionX = snapped.x;
    positionY = snapped.y;

    double objX, objY;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                            fromX:positionX
                            fromY:positionY
                          toSpace:kFxDrawingCoordinates_OBJECT
                              toX:&objX
                              toY:&objY];
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI)
      [paramSetAPI setXValue:1.0 - objX
                      YValue:1.0 - objY
                 toParameter:kParamOffset
                      atTime:time];
    *forceUpdate = YES;
    return;
  }

  [super mouseDraggedAtPositionX:positionX
                       positionY:positionY
                      activePart:activePart
                       modifiers:modifiers
                     forceUpdate:forceUpdate
                          atTime:time];
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  _arcDragging = NO;
  _arcHovered = NO;
  _ringDragging = NO;
  _ringHovered = NO;
  [_offsetSnap reset];
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
