/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import "Constants.h"
#import <CoreGraphics/CGEventSource.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKSquarePointOSC.h>
#import <QuartzCore/QuartzCore.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

@interface KKArcOSC (FxOSC) <FxOnScreenControl_v4>
@end

@implementation MagicMoveOSC {
  KKRingOSC *_scaleRing;
  KKRotationOSC *_rot;
  KKRingOSC *_rotXRing;
  KKRingOSC *_rotYRing;
  KKIconButtonOSC *_opacityIcon;
  KKIconButtonOSC *_scaleIcon;
  KKSquarePointOSC *_anchorOSC;
  KKSnapEngine *_positionSnap;
  KKSnapEngine *_anchorSnap;

  BOOL _arcHovered, _arcDragging;
  double _arcDragStartX, _arcDragStartY;

  BOOL _scaleRingHovered, _scaleRingDragging;
  double _scaleDragStartDist, _scaleDragStartAngle;
  double _scaleDragStartValX, _scaleDragStartValY;
  NSTimeInterval _scaleLastClickTime;

  BOOL _rotHovered, _rotDragging;
  double _rotDragPrevAngle, _rotDragAccum;
  UInt32 _rotDragTargetParam;

  BOOL _rotXRingHovered, _rotXRingDragging;
  BOOL _rotYRingHovered, _rotYRingDragging;
  double _rotRingDragPrevPos;

  BOOL _anchorHovered, _anchorDragging;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;

    _scaleRing = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _scaleRing.clearsOnDraw = NO;

    _rot = [[KKRotationOSC alloc] initWithAPIManager:apiManager];

    _rotXRing = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rotXRing.tintColor = [NSColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:1];
    _rotXRing.ringRadius = 70.0f;
    _rotXRing.ringRadiusY = 40.0f;
    _rotXRing.fillWidth = 3.0f;
    _rotXRing.hoverCursor = [NSCursor resizeLeftRightCursor];

    _rotYRing = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rotYRing.tintColor = [NSColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:1];
    _rotYRing.ringRadius = 40.0f;
    _rotYRing.ringRadiusY = 70.0f;
    _rotYRing.fillWidth = 3.0f;
    _rotYRing.hoverCursor = [NSCursor resizeUpDownCursor];

    _opacityIcon = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _opacityIcon.iconName = @"circle.fill";
    _scaleIcon = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _scaleIcon.iconName = @"squareshape.fill";

    _anchorOSC = [[KKSquarePointOSC alloc] initWithAPIManager:apiManager];
    _anchorOSC.clearsOnDraw = NO;

    _positionSnap = [[KKSnapEngine alloc] init];
    _anchorSnap = [[KKSnapEngine alloc] init];
  }
  return self;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  return [self canvasPositionForParam:kParamPoint atTime:time];
}

- (CGPoint)canvasCenter {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return CGPointZero;
  CGPoint c = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0.5
                          fromY:0.5
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&c.x
                            toY:&c.y];
  return c;
}

- (void)updateScaleRingAtTime:(CMTime)time {
  float minDim = [self canvasMinDimension];
  double sx = 1.0, sy = 1.0;
  id<FxParameterRetrievalAPI_v6> api =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  [api getFloatValue:&sx fromParameter:kParamScale atTime:time];
  [api getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
  _scaleRing.ringRadius = minDim * 0.1f * (float)sx;
  _scaleRing.ringRadiusY = minDim * 0.1f * (float)sy;
}

- (void)layoutCenterIcons:(CGPoint)center
                 arcOuter:(float)arcOuter
                opacityAt:(CGPoint *)outOpacity
                  scaleAt:(CGPoint *)outScale {
  float gap = 6.0f;
  float totalWidth = _opacityIcon.size.width + gap + _scaleIcon.size.width;
  float iconY = center.y + arcOuter + 4.0f + _opacityIcon.size.height / 2.0f;
  float iconX = center.x - totalWidth / 2.0f;
  *outOpacity = CGPointMake(iconX + _opacityIcon.size.width / 2.0f, iconY);
  *outScale = CGPointMake(iconX + _opacityIcon.size.width + gap +
                              _scaleIcon.size.width / 2.0f,
                          iconY);
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  [KKPlugin multiStageDrawOSCTickForAPI:self.apiManager atTime:time];

  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  [_positionSnap drawSnapGuidesWithOSC:self
                         isObjectSpace:NO
                      destinationImage:destinationImage];
  [_anchorSnap drawSnapGuidesWithOSC:self
                       isObjectSpace:YES
                    destinationImage:destinationImage];

  CGPoint center = [self canvasCenter];
  CGPoint posPos = [self oscPositionAtTime:time];

  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optHeld = (flags & kCGEventFlagMaskAlternate) != 0;

  BOOL positionVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                        label:@"Position"];
  BOOL scaleVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                     label:@"Scale"];
  BOOL rotZVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                    label:@"Rotation Z"];
  BOOL rotXVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                    label:@"Rotation X"];
  BOOL rotYVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                    label:@"Rotation Y"];
  BOOL opacityVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                       label:@"Opacity"];

  BOOL rotXEnabled =
      rotXVisible || optHeld || _rotXRingDragging || _rotXRingHovered;
  BOOL rotYEnabled =
      rotYVisible || optHeld || _rotYRingDragging || _rotYRingHovered;
  BOOL showRotX = rotXEnabled;
  BOOL showRotY = rotYEnabled;

  if (scaleVisible) {
    [self updateScaleRingAtTime:time];
    _scaleRing.center = center;
    [_scaleRing drawAtCanvasPosition:center
                           isHovered:_scaleRingHovered
                            isActive:_scaleRingDragging
                    destinationImage:destinationImage
                              atTime:time];
  }

  if (rotZVisible) {
    float rotAngle = [self floatValueForParam:kParamRotation atTime:time];
    _rot.center = center;
    _rot.angle = rotAngle;
    [_rot drawAtCanvasPosition:center
                     isHovered:_rotHovered
                      isActive:_rotDragging
              destinationImage:destinationImage
                        atTime:time];
  }

  if (showRotX) {
    _rotXRing.center = center;
    [_rotXRing drawAtCanvasPosition:center
                          isHovered:_rotXRingHovered
                           isActive:_rotXRingDragging
                   destinationImage:destinationImage
                             atTime:time];
  }

  if (showRotY) {
    _rotYRing.center = center;
    [_rotYRing drawAtCanvasPosition:center
                          isHovered:_rotYRingHovered
                           isActive:_rotYRingDragging
                   destinationImage:destinationImage
                             atTime:time];
  }

  // Update icon glyphs based on opacity / scale.
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double opacity = 1.0;
  [paramGetAPI getFloatValue:&opacity fromParameter:kParamOpacity atTime:time];
  if (opacity >= 1.0)
    _opacityIcon.iconName = @"circle.fill";
  else if (opacity <= 0.0)
    _opacityIcon.iconName = @"circle";
  else
    _opacityIcon.iconName =
        @"circle.lefthalf.filled.righthalf.striped.horizontal.inverse";

  double sx = 1.0, sy = 1.0;
  [paramGetAPI getFloatValue:&sx fromParameter:kParamScale atTime:time];
  [paramGetAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
  double scale = fmax(sx, sy);
  if (scale > 1.0)
    _scaleIcon.iconName = @"squareshape.dotted.squareshape";
  else if (scale == 1.0)
    _scaleIcon.iconName = @"squareshape.fill";
  else if (scale <= 0.0)
    _scaleIcon.iconName = @"squareshape";
  else
    _scaleIcon.iconName = @"squareshape.squareshape.dotted";

  float arcOuter = self.oscRadius + self.outlineWidth;
  CGPoint opacityCenter, scaleCenter;
  [self layoutCenterIcons:center
                 arcOuter:arcOuter
                opacityAt:&opacityCenter
                  scaleAt:&scaleCenter];
  if (opacityVisible)
    [_opacityIcon drawAtCanvasPosition:opacityCenter
                      destinationImage:destinationImage];
  if (scaleVisible)
    [_scaleIcon drawAtCanvasPosition:scaleCenter
                    destinationImage:destinationImage];

  // Position handle follows the position param.
  if (positionVisible) {
    self.fillAlpha = (opacity < 1.0) ? 0.25f : 1.0f;
    [self drawAtCanvasPosition:posPos
                     isHovered:_arcHovered
                      isActive:_arcDragging
              destinationImage:destinationImage
                        atTime:time];
  }

  // Anchor square is independent.
  CGPoint anchorCanvas = [self canvasPositionForParam:kParamAnchorPoint
                                               atTime:time];
  [_anchorOSC drawAtCanvasPosition:anchorCanvas
                         isHovered:_anchorHovered
                          isActive:_anchorDragging
                  destinationImage:destinationImage
                            atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  _arcHovered = NO;
  _scaleRingHovered = NO;
  _rotHovered = NO;
  _rotXRingHovered = NO;
  _rotYRingHovered = NO;
  _anchorHovered = NO;

  CGPoint center = [self canvasCenter];
  float arcOuter = self.oscRadius + self.outlineWidth;
  CGPoint opacityCenter, scaleCenter;
  [self layoutCenterIcons:center
                 arcOuter:arcOuter
                opacityAt:&opacityCenter
                  scaleAt:&scaleCenter];

  BOOL positionVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                        label:@"Position"];
  BOOL scaleVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                     label:@"Scale"];
  BOOL rotZVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                    label:@"Rotation Z"];
  BOOL rotXVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                    label:@"Rotation X"];
  BOOL rotYVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                    label:@"Rotation Y"];
  BOOL opacityVisible = [KKPlugin multiStageOSCVisibleForAPI:self.apiManager
                                                       label:@"Opacity"];

  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optHeld = (flags & kCGEventFlagMaskAlternate) != 0;

  if (opacityVisible && [_opacityIcon hitTestAtMousePositionX:positionX
                                                    positionY:positionY
                                                       center:opacityCenter]) {
    *activePart = kOSCOpacityIconPart;
    return;
  }
  if (scaleVisible && [_scaleIcon hitTestAtMousePositionX:positionX
                                                positionY:positionY
                                                   center:scaleCenter]) {
    *activePart = kOSCScaleIconPart;
    return;
  }

  // Anchor.
  CGPoint anchorCanvas = [self canvasPositionForParam:kParamAnchorPoint
                                               atTime:time];
  if (fmax(fabs(positionX - anchorCanvas.x), fabs(positionY - anchorCanvas.y)) <
      [_anchorOSC hitRadius]) {
    _anchorHovered = YES;
    *activePart = kOSCAnchorPart;
    return;
  }

  // Rotation X/Y rings — interactive when their lane is on, or Opt held.
  if (rotXVisible || optHeld) {
    _rotXRing.center = center;
    if ([_rotXRing hitTestAtMousePositionX:positionX
                                 positionY:positionY
                                    atTime:time]) {
      _rotXRingHovered = YES;
      *activePart = kOSCRotXRingPart;
      return;
    }
  }
  if (rotYVisible || optHeld) {
    _rotYRing.center = center;
    if ([_rotYRing hitTestAtMousePositionX:positionX
                                 positionY:positionY
                                    atTime:time]) {
      _rotYRingHovered = YES;
      *activePart = kOSCRotYRingPart;
      return;
    }
  }

  if (scaleVisible) {
    [self updateScaleRingAtTime:time];
    _scaleRing.center = center;
    if ([_scaleRing hitTestAtMousePositionX:positionX
                                  positionY:positionY
                                     atTime:time]) {
      _scaleRingHovered = YES;
      *activePart = kOSCScaleRingPart;
      return;
    }
  }

  if (rotZVisible) {
    _rot.center = center;
    _rot.angle = [self floatValueForParam:kParamRotation atTime:time];
    if ([_rot hitTestAtMousePositionX:positionX
                            positionY:positionY
                               atTime:time]) {
      _rotHovered = YES;
      *activePart = kOSCRotPart;
      return;
    }
  }

  // Position arc.
  if (positionVisible) {
    CGPoint posPos = [self oscPositionAtTime:time];
    double dx = positionX - posPos.x;
    double dy = positionY - posPos.y;
    if (sqrt(dx * dx + dy * dy) < self.hitRadius) {
      _arcHovered = YES;
      *activePart = kOSCPositionPart;
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
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  if (activePart == kOSCOpacityIconPart) {
    double opacity = 1.0;
    [paramGetAPI getFloatValue:&opacity
                 fromParameter:kParamOpacity
                        atTime:time];
    [paramSetAPI setFloatValue:(opacity >= 1.0) ? 0.0 : 1.0
                   toParameter:kParamOpacity
                        atTime:time];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCScaleIconPart) {
    double sx = 1.0, sy = 1.0;
    [paramGetAPI getFloatValue:&sx fromParameter:kParamScale atTime:time];
    [paramGetAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
    double newVal = (fmax(sx, sy) >= 1.0) ? 0.0 : 1.0;
    [paramSetAPI setFloatValue:newVal toParameter:kParamScale atTime:time];
    [paramSetAPI setFloatValue:newVal toParameter:kParamScaleY atTime:time];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCAnchorPart) {
    _anchorDragging = YES;
    [oscAPI setCursor:[NSCursor openHandCursor]];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCRotPart) {
    _rotDragging = YES;
    _rotDragTargetParam = kParamRotation;
    CGPoint center = [self canvasCenter];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    _rotDragPrevAngle = atan2(-dy, dx);
    _rotDragAccum = [self floatValueForParam:_rotDragTargetParam atTime:time];
    [oscAPI setCursor:[NSCursor crosshairCursor]];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCRotXRingPart || activePart == kOSCRotYRingPart) {
    if (activePart == kOSCRotXRingPart) {
      _rotXRingDragging = YES;
      _rotDragTargetParam = kParamRotationY;
      _rotRingDragPrevPos = positionX;
    } else {
      _rotYRingDragging = YES;
      _rotDragTargetParam = kParamRotationX;
      _rotRingDragPrevPos = positionY;
    }
    _rotDragAccum = [self floatValueForParam:_rotDragTargetParam atTime:time];
    [oscAPI setCursor:[NSCursor crosshairCursor]];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCScaleRingPart) {
    NSTimeInterval now = CACurrentMediaTime();
    if ((now - _scaleLastClickTime) < 0.35) {
      double sx = 1.0, sy = 1.0;
      [paramGetAPI getFloatValue:&sx fromParameter:kParamScale atTime:time];
      [paramGetAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
      if (sx != sy) {
        double smaller = fmin(sx, sy);
        [paramSetAPI setFloatValue:smaller toParameter:kParamScale atTime:time];
        [paramSetAPI setFloatValue:smaller
                       toParameter:kParamScaleY
                            atTime:time];
        *forceUpdate = YES;
      }
      _scaleLastClickTime = 0;
      return;
    }
    _scaleLastClickTime = now;

    _scaleRingDragging = YES;
    CGPoint center = [self canvasCenter];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    _scaleDragStartDist = sqrt(dx * dx + dy * dy);
    _scaleDragStartAngle = atan2(fabs(dy), fabs(dx));
    double sx = 1.0, sy = 1.0;
    [paramGetAPI getFloatValue:&sx fromParameter:kParamScale atTime:time];
    [paramGetAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
    _scaleDragStartValX = sx;
    _scaleDragStartValY = sy;
    [_scaleRing updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCPositionPart) {
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
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  if (activePart == kOSCAnchorPart) {
    double objX, objY;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                            fromX:positionX
                            fromY:positionY
                          toSpace:kFxDrawingCoordinates_OBJECT
                              toX:&objX
                              toY:&objY];
    simd_float2 pos = {(float)objX, (float)objY};

    CGEventFlags flags =
        CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    BOOL snapDisabled = (flags & kCGEventFlagMaskAlternate) != 0;
    if (!snapDisabled) {
      static const simd_float2 kAnchorTargets[] = {
          {0.5f, 0.5f},        {0.0f, 0.0f},        {1.0f, 0.0f},
          {0.0f, 1.0f},        {1.0f, 1.0f},        {0.5f, 0.0f},
          {1.0f, 0.5f},        {0.5f, 1.0f},        {0.0f, 0.5f},
          {1.0f / 3.0f, 0.0f}, {2.0f / 3.0f, 0.0f}, {1.0f / 3.0f, 1.0f},
          {2.0f / 3.0f, 1.0f}, {0.0f, 1.0f / 3.0f}, {0.0f, 2.0f / 3.0f},
          {1.0f, 1.0f / 3.0f}, {1.0f, 2.0f / 3.0f},
      };
      static const NSUInteger kCount =
          sizeof(kAnchorTargets) / sizeof(kAnchorTargets[0]);
      CGPoint c0 = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
      CGPoint c1 = [self canvasPointFromObjectPoint:(simd_float2){1, 0}];
      float pixPerUnit = (float)fabs(c1.x - c0.x);
      pos = [_anchorSnap snapObjectPoint:pos
                               toTargets:kAnchorTargets
                                   count:kCount
                           pixelsPerUnit:pixPerUnit];
    } else {
      [_anchorSnap reset];
    }

    [paramSetAPI setXValue:pos.x
                    YValue:pos.y
               toParameter:kParamAnchorPoint
                    atTime:time];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCRotXRingPart || activePart == kOSCRotYRingPart) {
    double pos = (activePart == kOSCRotXRingPart) ? positionX : positionY;
    double delta = (pos - _rotRingDragPrevPos) * (M_PI / 200.0);
    if (activePart == kOSCRotYRingPart)
      delta = -delta;
    _rotRingDragPrevPos = pos;
    _rotDragAccum += delta;
    static const double kSnapToZero = 3.0 * (M_PI / 180.0);
    double value = _rotDragAccum;
    if (fabs(value) < kSnapToZero)
      value = 0.0;
    [paramSetAPI setFloatValue:value
                   toParameter:_rotDragTargetParam
                        atTime:time];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCRotPart) {
    CGPoint center = [self canvasCenter];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    double angle = atan2(-dy, dx);
    double delta = angle - _rotDragPrevAngle;
    if (delta > M_PI)
      delta -= 2.0 * M_PI;
    else if (delta < -M_PI)
      delta += 2.0 * M_PI;
    _rotDragAccum += delta;
    _rotDragPrevAngle = angle;
    static const double kSnapToZero = 3.0 * (M_PI / 180.0);
    double value = _rotDragAccum;
    if (fabs(value) < kSnapToZero)
      value = 0.0;
    [paramSetAPI setFloatValue:value
                   toParameter:_rotDragTargetParam
                        atTime:time];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCScaleRingPart) {
    CGPoint center = [self canvasCenter];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    double dist = sqrt(dx * dx + dy * dy);
    if (_scaleDragStartDist > 0) {
      double ratio = dist / _scaleDragStartDist;
      CGEventFlags flags =
          CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
      BOOL shiftHeld = (flags & kCGEventFlagMaskShift) != 0;
      if (shiftHeld) {
        BOOL horizontal = _scaleDragStartAngle < M_PI / 4.0;
        if (horizontal)
          [paramSetAPI
              setFloatValue:CLAMP(_scaleDragStartValX * ratio, 0.0, 10.0)
                toParameter:kParamScale
                     atTime:time];
        else
          [paramSetAPI
              setFloatValue:CLAMP(_scaleDragStartValY * ratio, 0.0, 10.0)
                toParameter:kParamScaleY
                     atTime:time];
      } else {
        [paramSetAPI setFloatValue:CLAMP(_scaleDragStartValX * ratio, 0.0, 10.0)
                       toParameter:kParamScale
                            atTime:time];
        [paramSetAPI setFloatValue:CLAMP(_scaleDragStartValY * ratio, 0.0, 10.0)
                       toParameter:kParamScaleY
                            atTime:time];
      }
    }
    [_scaleRing updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
    return;
  }

  if (activePart == kOSCPositionPart) {
    CGEventFlags flags =
        CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    if (flags & kCGEventFlagMaskShift) {
      double dx = fabs(positionX - _arcDragStartX);
      double dy = fabs(positionY - _arcDragStartY);
      if (dx > dy)
        positionY = _arcDragStartY;
      else
        positionX = _arcDragStartX;
    }

    CGPoint canvasCenter = [self canvasCenter];
    BOOL ctrlHeld = (flags & kCGEventFlagMaskControl) != 0;

    if (!ctrlHeld) {
      CGPoint thirds[4];
      double tx, ty;
      [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                              fromX:1.0 / 3.0
                              fromY:0.5
                            toSpace:kFxDrawingCoordinates_CANVAS
                                toX:&tx
                                toY:&ty];
      thirds[0] = (CGPoint){tx, ty};
      [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                              fromX:2.0 / 3.0
                              fromY:0.5
                            toSpace:kFxDrawingCoordinates_CANVAS
                                toX:&tx
                                toY:&ty];
      thirds[1] = (CGPoint){tx, ty};
      [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                              fromX:0.5
                              fromY:1.0 / 3.0
                            toSpace:kFxDrawingCoordinates_CANVAS
                                toX:&tx
                                toY:&ty];
      thirds[2] = (CGPoint){tx, ty};
      [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                              fromX:0.5
                              fromY:2.0 / 3.0
                            toSpace:kFxDrawingCoordinates_CANVAS
                                toX:&tx
                                toY:&ty];
      thirds[3] = (CGPoint){tx, ty};

      CGPoint targets[5] = {canvasCenter, thirds[0], thirds[1], thirds[2],
                            thirds[3]};
      CGPoint snapped =
          [_positionSnap snapCanvasPoint:(CGPoint){positionX, positionY}
                               toTargets:targets
                                   count:5];
      positionX = snapped.x;
      positionY = snapped.y;
    } else {
      [_positionSnap reset];
    }

    double objX, objY;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                            fromX:positionX
                            fromY:positionY
                          toSpace:kFxDrawingCoordinates_OBJECT
                              toX:&objX
                              toY:&objY];
    [paramSetAPI setXValue:objX
                    YValue:objY
               toParameter:kParamPoint
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
  _scaleRingDragging = NO;
  _scaleRingHovered = NO;
  _rotDragging = NO;
  _rotHovered = NO;
  _rotXRingDragging = NO;
  _rotXRingHovered = NO;
  _rotYRingDragging = NO;
  _rotYRingHovered = NO;
  _anchorDragging = NO;
  _anchorHovered = NO;
  [_positionSnap reset];
  [_anchorSnap reset];
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
