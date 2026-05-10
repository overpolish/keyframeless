/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
  double _arcDragStartParamX, _arcDragStartParamY;
  double _arcCanvasToParamX, _arcCanvasToParamY;
  double _ringDragStartDist, _ringDragStartAngle;
  double _ringDragStartValX, _ringDragStartValY;
  NSTimeInterval _ringLastClickTime;
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
  id<FxParameterRetrievalAPI_v6> api =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

  double posX = 0.5, posY = 0.5;
  [api getXValue:&posX YValue:&posY fromParameter:kParamPosition atTime:time];

  if (!oscAPI)
    return CGPointZero;

  double cx = 0, cy = 0;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:posX
                          fromY:posY
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&cx
                            toY:&cy];
  return CGPointMake(cx, cy);
}

- (CGPoint)canvasCenter {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return CGPointZero;
  double cx = 0, cy = 0;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0.5
                          fromY:0.5
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&cx
                            toY:&cy];
  return CGPointMake(cx, cy);
}

- (void)updateRingAtTime:(CMTime)time {
  float minDim = [self canvasMinDimension];
  float sx = [self floatValueForParam:kParamRadiusX atTime:time];
  float sy = [self floatValueForParam:kParamRadiusY atTime:time];
  _radiusRing.ringRadius = minDim * 0.012f * sqrtf(sx);
  _radiusRing.ringRadiusY = minDim * 0.012f * sqrtf(sy);
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  [KKPlugin multiStageDrawOSCTickForAPI:self.apiManager atTime:time];
  [KKPlugin colorSyncFromParams:self.apiManager];

  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  BOOL offsetVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                      label:@"Position"];
  BOOL radiusVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                      label:@"Radius"];

  if (offsetVisible)
    [_offsetSnap drawSnapGuidesWithOSC:self
                         isObjectSpace:NO
                      destinationImage:destinationImage];

  CGPoint offsetPos = [self oscPositionAtTime:time];
  CGPoint ringCenter = [self canvasCenter];
  [self updateRingAtTime:time];

  _radiusRing.center = ringCenter;
  if (radiusVisible)
    [_radiusRing drawAtCanvasPosition:ringCenter
                            isHovered:_ringHovered
                             isActive:_ringDragging
                     destinationImage:destinationImage
                               atTime:time];

  if (offsetVisible)
    [self drawAtCanvasPosition:offsetPos
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

  if ([KKPlugin multiStageOSCVisibleForAPI:self.apiManager label:@"Position"]) {
    CGPoint offsetPos = [self oscPositionAtTime:time];
    double dx = positionX - offsetPos.x;
    double dy = positionY - offsetPos.y;
    if (sqrt(dx * dx + dy * dy) < self.hitRadius) {
      _arcHovered = YES;
      *activePart = kOSCPositionPart;
    }
  }

  if ([KKPlugin multiStageOSCVisibleForAPI:self.apiManager label:@"Radius"]) {
    [self updateRingAtTime:time];
    _radiusRing.center = [self canvasCenter];
    if ([_radiusRing hitTestAtMousePositionX:positionX
                                   positionY:positionY
                                      atTime:time]) {
      _ringHovered = YES;
      *activePart = kOSCRadiusPart;
    }
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
    // Double-click: reset aspect ratio to 1:1
    NSTimeInterval now = CACurrentMediaTime();
    if ((now - _ringLastClickTime) < 0.35) {
      id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      double sx = 100, sy = 100;
      [paramGetAPI getFloatValue:&sx fromParameter:kParamRadiusX atTime:time];
      [paramGetAPI getFloatValue:&sy fromParameter:kParamRadiusY atTime:time];
      if (sx != sy) {
        double smaller = fmin(sx, sy);
        id<FxParameterSettingAPI_v5> paramSetAPI = [self.apiManager
            apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
        if (paramSetAPI) {
          [paramSetAPI setFloatValue:smaller
                         toParameter:kParamRadiusX
                              atTime:time];
          [paramSetAPI setFloatValue:smaller
                         toParameter:kParamRadiusY
                              atTime:time];
        }
        *forceUpdate = YES;
      }
      _ringLastClickTime = 0;
      return;
    }
    _ringLastClickTime = now;

    _ringDragging = YES;
    CGPoint center = [self canvasCenter];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    _ringDragStartDist = sqrt(dx * dx + dy * dy);
    _ringDragStartAngle = atan2(fabs(dy), fabs(dx));

    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    double sx = 100, sy = 100;
    [paramGetAPI getFloatValue:&sx fromParameter:kParamRadiusX atTime:time];
    [paramGetAPI getFloatValue:&sy fromParameter:kParamRadiusY atTime:time];
    _ringDragStartValX = sx;
    _ringDragStartValY = sy;

    [_radiusRing updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCPositionPart) {
    _arcDragging = YES;
    _arcDragStartX = positionX;
    _arcDragStartY = positionY;

    // Capture canvas→param scale at drag start (stable during drag).
    double c0x, c0y, c1x, c1y;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                            fromX:positionX
                            fromY:positionY
                          toSpace:kFxDrawingCoordinates_OBJECT
                              toX:&c0x
                              toY:&c0y];
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                            fromX:positionX + 100
                            fromY:positionY + 100
                          toSpace:kFxDrawingCoordinates_OBJECT
                              toX:&c1x
                              toY:&c1y];
    _arcCanvasToParamX = (c1x - c0x) / 100.0;
    _arcCanvasToParamY = (c1y - c0y) / 100.0;

    // Jump glow to mouse position on click (absolute object-space).
    _arcDragStartParamX = c0x;
    _arcDragStartParamY = c0y;

    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI) {
      [paramSetAPI setXValue:_arcDragStartParamX
                      YValue:_arcDragStartParamY
                 toParameter:kParamPosition
                      atTime:time];
    }

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
    CGPoint center = [self canvasCenter];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    double dist = sqrt(dx * dx + dy * dy);
    if (_ringDragStartDist > 0) {
      double ratio = dist / _ringDragStartDist;
      id<FxParameterSettingAPI_v5> paramSetAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      CGEventFlags flags =
          CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
      BOOL shiftHeld = (flags & kCGEventFlagMaskShift) != 0;
      if (shiftHeld) {
        BOOL horizontal = _ringDragStartAngle < M_PI / 4.0;
        if (paramSetAPI) {
          if (horizontal)
            [paramSetAPI
                setFloatValue:CLAMP(_ringDragStartValX * ratio, 0.0, 500.0)
                  toParameter:kParamRadiusX
                       atTime:time];
          else
            [paramSetAPI
                setFloatValue:CLAMP(_ringDragStartValY * ratio, 0.0, 500.0)
                  toParameter:kParamRadiusY
                       atTime:time];
        }
      } else {
        if (paramSetAPI) {
          [paramSetAPI
              setFloatValue:CLAMP(_ringDragStartValX * ratio, 0.0, 500.0)
                toParameter:kParamRadiusX
                     atTime:time];
          [paramSetAPI
              setFloatValue:CLAMP(_ringDragStartValY * ratio, 0.0, 500.0)
                toParameter:kParamRadiusY
                     atTime:time];
        }
      }
    }
    [_radiusRing updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCPositionPart) {
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

    double deltaX = snapped.x - _arcDragStartX;
    double deltaY = snapped.y - _arcDragStartY;
    double newPosX = _arcDragStartParamX + deltaX * _arcCanvasToParamX;
    double newPosY = _arcDragStartParamY + deltaY * _arcCanvasToParamY;

    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI) {
      [paramSetAPI setXValue:newPosX
                      YValue:newPosY
                 toParameter:kParamPosition
                      atTime:time];
    }
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
