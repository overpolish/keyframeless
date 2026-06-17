/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "OSC_Internal.h"
#import "Plugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <simd/simd.h>

@implementation MagicMoveOSC (MouseHandlers)

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  [self kkResetOptHideArming];
  [self.positionController mouseUp];
  [self.scaleControl mouseUp];
  [self.rotationOSC mouseUp];
  [self.anchorSnap reset];
  self.anchorHovered = NO;
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

- (void)mouseMovedAtPositionX:(double)positionX
                    positionY:(double)positionY
                   activePart:(NSInteger)activePart
                    modifiers:(FxModifierKeys)modifiers
                  forceUpdate:(BOOL *)forceUpdate
                       atTime:(CMTime)time {
  [self kkUpdateOptRevealWithModifiers:modifiers forceUpdate:forceUpdate];
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  if ([self kkArmOptHideForActivePart:activePart modifiers:modifiers]) {
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
  if (activePart == kOSCScalePart) {
    self.scaleControl.center = [self oscPositionAtTime:time];
    self.scaleControl.frameMin = [self _onScreenFrameMin];
    [self.scaleControl mouseDownAtX:positionX
                                  y:positionY
                          modifiers:modifiers
                        forceUpdate:forceUpdate
                             atTime:time];
    return;
  }
  if (activePart == kOSCAnchorPart) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    if (oscAPI) {
      double objX = 0.0, objY = 0.0;
      [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                              fromX:positionX
                              fromY:positionY
                            toSpace:kFxDrawingCoordinates_OBJECT
                                toX:&objX
                                toY:&objY];
      self.anchorPressObject = (simd_float2){(float)objX, (float)objY};
    }
    // Capture the grabbed keypose's anchor value for delta-based dragging.
    double frac = [self _fractionAtTime:time];
    NSArray<NSNumber *> *av = _anchorValuesAtFraction(frac);
    self.anchorGrabValX = av[0].doubleValue;
    self.anchorGrabValY = av[1].doubleValue;
    self.anchorHovered = YES;
    return;
  }
  // Position handle / keypose anchor, and the motion-path tangent handles, are
  // owned by the Position controller (press capture, double-click smooth
  // toggle, grab-value capture all live in there). The hit-test already set
  // hoverTargetIsAnchor on the controller, so map the part to a KKPositionHit.
  if (activePart == kOSCPositionPart || activePart == kOSCPathHandlePart) {
    KKPositionHit hit = (activePart == kOSCPathHandlePart)
                            ? KKPositionHitTangentHandle
                            : (self.positionController.hoverTargetIsAnchor
                                   ? KKPositionHitAnchorDot
                                   : KKPositionHitHandle);
    [self.positionController mouseDownAtX:positionX
                                        y:positionY
                                      hit:hit
                                modifiers:modifiers
                              forceUpdate:forceUpdate
                                   atTime:time];
  }
  if (activePart == kOSCRotationPart) {
    // The shared KKRotationOSC owns press capture (nearest keypose), the
    // smoothed-pose tangent sync, compose/decompose and persistence.
    self.rotationOSC.center = [self oscPositionAtTime:time];
    self.rotationOSC.optRevealActive = self.optRevealActive;
    [self.rotationOSC mouseDownAtX:positionX
                                 y:positionY
                         modifiers:modifiers
                       forceUpdate:forceUpdate
                            atTime:time];
  }
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  // First drag tick decides: opt held => hide-click (handled, no drag).
  if ([self kkArmOptHideForActivePart:activePart modifiers:modifiers]) {
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  if (activePart == kOSCPathHandlePart) {
    [self.positionController mouseDraggedAtX:positionX
                                           y:positionY
                                         hit:KKPositionHitTangentHandle
                                   modifiers:modifiers
                                 forceUpdate:forceUpdate
                                      atTime:time];
    return;
  }
  if (activePart == kOSCRotationPart) {
    [self.rotationOSC mouseDraggedAtX:positionX
                                    y:positionY
                            modifiers:modifiers
                          forceUpdate:forceUpdate
                               atTime:time];
    return;
  }
  if (activePart == kOSCScalePart) {
    self.scaleControl.center = [self oscPositionAtTime:time];
    self.scaleControl.frameMin = [self _onScreenFrameMin];
    [self.scaleControl mouseDraggedAtX:positionX
                                     y:positionY
                             modifiers:modifiers
                           forceUpdate:forceUpdate
                                atTime:time];
    return;
  }
  if (activePart == kOSCAnchorPart) {
    [self _dragAnchorToPositionX:positionX
                       positionY:positionY
                       modifiers:modifiers
                     forceUpdate:forceUpdate
                          atTime:time];
    return;
  }
  if (activePart != kOSCPositionPart)
    return;
  [self.positionController
      mouseDraggedAtX:positionX
                    y:positionY
                  hit:(self.positionController.hoverTargetIsAnchor
                           ? KKPositionHitAnchorDot
                           : KKPositionHitHandle)modifiers:modifiers
          forceUpdate:forceUpdate
               atTime:time];
}

- (void)_dragAnchorToPositionX:(double)positionX
                     positionY:(double)positionY
                     modifiers:(NSUInteger)modifiers
                   forceUpdate:(BOOL *)forceUpdate
                        atTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return;
  double curX = 0.0, curY = 0.0;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:positionX
                          fromY:positionY
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&curX
                            toY:&curY];
  // Delta drag: the anchor value moves by the cursor's object-space offset from
  // the grab point (1 object unit == 1 anchor unit), so grabbing off-centre
  // doesn't jump the pivot to the cursor.
  double newX = self.anchorGrabValX + (curX - (double)self.anchorPressObject.x);
  double newY = self.anchorGrabValY + (curY - (double)self.anchorPressObject.y);

  double frac = [self _fractionAtTime:time];
  NSArray<NSNumber *> *pv = _positionValuesAtFraction(frac);
  double posX = pv[0].doubleValue, posY = pv[1].doubleValue;

  // Snap is OFF by default (free, pixel-precise) and engaged by holding Cmd -
  // same as the Position / Rotation OSCs. Snap targets are the clip's own
  // centre / corners / edge-midpoints / thirds. Snap in the pivot's object
  // space so the guides land on the clip's real features, then convert the
  // snapped pivot back to the anchor value.
  BOOL snapActive = (modifiers & kFxModifierKey_COMMAND) != 0;
  if (snapActive) {
    static const float tg[] = {0.0f, 1.0f / 3.0f, 0.5f, 2.0f / 3.0f, 1.0f};
    simd_float2 targets[25];
    NSUInteger n = 0;
    for (int i = 0; i < 5; i++)
      for (int j = 0; j < 5; j++)
        targets[n++] = (simd_float2){(float)(posX + tg[i] - 0.5),
                                     (float)(posY + tg[j] - 0.5)};
    CGPoint c0 = [self _canvasFromObjX:0 y:0];
    CGPoint c1 = [self _canvasFromObjX:1 y:0];
    float ppu = (float)fabs(c1.x - c0.x);
    simd_float2 pivot = {(float)(posX + newX - 0.5),
                         (float)(posY + newY - 0.5)};
    simd_float2 snapped = [self.anchorSnap snapObjectPoint:pivot
                                                 toTargets:targets
                                                     count:n
                                             pixelsPerUnit:ppu];
    newX = snapped.x - posX + 0.5;
    newY = snapped.y - posY + 0.5;
  } else {
    [self.anchorSnap reset];
  }

  [self _writeAnchorValues:@[ @(newX), @(newY) ]
                    atTime:time
               forceUpdate:forceUpdate];
}

- (void)_writeAnchorValues:(NSArray<NSNumber *> *)newValues
                    atTime:(CMTime)time
               forceUpdate:(BOOL *)forceUpdate {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  [actionAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI) {
    [actionAPI endAction:self];
    return;
  }

  double frac = [self _fractionAtTime:time];
  KKTimeline *snap = KKProcessTimelineSnapshot();
  KKTimeline *tl = snap ? KKTimelineSettingValuesNearestFraction(
                              snap, @"Anchor", frac, newValues)
                        : nil;
  if (!tl) {
    tl = snap ? [snap copy] : [KKTimeline timeline];
    NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
    KKLane *anchorLane = [KKLane laneWithLabel:@"Anchor"];
    anchorLane.valueType = KKLaneValueTypeGeneric;
    anchorLane.componentMin = @[];
    anchorLane.componentMax = @[];
    anchorLane.componentUnits = @[ @"px", @"px" ];
    anchorLane.componentsScaleWithMedia = YES;
    anchorLane.componentLabels = @[ @"X", @"Y" ];
    anchorLane.enabled = NO;
    anchorLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    [lanes addObject:anchorLane];
    tl.lanes = lanes;
  }

  KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                           kKKParamTimelineData);
  [actionAPI endAction:self];
  if (forceUpdate)
    *forceUpdate = YES;
}

@end
