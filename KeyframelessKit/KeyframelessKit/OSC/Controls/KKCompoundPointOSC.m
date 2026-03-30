/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKCompoundPointOSC.h"
#import "../Base/KKOnScreenControl+CoordinateSpace.h"
#import <CoreGraphics/CGEventSource.h>
#import <FxPlug/FxPlugSDK.h>
#import <QuartzCore/QuartzCore.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

@implementation KKCompoundPointOSC {
  BOOL _arcHovered;
  BOOL _ringHovered;
  BOOL _rotHovered;
  double _rotDragPrevAngle, _rotDragAccum;
  double _ringDragStartDist, _ringDragStartValX, _ringDragStartValY;
  double _ringDragStartAngle;
  double _ringLastClickTime;
  double _arcDragStartX, _arcDragStartY;
  id<PROAPIAccessing> _apiManager;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                         labelText:(NSString *)labelText
                        primaryArc:(KKArcOSC *)primaryArc {
  self = [super init];
  if (self) {
    _apiManager = apiManager;

    if (primaryArc) {
      _arc = primaryArc;
      _isPrimaryArc = YES;
    } else {
      _arc = [[KKArcOSC alloc] initWithAPIManager:apiManager];
      _arc.clearsOnDraw = NO;
      _isPrimaryArc = NO;
    }

    _label = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    _label.text = labelText;
    _ring = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    _rot = [[KKRotationOSC alloc] initWithAPIManager:apiManager];
    _previewIcon = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _previewIcon.iconName = @"eye";
    _opacityIcon = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _opacityIcon.iconName = @"circle.fill";
    _scaleIcon = [[KKIconButtonOSC alloc] initWithAPIManager:apiManager];
    _scaleIcon.iconName = @"squareshape.fill";
  }
  return self;
}

- (void)updateRing:(KKOnScreenControl *)parentOSC atTime:(CMTime)time {
  float minDim = [parentOSC canvasMinDimension];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double sx = 1.0, sy = 1.0;
  [paramGetAPI getFloatValue:&sx fromParameter:_scaleXParam atTime:time];
  [paramGetAPI getFloatValue:&sy fromParameter:_scaleYParam atTime:time];
  _ring.ringRadius = minDim * 0.1f * (float)sx;
  _ring.ringRadiusY = minDim * 0.1f * (float)sy;
}

- (void)drawWithParentOSC:(KKOnScreenControl *)parentOSC
         destinationImage:(FxImageTile *)dest
                   atTime:(CMTime)time {
  if (_hidden)
    return;

  CGPoint pos = [parentOSC canvasPositionForParam:_pointParam atTime:time];
  [self updateRing:parentOSC atTime:time];
  float rotAngle = [parentOSC floatValueForParam:_rotParam atTime:time];

  _ring.center = pos;
  [_ring drawAtCanvasPosition:pos
                    isHovered:_ringHovered
                     isActive:_ringDragging
             destinationImage:dest
                       atTime:time];

  _rot.center = pos;
  _rot.angle = rotAngle;
  [_rot drawAtCanvasPosition:pos
                   isHovered:_rotHovered
                    isActive:_rotDragging
            destinationImage:dest
                      atTime:time];

  [_arc drawAtCanvasPosition:pos
                   isHovered:_arcHovered
                    isActive:_arcDragging
            destinationImage:dest
                      atTime:time];

  float arcOuter = _arc.oscRadius + _arc.outlineWidth;
  CGPoint labelPos =
      CGPointMake(pos.x, pos.y - arcOuter - 4.0f - _label.size.height / 2.0f);
  [_label drawAtCanvasPosition:labelPos destinationImage:dest];

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL previewOn = NO;
  [paramGetAPI getBoolValue:&previewOn fromParameter:_previewParam atTime:time];
  _previewIcon.iconName = previewOn ? @"eye.fill" : @"eye";

  double opacity = 1.0;
  [paramGetAPI getFloatValue:&opacity fromParameter:_opacityParam atTime:time];
  if (opacity >= 1.0)
    _opacityIcon.iconName = @"circle.fill";
  else if (opacity <= 0.0)
    _opacityIcon.iconName = @"circle";
  else
    _opacityIcon.iconName =
        @"circle.lefthalf.filled.righthalf.striped.horizontal.inverse";

  double scaleX = 1.0, scaleY = 1.0;
  [paramGetAPI getFloatValue:&scaleX fromParameter:_scaleXParam atTime:time];
  [paramGetAPI getFloatValue:&scaleY fromParameter:_scaleYParam atTime:time];
  double scale = fmax(scaleX, scaleY);
  if (scale > 1.0)
    _scaleIcon.iconName = @"squareshape.dotted.squareshape";
  else if (scale == 1.0)
    _scaleIcon.iconName = @"squareshape.fill";
  else if (scale <= 0.0)
    _scaleIcon.iconName = @"squareshape";
  else
    _scaleIcon.iconName = @"squareshape.squareshape.dotted";

  float gap = 6.0f;
  float totalWidth = _previewIcon.size.width + gap + _opacityIcon.size.width +
                     gap + _scaleIcon.size.width;
  float iconY = pos.y + arcOuter + 4.0f + _previewIcon.size.height / 2.0f;
  float iconX = pos.x - totalWidth / 2.0f;
  CGPoint previewPos =
      CGPointMake(iconX + _previewIcon.size.width / 2.0f, iconY);
  CGPoint opacityPos = CGPointMake(iconX + _previewIcon.size.width + gap +
                                       _opacityIcon.size.width / 2.0f,
                                   iconY);
  CGPoint scalePos = CGPointMake(iconX + _previewIcon.size.width + gap +
                                     _opacityIcon.size.width + gap +
                                     _scaleIcon.size.width / 2.0f,
                                 iconY);
  [_previewIcon drawAtCanvasPosition:previewPos destinationImage:dest];
  [_opacityIcon drawAtCanvasPosition:opacityPos destinationImage:dest];
  [_scaleIcon drawAtCanvasPosition:scalePos destinationImage:dest];

  _arc.fillAlpha = (opacity < 1.0) ? 0.25f : 1.0f;
}

- (void)hitTestWithParentOSC:(KKOnScreenControl *)parentOSC
                   positionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger *)activePart
                      atTime:(CMTime)time {
  _arcHovered = NO;
  _ringHovered = NO;
  _rotHovered = NO;
  if (_hidden)
    return;

  CGPoint pos = [parentOSC canvasPositionForParam:_pointParam atTime:time];

  float arcOuter = _arc.oscRadius + _arc.outlineWidth;
  float gap = 6.0f;
  float totalWidth = _previewIcon.size.width + gap + _opacityIcon.size.width +
                     gap + _scaleIcon.size.width;
  float iconY = pos.y + arcOuter + 4.0f + _previewIcon.size.height / 2.0f;
  float iconX = pos.x - totalWidth / 2.0f;
  CGPoint previewCenter =
      CGPointMake(iconX + _previewIcon.size.width / 2.0f, iconY);
  CGPoint opacityCenter = CGPointMake(iconX + _previewIcon.size.width + gap +
                                          _opacityIcon.size.width / 2.0f,
                                      iconY);
  CGPoint scaleCenter = CGPointMake(iconX + _previewIcon.size.width + gap +
                                        _opacityIcon.size.width + gap +
                                        _scaleIcon.size.width / 2.0f,
                                    iconY);

  if ([_previewIcon hitTestAtMousePositionX:positionX
                                  positionY:positionY
                                     center:previewCenter]) {
    *activePart = _iconPart;
    return;
  }
  if ([_opacityIcon hitTestAtMousePositionX:positionX
                                  positionY:positionY
                                     center:opacityCenter]) {
    *activePart = _opacityIconPart;
    return;
  }
  if ([_scaleIcon hitTestAtMousePositionX:positionX
                                positionY:positionY
                                   center:scaleCenter]) {
    *activePart = _scaleIconPart;
    return;
  }

  {
    double dx = positionX - pos.x;
    double dy = positionY - pos.y;
    if (sqrt(dx * dx + dy * dy) < _arc.hitRadius) {
      _arcHovered = YES;
      *activePart = _arcPart;
    }
  }

  _ring.center = pos;
  [self updateRing:parentOSC atTime:time];
  if ([_ring hitTestAtMousePositionX:positionX
                           positionY:positionY
                              atTime:time]) {
    _ringHovered = YES;
    *activePart = _ringPart;
  }

  _rot.center = pos;
  _rot.angle = [parentOSC floatValueForParam:_rotParam atTime:time];
  if ([_rot hitTestAtMousePositionX:positionX
                          positionY:positionY
                             atTime:time]) {
    _rotHovered = YES;
    *activePart = _rotPart;
  }
}

- (BOOL)mouseDownWithParentOSC:(KKOnScreenControl *)parentOSC
                     positionX:(double)positionX
                     positionY:(double)positionY
                    activePart:(NSInteger)activePart
                   forceUpdate:(BOOL *)forceUpdate
                        atTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [_apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

  if (activePart == _iconPart) {
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    BOOL previewOn = NO;
    [paramGetAPI getBoolValue:&previewOn
                fromParameter:_previewParam
                       atTime:time];
    [paramSetAPI setBoolValue:!previewOn toParameter:_previewParam atTime:time];
    *forceUpdate = YES;
    return YES;
  }

  if (activePart == _opacityIconPart) {
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    double opacity = 1.0;
    [paramGetAPI getFloatValue:&opacity
                 fromParameter:_opacityParam
                        atTime:time];
    [paramSetAPI setFloatValue:(opacity >= 1.0) ? 0.0 : 1.0
                   toParameter:_opacityParam
                        atTime:time];
    *forceUpdate = YES;
    return YES;
  }

  if (activePart == _scaleIconPart) {
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    double sx = 1.0, sy = 1.0;
    [paramGetAPI getFloatValue:&sx fromParameter:_scaleXParam atTime:time];
    [paramGetAPI getFloatValue:&sy fromParameter:_scaleYParam atTime:time];
    double newVal = (fmax(sx, sy) >= 1.0) ? 0.0 : 1.0;
    [paramSetAPI setFloatValue:newVal toParameter:_scaleXParam atTime:time];
    [paramSetAPI setFloatValue:newVal toParameter:_scaleYParam atTime:time];
    *forceUpdate = YES;
    return YES;
  }

  if (activePart == _rotPart) {
    _rotDragging = YES;
    CGPoint center = [parentOSC canvasPositionForParam:_pointParam atTime:time];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    _rotDragPrevAngle = atan2(-dy, dx);
    _rotDragAccum = [parentOSC floatValueForParam:_rotParam atTime:time];
    [oscAPI setCursor:[NSCursor crosshairCursor]];
    *forceUpdate = YES;
    return YES;
  }

  if (activePart == _ringPart) {
    NSTimeInterval now = CACurrentMediaTime();
    if ((now - _ringLastClickTime) < 0.35) {
      id<FxParameterRetrievalAPI_v6> paramGetAPI =
          [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      double sx = 1.0, sy = 1.0;
      [paramGetAPI getFloatValue:&sx fromParameter:_scaleXParam atTime:time];
      [paramGetAPI getFloatValue:&sy fromParameter:_scaleYParam atTime:time];
      if (sx != sy) {
        double smaller = fmin(sx, sy);
        id<FxParameterSettingAPI_v5> paramSetAPI =
            [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
        if (paramSetAPI) {
          [paramSetAPI setFloatValue:smaller
                         toParameter:_scaleXParam
                              atTime:time];
          [paramSetAPI setFloatValue:smaller
                         toParameter:_scaleYParam
                              atTime:time];
        }
        *forceUpdate = YES;
      }
      _ringLastClickTime = 0;
      return YES;
    }
    _ringLastClickTime = now;

    _ringDragging = YES;
    CGPoint center = [parentOSC canvasPositionForParam:_pointParam atTime:time];
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    _ringDragStartDist = sqrt(dx * dx + dy * dy);
    _ringDragStartAngle = atan2(fabs(dy), fabs(dx));
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    double sx = 1.0, sy = 1.0;
    [paramGetAPI getFloatValue:&sx fromParameter:_scaleXParam atTime:time];
    [paramGetAPI getFloatValue:&sy fromParameter:_scaleYParam atTime:time];
    _ringDragStartValX = sx;
    _ringDragStartValY = sy;
    [_ring updateCursorForMouseX:positionX positionY:positionY];
    *forceUpdate = YES;
    return YES;
  }

  if (activePart == _arcPart) {
    _arcDragging = YES;
    _arcDragStartX = positionX;
    _arcDragStartY = positionY;
    [oscAPI setCursor:[NSCursor openHandCursor]];
    *forceUpdate = YES;
    return YES;
  }

  return NO;
}

- (BOOL)mouseDraggedWithParentOSC:(KKOnScreenControl *)parentOSC
                       snapEngine:(KKSnapEngine *)snapEngine
                      snapTargets:(const CGPoint *)snapTargets
                        snapCount:(NSUInteger)snapCount
                        positionX:(double)positionX
                        positionY:(double)positionY
                       activePart:(NSInteger)activePart
                           atTime:(CMTime)time {
  CGPoint center = [parentOSC canvasPositionForParam:_pointParam atTime:time];

  if (activePart == _rotPart) {
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
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI)
      [paramSetAPI setFloatValue:_rotDragAccum
                     toParameter:_rotParam
                          atTime:time];
    return YES;
  }

  if (activePart == _ringPart) {
    double dx = positionX - center.x;
    double dy = positionY - center.y;
    double dist = sqrt(dx * dx + dy * dy);
    if (_ringDragStartDist > 0) {
      double ratio = dist / _ringDragStartDist;
      id<FxParameterSettingAPI_v5> paramSetAPI =
          [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      CGEventFlags flags =
          CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
      BOOL shiftHeld = (flags & kCGEventFlagMaskShift) != 0;
      if (shiftHeld) {
        BOOL horizontal = _ringDragStartAngle < M_PI / 4.0;
        if (paramSetAPI) {
          if (horizontal)
            [paramSetAPI
                setFloatValue:CLAMP(_ringDragStartValX * ratio, 0.0, 10.0)
                  toParameter:_scaleXParam
                       atTime:time];
          else
            [paramSetAPI
                setFloatValue:CLAMP(_ringDragStartValY * ratio, 0.0, 10.0)
                  toParameter:_scaleYParam
                       atTime:time];
        }
      } else {
        if (paramSetAPI) {
          [paramSetAPI
              setFloatValue:CLAMP(_ringDragStartValX * ratio, 0.0, 10.0)
                toParameter:_scaleXParam
                     atTime:time];
          [paramSetAPI
              setFloatValue:CLAMP(_ringDragStartValY * ratio, 0.0, 10.0)
                toParameter:_scaleYParam
                     atTime:time];
        }
      }
    }
    [_ring updateCursorForMouseX:positionX positionY:positionY];
    return YES;
  }

  if (activePart == _arcPart) {
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

    id<FxOnScreenControlAPI_v4> oscAPI =
        [_apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    if (!oscAPI)
      return YES;

    CGPoint canvasCenter;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:0.5
                            fromY:0.5
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&canvasCenter.x
                              toY:&canvasCenter.y];

    CGEventFlags ctrlFlags =
        CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    BOOL ctrlHeld = (ctrlFlags & kCGEventFlagMaskControl) != 0;

    if (!ctrlHeld) {
      NSUInteger allCount = snapCount + 1;
      CGPoint *allTargets = alloca(allCount * sizeof(CGPoint));
      allTargets[0] = canvasCenter;
      memcpy(allTargets + 1, snapTargets, snapCount * sizeof(CGPoint));

      CGPoint snapped =
          [snapEngine snapCanvasPoint:(CGPoint){positionX, positionY}
                            toTargets:allTargets
                                count:allCount];
      positionX = snapped.x;
      positionY = snapped.y;
    } else {
      [snapEngine reset];
    }

    double objX, objY;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                            fromX:positionX
                            fromY:positionY
                          toSpace:kFxDrawingCoordinates_OBJECT
                              toX:&objX
                              toY:&objY];
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI)
      [paramSetAPI setXValue:objX
                      YValue:objY
                 toParameter:_pointParam
                      atTime:time];
    return YES;
  }

  return NO;
}

- (void)resetDragState {
  _arcDragging = NO;
  _arcHovered = NO;
  _ringDragging = NO;
  _ringHovered = NO;
  _rotDragging = NO;
  _rotHovered = NO;
}

@end
