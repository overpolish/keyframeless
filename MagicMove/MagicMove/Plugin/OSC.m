/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"
#import <CoreGraphics/CGEventSource.h>

@interface KKArcOSC (FxOSC) <FxOnScreenControl_v4>
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMoveOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;

    KKCompoundPointOSC *p =
        [[KKCompoundPointOSC alloc] initWithAPIManager:apiManager
                                             labelText:@"Point"
                                            primaryArc:self];
    p.pointParam = kParamPoint;
    p.rotParam = kParamRotation;
    p.rotXParam = kParamRotationX;
    p.rotYParam = kParamRotationY;
    p.scaleXParam = kParamScale;
    p.scaleYParam = kParamScaleY;
    p.opacityParam = kParamOpacity;
    p.arcPart = kOSCArcPart;
    p.ringPart = kOSCRingPart;
    p.rotPart = kOSCRotPart;
    p.rotXRingPart = kOSCRotXRingPart;
    p.rotYRingPart = kOSCRotYRingPart;
    p.opacityIconPart = kOSCOpacityIconPart;
    p.scaleIconPart = kOSCScaleIconPart;
    self.point = p;

    self.anchorOSC = [[KKSquarePointOSC alloc] initWithAPIManager:apiManager];
    self.anchorOSC.clearsOnDraw = NO;
    self.anchorSnap = [[KKSnapEngine alloc] init];
    self.pointSnap = [[KKSnapEngine alloc] init];
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
  return [self canvasPositionForParam:kParamPoint atTime:time];
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  if ([self.point mouseDownWithParentOSC:self
                               positionX:positionX
                               positionY:positionY
                              activePart:activePart
                             forceUpdate:forceUpdate
                                  atTime:time])
    return;

  if (activePart == kOSCAnchorPart) {
    self.anchorDragging = YES;
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
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
          {0.5f, 0.5f},        {0.0f, 0.0f},        {1.0f, 0.0f},
          {0.0f, 1.0f},        {1.0f, 1.0f},        {0.5f, 0.0f},
          {1.0f, 0.5f},        {0.5f, 1.0f},        {0.0f, 0.5f},
          {1.0f / 3.0f, 0.0f}, {2.0f / 3.0f, 0.0f}, {1.0f / 3.0f, 1.0f},
          {2.0f / 3.0f, 1.0f}, {0.0f, 1.0f / 3.0f}, {0.0f, 2.0f / 3.0f},
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

  CGPoint dummySnap = CGPointZero;
  if ([self.point mouseDraggedWithParentOSC:self
                                 snapEngine:self.pointSnap
                                snapTargets:&dummySnap
                                  snapCount:0
                                  positionX:positionX
                                  positionY:positionY
                                 activePart:activePart
                                     atTime:time]) {
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
  [self.pointSnap reset];
  [self.anchorSnap reset];
  self.anchorDragging = NO;
  self.anchorHovered = NO;
  [self.point resetDragState];
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

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  NSInteger prePart = *activePart;

  [self.point hitTestWithParentOSC:self
                         positionX:positionX
                         positionY:positionY
                        activePart:activePart
                            atTime:time];

  self.anchorHovered = NO;
  if (*activePart == prePart) {
    CGPoint anchorCanvas = [self canvasPositionForParam:kParamAnchorPoint
                                                 atTime:time];
    double adx = positionX - anchorCanvas.x;
    double ady = positionY - anchorCanvas.y;
    if (fmax(fabs(adx), fabs(ady)) < [self.anchorOSC hitRadius]) {
      self.anchorHovered = YES;
      *activePart = kOSCAnchorPart;
    }
  }
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

  [self.pointSnap drawSnapGuidesWithOSC:self
                          isObjectSpace:NO
                       destinationImage:destinationImage];
  [self.anchorSnap drawSnapGuidesWithOSC:self
                           isObjectSpace:YES
                        destinationImage:destinationImage];

  CGPoint anchorCanvas = [self canvasPositionForParam:kParamAnchorPoint
                                               atTime:time];
  [self.anchorOSC drawAtCanvasPosition:anchorCanvas
                             isHovered:self.anchorHovered
                              isActive:self.anchorDragging
                      destinationImage:destinationImage
                                atTime:time];

  [self.point drawWithParentOSC:self
               destinationImage:destinationImage
                         atTime:time];
}

@end
#pragma clang diagnostic pop
