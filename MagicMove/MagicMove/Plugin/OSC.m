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
#define kPointCount 4

typedef struct {
  UInt32 pointParam, rotParam, scaleParam;
  NSInteger arcPart, ringPart, rotPart;
  __unsafe_unretained KKArcOSC *arc;
  __unsafe_unretained KKOSCLabel *label;
  __unsafe_unretained KKRingOSC *ring;
  __unsafe_unretained KKRotationOSC *rot;
  BOOL arcHovered, arcDragging;
  BOOL ringHovered, ringDragging;
  BOOL rotHovered, rotDragging;
  double rotDragPrevAngle, rotDragAccum;
  double ringDragStartDist, ringDragStartVal;
} PointOSCState;

static const float kSnapThreshold = 8.0f;

@implementation MagicMoveOSC {
  PointOSCState _points[kPointCount];
  KKOSCLabel *_labelA;
  KKRingOSC *_ringA;
  KKRotationOSC *_rotA;
  KKArcOSC *_arcB;
  KKOSCLabel *_labelB;
  KKRingOSC *_ringB;
  KKRotationOSC *_rotB;
  KKArcOSC *_arcDrift;
  KKOSCLabel *_labelDrift;
  KKRingOSC *_ringDrift;
  KKRotationOSC *_rotDrift;
  KKArcOSC *_arcExit;
  KKOSCLabel *_labelExit;
  KKRingOSC *_ringExit;
  KKRotationOSC *_rotExit;
  BOOL _snapX;
  BOOL _snapY;
  float _snapXVal;
  float _snapYVal;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;

    _labelA = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    _labelA.text = @"Point A";
    _ringA = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rotA = [[KKRotationOSC alloc] initWithAPIManager:apiManager];

    _arcB = [[KKArcOSC alloc] initWithAPIManager:apiManager];
    _arcB.clearsOnDraw = NO;
    _labelB = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    _labelB.text = @"Point B";
    _ringB = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rotB = [[KKRotationOSC alloc] initWithAPIManager:apiManager];

    _points[0] = (PointOSCState){
        .pointParam = kParamPointA,
        .rotParam = kParamRotationA,
        .scaleParam = kParamScaleA,
        .arcPart = 1,
        .ringPart = 2,
        .rotPart = 3,
        .arc = self,
        .label = _labelA,
        .ring = _ringA,
        .rot = _rotA,
    };
    _points[1] = (PointOSCState){
        .pointParam = kParamPointB,
        .rotParam = kParamRotationB,
        .scaleParam = kParamScaleB,
        .arcPart = 4,
        .ringPart = 5,
        .rotPart = 6,
        .arc = _arcB,
        .label = _labelB,
        .ring = _ringB,
        .rot = _rotB,
    };

    _arcDrift = [[KKArcOSC alloc] initWithAPIManager:apiManager];
    _arcDrift.clearsOnDraw = NO;
    _labelDrift = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    _labelDrift.text = @"Drift";
    _ringDrift = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rotDrift = [[KKRotationOSC alloc] initWithAPIManager:apiManager];

    _points[2] = (PointOSCState){
        .pointParam = kParamDriftPoint,
        .rotParam = kParamDriftRotation,
        .scaleParam = kParamDriftScale,
        .arcPart = 7,
        .ringPart = 8,
        .rotPart = 9,
        .arc = _arcDrift,
        .label = _labelDrift,
        .ring = _ringDrift,
        .rot = _rotDrift,
    };

    _arcExit = [[KKArcOSC alloc] initWithAPIManager:apiManager];
    _arcExit.clearsOnDraw = NO;
    _labelExit = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    _labelExit.text = @"Exit";
    _ringExit = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rotExit = [[KKRotationOSC alloc] initWithAPIManager:apiManager];

    _points[3] = (PointOSCState){
        .pointParam = kParamExitPoint,
        .rotParam = kParamExitRotation,
        .scaleParam = kParamExitScale,
        .arcPart = 10,
        .ringPart = 11,
        .rotPart = 12,
        .arc = _arcExit,
        .label = _labelExit,
        .ring = _ringExit,
        .rot = _rotExit,
    };
  }
  return self;
}

- (CGPoint)positionForParam:(UInt32)paramID atTime:(CMTime)time {
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

- (float)rotationForParam:(UInt32)paramID atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return 0.0f;
  double radians = 0.0;
  [paramGetAPI getFloatValue:&radians fromParameter:paramID atTime:time];
  return (float)radians;
}

- (float)canvasMinDim {
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

- (float)ringRadiusForScaleParam:(UInt32)paramID atTime:(CMTime)time {
  float minDim = [self canvasMinDim];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double scale = 1.0;
  [paramGetAPI getFloatValue:&scale fromParameter:paramID atTime:time];
  return minDim * 0.1f * (float)scale;
}

- (BOOL)animateInEnabledAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled
              fromParameter:kKKParamAnimateIn
                     atTime:time];
  return enabled;
}

- (BOOL)animateOutEnabledAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled
              fromParameter:kKKParamAnimateOut
                     atTime:time];
  return enabled;
}

- (BOOL)driftEnabledAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled fromParameter:kParamDrift atTime:time];
  return enabled;
}

- (BOOL)exitEnabledAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled fromParameter:kParamExit atTime:time];
  return enabled;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  return [self positionForParam:kParamPointA atTime:time];
}

- (void)drawPoint:(PointOSCState *)pt
    destinationImage:(FxImageTile *)dest
              atTime:(CMTime)time {
  CGPoint pos = [self positionForParam:pt->pointParam atTime:time];
  float ringRadius = [self ringRadiusForScaleParam:pt->scaleParam atTime:time];
  float rotAngle = [self rotationForParam:pt->rotParam atTime:time];

  pt->ring.center = pos;
  pt->ring.ringRadius = ringRadius;
  [pt->ring drawAtCanvasPosition:pos
                       isHovered:pt->ringHovered
                        isActive:pt->ringDragging
                destinationImage:dest
                          atTime:time];

  pt->rot.center = pos;
  pt->rot.angle = rotAngle;
  [pt->rot drawAtCanvasPosition:pos
                      isHovered:pt->rotHovered
                       isActive:pt->rotDragging
               destinationImage:dest
                         atTime:time];

  [pt->arc drawAtCanvasPosition:pos
                      isHovered:pt->arcHovered
                       isActive:pt->arcDragging
               destinationImage:dest
                         atTime:time];

  float arcOuter = pt->arc.oscRadius + pt->arc.outlineWidth;
  CGPoint labelPos = CGPointMake(pos.x, pos.y - arcOuter - 4.0f -
                                            pt->label.size.height / 2.0f);
  [pt->label drawAtCanvasPosition:labelPos destinationImage:dest];
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

  BOOL animInOn = [self animateInEnabledAtTime:time];
  BOOL animOutOn = [self animateOutEnabledAtTime:time];
  BOOL driftOn = [self driftEnabledAtTime:time];
  BOOL exitOn = [self exitEnabledAtTime:time];
  BOOL showA = animInOn || (animOutOn && !exitOn);
  BOOL showExit = exitOn && animOutOn;

  CGPoint posB = [self positionForParam:kParamPointB atTime:time];
  simd_float4 red = {1, 0, 0, 1};
  BOOL anyArcActive = _points[0].arcDragging || _points[1].arcDragging ||
                      _points[2].arcDragging || _points[3].arcDragging;
  double inset = anyArcActive ? 22.0 : 14.0;

  if (showA) {
    CGPoint posA = [self positionForParam:kParamPointA atTime:time];
    double ldx = posB.x - posA.x, ldy = posB.y - posA.y;
    double len = hypot(ldx, ldy);
    if (len > inset * 2.0) {
      double nx = ldx / len * inset, ny = ldy / len * inset;
      [self drawLineFrom:(CGPoint){posA.x + nx, posA.y + ny}
                        to:(CGPoint){posB.x - nx, posB.y - ny}
                     color:red
                 halfWidth:2.0f
          destinationImage:destinationImage];
    }
  }

  if (driftOn) {
    CGPoint posD = [self positionForParam:kParamDriftPoint atTime:time];
    double d2x = posD.x - posB.x, d2y = posD.y - posB.y;
    double l2 = hypot(d2x, d2y);
    if (l2 > inset * 2.0) {
      double n2x = d2x / l2 * inset, n2y = d2y / l2 * inset;
      [self drawLineFrom:(CGPoint){posB.x + n2x, posB.y + n2y}
                        to:(CGPoint){posD.x - n2x, posD.y - n2y}
                     color:red
                 halfWidth:2.0f
          destinationImage:destinationImage];
    }
    if (showExit) {
      CGPoint posE = [self positionForParam:kParamExitPoint atTime:time];
      double d3x = posE.x - posD.x, d3y = posE.y - posD.y;
      double l3 = hypot(d3x, d3y);
      if (l3 > inset * 2.0) {
        double n3x = d3x / l3 * inset, n3y = d3y / l3 * inset;
        [self drawLineFrom:(CGPoint){posD.x + n3x, posD.y + n3y}
                          to:(CGPoint){posE.x - n3x, posE.y - n3y}
                       color:red
                   halfWidth:2.0f
            destinationImage:destinationImage];
      }
    }
  } else if (showExit) {
    CGPoint posE = [self positionForParam:kParamExitPoint atTime:time];
    double d2x = posE.x - posB.x, d2y = posE.y - posB.y;
    double l2 = hypot(d2x, d2y);
    if (l2 > inset * 2.0) {
      double n2x = d2x / l2 * inset, n2y = d2y / l2 * inset;
      [self drawLineFrom:(CGPoint){posB.x + n2x, posB.y + n2y}
                        to:(CGPoint){posE.x - n2x, posE.y - n2y}
                     color:red
                 halfWidth:2.0f
          destinationImage:destinationImage];
    }
  }

  if (_snapX || _snapY) {
    CGPoint topRight, bottomLeft;
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:0.0
                            fromY:0.0
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&bottomLeft.x
                              toY:&bottomLeft.y];
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:1.0
                            fromY:1.0
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&topRight.x
                              toY:&topRight.y];
    float minX = fmin(bottomLeft.x, topRight.x);
    float maxX = fmax(bottomLeft.x, topRight.x);
    float minY = fmin(bottomLeft.y, topRight.y);
    float maxY = fmax(bottomLeft.y, topRight.y);
    simd_float4 yellow = {1, 1, 0, 1};
    if (_snapX) {
      [self drawLineFrom:(CGPoint){_snapXVal, minY}
                        to:(CGPoint){_snapXVal, maxY}
                     color:yellow
                 halfWidth:2.0f
          destinationImage:destinationImage];
    }
    if (_snapY) {
      [self drawLineFrom:(CGPoint){minX, _snapYVal}
                        to:(CGPoint){maxX, _snapYVal}
                     color:yellow
                 halfWidth:2.0f
          destinationImage:destinationImage];
    }
  }

  if (showA)
    [self drawPoint:&_points[0] destinationImage:destinationImage atTime:time];
  [self drawPoint:&_points[1] destinationImage:destinationImage atTime:time];

  if (driftOn)
    [self drawPoint:&_points[2] destinationImage:destinationImage atTime:time];

  if (showExit)
    [self drawPoint:&_points[3] destinationImage:destinationImage atTime:time];
}

- (void)hitTestPoint:(PointOSCState *)pt
           positionX:(double)positionX
           positionY:(double)positionY
          activePart:(NSInteger *)activePart
              atTime:(CMTime)time {
  pt->arcHovered = NO;
  pt->ringHovered = NO;
  pt->rotHovered = NO;

  CGPoint pos = [self positionForParam:pt->pointParam atTime:time];

  if (pt->arc == self) {
    [super hitTestOSCAtMousePositionX:positionX
                       mousePositionY:positionY
                           activePart:activePart
                               atTime:time];
  } else {
    double dx = positionX - pos.x;
    double dy = positionY - pos.y;
    if (sqrt(dx * dx + dy * dy) < pt->arc.hitRadius) {
      pt->arcHovered = YES;
      *activePart = pt->arcPart;
    }
  }

  pt->ring.center = pos;
  pt->ring.ringRadius = [self ringRadiusForScaleParam:pt->scaleParam
                                               atTime:time];
  if ([pt->ring hitTestAtMousePositionX:positionX
                              positionY:positionY
                                 atTime:time]) {
    pt->ringHovered = YES;
    *activePart = pt->ringPart;
  }

  pt->rot.center = pos;
  pt->rot.angle = [self rotationForParam:pt->rotParam atTime:time];
  if ([pt->rot hitTestAtMousePositionX:positionX
                             positionY:positionY
                                atTime:time]) {
    pt->rotHovered = YES;
    *activePart = pt->rotPart;
  }
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  BOOL animInOn = [self animateInEnabledAtTime:time];
  BOOL animOutOn = [self animateOutEnabledAtTime:time];
  BOOL exitOn = [self exitEnabledAtTime:time];

  if (animInOn || (animOutOn && !exitOn))
    [self hitTestPoint:&_points[0]
             positionX:positionX
             positionY:positionY
            activePart:activePart
                atTime:time];

  [self hitTestPoint:&_points[1]
           positionX:positionX
           positionY:positionY
          activePart:activePart
              atTime:time];

  if ([self driftEnabledAtTime:time])
    [self hitTestPoint:&_points[2]
             positionX:positionX
             positionY:positionY
            activePart:activePart
                atTime:time];

  if (exitOn && animOutOn)
    [self hitTestPoint:&_points[3]
             positionX:positionX
             positionY:positionY
            activePart:activePart
                atTime:time];
}

- (BOOL)mouseDownForPoint:(PointOSCState *)pt
                positionX:(double)positionX
                positionY:(double)positionY
               activePart:(NSInteger)activePart
              forceUpdate:(BOOL *)forceUpdate
                   atTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

  if (activePart == pt->rotPart) {
    pt->rotDragging = YES;
    CGPoint center = [self positionForParam:pt->pointParam atTime:time];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    pt->rotDragPrevAngle = atan2(-dy, dx);
    pt->rotDragAccum = [self rotationForParam:pt->rotParam atTime:time];
    [oscAPI setCursor:[NSCursor crosshairCursor]];
    *forceUpdate = YES;
    return YES;
  }

  if (activePart == pt->ringPart) {
    pt->ringDragging = YES;
    CGPoint center = [self positionForParam:pt->pointParam atTime:time];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    pt->ringDragStartDist = sqrt(dx * dx + dy * dy);
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    double s = 1.0;
    [paramGetAPI getFloatValue:&s fromParameter:pt->scaleParam atTime:time];
    pt->ringDragStartVal = s;
    [pt->ring updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
    return YES;
  }

  if (activePart == pt->arcPart) {
    pt->arcDragging = YES;
    if (pt->arc == self) {
      [super mouseDownAtPositionX:positionX
                        positionY:positionY
                       activePart:activePart
                        modifiers:0
                      forceUpdate:forceUpdate
                           atTime:time];
    }
    [oscAPI setCursor:[NSCursor openHandCursor]];
    *forceUpdate = YES;
    return YES;
  }

  return NO;
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  for (int i = 0; i < kPointCount; i++) {
    if ([self mouseDownForPoint:&_points[i]
                      positionX:positionX
                      positionY:positionY
                     activePart:activePart
                    forceUpdate:forceUpdate
                         atTime:time])
      return;
  }
  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
}

- (void)setPositionParam:(UInt32)paramID
                   fromX:(double)canvasX
                       Y:(double)canvasY
              snapTarget:(CGPoint)snapTarget
                  atTime:(CMTime)time {
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

  double distPointX = fabs(canvasX - snapTarget.x);
  double distCenterX = fabs(canvasX - canvasCenter.x);
  double distPointY = fabs(canvasY - snapTarget.y);
  double distCenterY = fabs(canvasY - canvasCenter.y);

  _snapX = NO;
  _snapY = NO;

  if (distPointX < kSnapThreshold && distPointX <= distCenterX) {
    _snapX = YES;
    canvasX = snapTarget.x;
    _snapXVal = (float)snapTarget.x;
  } else if (distCenterX < kSnapThreshold) {
    _snapX = YES;
    canvasX = canvasCenter.x;
    _snapXVal = (float)canvasCenter.x;
  }

  if (distPointY < kSnapThreshold && distPointY <= distCenterY) {
    _snapY = YES;
    canvasY = snapTarget.y;
    _snapYVal = (float)snapTarget.y;
  } else if (distCenterY < kSnapThreshold) {
    _snapY = YES;
    canvasY = canvasCenter.y;
    _snapYVal = (float)canvasCenter.y;
  }

  double objX, objY;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:canvasX
                          fromY:canvasY
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&objX
                            toY:&objY];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (paramSetAPI)
    [paramSetAPI setXValue:objX YValue:objY toParameter:paramID atTime:time];
}

- (BOOL)mouseDraggedForPoint:(PointOSCState *)pt
                  snapTarget:(CGPoint)snapTarget
                   positionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                      atTime:(CMTime)time {
  CGPoint center = [self positionForParam:pt->pointParam atTime:time];

  if (activePart == pt->rotPart) {
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    double angle = atan2(-dy, dx);
    double delta = angle - pt->rotDragPrevAngle;
    if (delta > M_PI)
      delta -= 2.0 * M_PI;
    else if (delta < -M_PI)
      delta += 2.0 * M_PI;
    pt->rotDragAccum += delta;
    pt->rotDragPrevAngle = angle;
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI)
      [paramSetAPI setFloatValue:pt->rotDragAccum
                     toParameter:pt->rotParam
                          atTime:time];
    return YES;
  }

  if (activePart == pt->ringPart) {
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    double dist = sqrt(dx * dx + dy * dy);
    if (pt->ringDragStartDist > 0) {
      double newVal = CLAMP(
          pt->ringDragStartVal * (dist / pt->ringDragStartDist), 0.0, 10.0);
      id<FxParameterSettingAPI_v5> paramSetAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      if (paramSetAPI)
        [paramSetAPI setFloatValue:newVal
                       toParameter:pt->scaleParam
                            atTime:time];
    }
    [pt->ring updateCursorForMouseX:positionX positionY:positionY];
    return YES;
  }

  if (activePart == pt->arcPart) {
    [self setPositionParam:pt->pointParam
                     fromX:positionX
                         Y:positionY
                snapTarget:snapTarget
                    atTime:time];
    return YES;
  }

  return NO;
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  for (int i = 0; i < kPointCount; i++) {
    CGPoint snapTarget =
        [self positionForParam:_points[(i + 1) % kPointCount].pointParam
                        atTime:time];
    if ([self mouseDraggedForPoint:&_points[i]
                        snapTarget:snapTarget
                         positionX:positionX
                         positionY:positionY
                        activePart:activePart
                            atTime:time]) {
      *forceUpdate = YES;
      return;
    }
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
  _snapX = NO;
  _snapY = NO;
  for (int i = 0; i < kPointCount; i++) {
    _points[i].arcDragging = NO;
    _points[i].arcHovered = NO;
    _points[i].ringDragging = NO;
    _points[i].ringHovered = NO;
    _points[i].rotDragging = NO;
    _points[i].rotHovered = NO;
  }
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
