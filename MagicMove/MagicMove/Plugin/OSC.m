/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"
#import <CoreGraphics/CGEventSource.h>

@interface KKArcOSC (FxOSC) <FxOnScreenControl_v4>
@end

static KKCompoundPointOSC *makePoint(id<PROAPIAccessing> api, NSString *label,
                                     KKArcOSC *primaryArc, UInt32 pointP,
                                     UInt32 rotP, UInt32 rotXP, UInt32 rotYP,
                                     UInt32 sxP, UInt32 syP, UInt32 prevP,
                                     UInt32 opP, MagicMoveOSCParts parts) {
  KKCompoundPointOSC *p =
      [[KKCompoundPointOSC alloc] initWithAPIManager:api
                                           labelText:label
                                          primaryArc:primaryArc];
  p.pointParam = pointP;
  p.rotParam = rotP;
  p.rotXParam = rotXP;
  p.rotYParam = rotYP;
  p.scaleXParam = sxP;
  p.scaleYParam = syP;
  p.previewParam = prevP;
  p.opacityParam = opP;
  p.arcPart = parts.arc;
  p.ringPart = parts.ring;
  p.rotPart = parts.rot;
  p.rotXRingPart = parts.rotXRing;
  p.rotYRingPart = parts.rotYRing;
  p.iconPart = parts.icon;
  p.opacityIconPart = parts.opacityIcon;
  p.scaleIconPart = parts.scaleIcon;
  return p;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMoveOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;

    self.points = @[
      makePoint(apiManager, @"Point A", self, kParamPointA, kParamRotationA,
                kParamRotationXA, kParamRotationYA, kParamScaleA, kParamScaleYA,
                kParamPreviewA, kParamOpacityA, kOSCPartsA),
      makePoint(apiManager, @"Point B", nil, kParamPointB, kParamRotationB,
                kParamRotationXB, kParamRotationYB, kParamScaleB, kParamScaleYB,
                kParamPreviewB, kParamOpacityB, kOSCPartsB),
      makePoint(apiManager, @"Drift", nil, kParamDriftPoint,
                kParamDriftRotation, kParamDriftRotationX, kParamDriftRotationY,
                kParamDriftScale, kParamDriftScaleY, kParamPreviewDrift,
                kParamDriftOpacity, kOSCPartsDrift),
      makePoint(apiManager, @"Exit", nil, kParamExitPoint, kParamExitRotation,
                kParamExitRotationX, kParamExitRotationY, kParamExitScale,
                kParamExitScaleY, kParamPreviewExit, kParamExitOpacity,
                kOSCPartsExit),
    ];

    self.pathPointOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    self.pathPointOSC.clearsOnDraw = NO;
    self.pathPointOSC.oscRadius = 5.0f;
    self.pathPointOSC.outlineWidth = 1.5f;
    self.pathHandleOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    self.pathHandleOSC.clearsOnDraw = NO;
    self.pathHandleOSC.oscRadius = 3.0f;
    self.pathHandleOSC.outlineWidth = 1.0f;
    self.anchorOSC = [[KKSquarePointOSC alloc] initWithAPIManager:apiManager];
    self.anchorOSC.clearsOnDraw = NO;
    self.anchorSnap = [[KKSnapEngine alloc] init];
    self.pathDragIndex = -1;
    self.pathLastClickIndex = -1;
    self.pointSnap = [[KKSnapEngine alloc] init];
    self.pathSnap = [[KKSnapEngine alloc] init];
  }
  return self;
}

- (BOOL)boolParam:(UInt32)paramID atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled fromParameter:paramID atTime:time];
  return enabled;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  return [self canvasPositionForParam:kParamPointA atTime:time];
}

- (KKBezierPath *)readPathParam:(UInt32)paramID {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:paramID];
  if (str.length > 0) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:str options:0];
    if (data)
      return [KKBezierPath pathWithData:data];
  }
  return [[KKBezierPath alloc] init];
}

- (void)writePathParam:(UInt32)paramID path:(KKBezierPath *)path {
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSData *data = [path dataRepresentation];
  NSString *str = [data base64EncodedStringWithOptions:0];
  [paramSetAPI setStringParameterValue:str toParameter:paramID];
}

- (PathSegConfig)configForPathIndex:(NSInteger)pi {
  switch (pi) {
  case 1:
    return (PathSegConfig){kParamPathBDrift, kParamPointB, kParamDriftPoint, 1};
  case 2:
    return (PathSegConfig){kParamPathDriftExit, kParamDriftPoint,
                           kParamExitPoint, 2};
  case 3:
    return (PathSegConfig){kParamPathBExit, kParamPointB, kParamExitPoint, 3};
  case 4:
    return (PathSegConfig){kParamPathDriftA, kParamDriftPoint, kParamPointA, 4};
  case 5:
    return (PathSegConfig){kParamPathBA, kParamPointB, kParamPointA, 5};
  default:
    return (PathSegConfig){kParamPathAB, kParamPointA, kParamPointB, 0};
  }
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  if (modifiers & kFxModifierKey_COMMAND) {
    static const UInt32 hideParams[] = {kParamHideOSCA, kParamHideOSCB,
                                        kParamHideOSCDrift, kParamHideOSCExit};
    for (int i = 0; i < kPointCount; i++) {
      if (activePart == self.points[i].arcPart) {
        id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager
            apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
        id<FxParameterSettingAPI_v5> paramSetAPI = [self.apiManager
            apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
        BOOL hidden = NO;
        [paramGetAPI getBoolValue:&hidden
                    fromParameter:hideParams[i]
                           atTime:time];
        [paramSetAPI setBoolValue:!hidden
                      toParameter:hideParams[i]
                           atTime:time];
        *forceUpdate = YES;
        return;
      }
    }
  }

  for (int i = 0; i < kPointCount; i++) {
    if ([self.points[i] mouseDownWithParentOSC:self
                                     positionX:positionX
                                     positionY:positionY
                                    activePart:activePart
                                   forceUpdate:forceUpdate
                                        atTime:time])
      return;
  }
  if (activePart == kOSCAnchorPart) {
    self.anchorDragging = YES;
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI setCursor:[NSCursor openHandCursor]];
    *forceUpdate = YES;
    return;
  }
  if ([self mouseDownForPathWithPart:activePart
                           positionX:positionX
                           positionY:positionY
                           modifiers:modifiers
                         forceUpdate:forceUpdate
                              atTime:time])
    return;
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
  if (activePart == kOSCAnchorPart) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    double objX, objY;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                            fromX:positionX
                            fromY:positionY
                          toSpace:kFxDrawingCoordinates_OBJECT
                              toX:&objX
                              toY:&objY];
    simd_float2 pos = {(float)objX, (float)objY};

    CGEventFlags anchorFlags =
        CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    BOOL snapDisabled = (anchorFlags & kCGEventFlagMaskAlternate) != 0;
    if (!snapDisabled) {
      static const simd_float2 kAnchorTargets[] = {
          {0.5f, 0.5f},                      // center
          {0.0f, 0.0f},        {1.0f, 0.0f}, // corners
          {0.0f, 1.0f},        {1.0f, 1.0f},
          {0.5f, 0.0f},        {1.0f, 0.5f}, // edge midpoints
          {0.5f, 1.0f},        {0.0f, 0.5f},
          {1.0f / 3.0f, 0.0f}, {2.0f / 3.0f, 0.0f}, // thirds X
          {1.0f / 3.0f, 1.0f}, {2.0f / 3.0f, 1.0f},
          {0.0f, 1.0f / 3.0f}, {0.0f, 2.0f / 3.0f}, // thirds Y
          {1.0f, 1.0f / 3.0f}, {1.0f, 2.0f / 3.0f},
      };
      static const NSUInteger kAnchorTargetCount =
          sizeof(kAnchorTargets) / sizeof(kAnchorTargets[0]);
      CGPoint c0 = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
      CGPoint c1 = [self canvasPointFromObjectPoint:(simd_float2){1, 0}];
      float pixPerUnit = (float)fabs(c1.x - c0.x);
      pos = [self.anchorSnap snapObjectPoint:pos
                                   toTargets:kAnchorTargets
                                       count:kAnchorTargetCount
                               pixelsPerUnit:pixPerUnit];
    } else {
      [self.anchorSnap reset];
    }

    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI)
      [paramSetAPI setXValue:pos.x
                      YValue:pos.y
                 toParameter:kParamAnchorPoint
                      atTime:time];
    *forceUpdate = YES;
    return;
  }
  if ([self mouseDraggedForPathWithPart:activePart
                              positionX:positionX
                              positionY:positionY
                                 atTime:time]) {
    *forceUpdate = YES;
    return;
  }
  for (int i = 0; i < kPointCount; i++) {
    CGPoint snapTargets[kPointCount - 1];
    NSUInteger snapCount = 0;
    for (int j = 0; j < kPointCount; j++) {
      if (j != i)
        snapTargets[snapCount++] =
            [self canvasPositionForParam:self.points[j].pointParam atTime:time];
    }
    if ([self.points[i] mouseDraggedWithParentOSC:self
                                       snapEngine:self.pointSnap
                                      snapTargets:snapTargets
                                        snapCount:snapCount
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
  [self.pointSnap reset];
  [self.pathSnap reset];
  [self.anchorSnap reset];
  self.anchorDragging = NO;
  self.anchorHovered = NO;
  self.pathDragIndex = -1;
  self.pathDragIsInHandle = NO;
  self.pathDragIsOutHandle = NO;
  for (int i = 0; i < kPointCount; i++) {
    [self.points[i] resetDragState];
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
#pragma clang diagnostic pop
