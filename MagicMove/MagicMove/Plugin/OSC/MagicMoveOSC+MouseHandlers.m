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

// Scale drag is absolute: the grabbed handle tracks the cursor (deterministic,
// in sync), mapping cursor distance to centre back through the gizmo curve.
// Holding Cmd engages a fine mode that scales cursor movement down for precise
// adjustment (essential at high scale, where the compressed box is otherwise
// hyper-sensitive).
static const double kScaleFineFactor = 0.2;

@implementation MagicMoveOSC (MouseHandlers)

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  [self kkResetOptHideArming];
  [self.positionController mouseUp];
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
    self.scaleGrabHandle = self.scaleHitHandle;
    self.scalePressCenter = [self oscPositionAtTime:time];
    NSArray<NSNumber *> *sv =
        _scaleValuesAtFraction([self _fractionAtTime:time]);
    self.scalePressSclX = sv.count > 0 ? sv[0].doubleValue : 100.0;
    self.scalePressSclY = sv.count > 1 ? sv[1].doubleValue : 100.0;
    // Effective cursor starts at the grabbed handle (not the raw click point),
    // so the value begins exactly where it is - no press snap.
    double e0p = 0, spanp = 0;
    [self _scaleGizmoE0:&e0p span:&spanp];
    CGPoint hp[8];
    MMScaleHandlePositions(self.scalePressCenter, self.scalePressSclX,
                           self.scalePressSclY, e0p, spanp, hp);
    self.scaleEffCursor =
        (self.scaleGrabHandle >= 0 && self.scaleGrabHandle < 8)
            ? hp[self.scaleGrabHandle]
            : CGPointMake(positionX, positionY);
    self.scaleLastCursor = CGPointMake(positionX, positionY);
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
    double frac = [self _fractionAtTime:time];
    // Capture press values from the KEYPOSE we'll write to (the one nearest
    // the playhead), not the smoothed interpolation. The smoothed reader
    // uses an easing curve that overshoots near keypose boundaries - if we
    // used it as the press baseline, the non-dragged axes would inherit
    // that overshoot and silently overwrite the keypose's actual values.
    KKLane *rotLane = _rotationLane();
    NSArray<NSNumber *> *r = nil;
    if (rotLane.keyposes.count > 0)
      r = rotLane.keyposes[KKLaneNearestKeyposeIndex(rotLane, frac)].values;
    if (r.count < 3)
      r = @[ @0.0, @0.0, @0.0 ];
    self.rotPressX = r[0].doubleValue * M_PI / 180.0;
    self.rotPressY = r[1].doubleValue * M_PI / 180.0;
    self.rotPressZ = r[2].doubleValue * M_PI / 180.0;
    self.rotLastWrittenX = self.rotPressX;
    self.rotLastWrittenY = self.rotPressY;
    self.rotLastWrittenZ = self.rotPressZ;
    self.rotPressCanvas = CGPointMake(positionX, positionY);
    // Sync the inner OSC to the live (smoothed) timeline values - that's
    // what the user actually sees on screen, so the press tangent has to be
    // computed against the same pose. The additive base above uses the
    // raw keypose so non-dragged axes stay untouched at write time.
    NSArray<NSNumber *> *smoothed = _rotationValuesAtFraction(frac);
    self.rotationOSC.rotX = (float)(smoothed[0].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotY = (float)(smoothed[1].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotZ = (float)(smoothed[2].doubleValue * M_PI / 180.0);
    self.rotationOSC.center = [self oscPositionAtTime:time];
    [self.rotationOSC mouseDownAtPositionX:positionX
                                 positionY:positionY
                                activePart:activePart
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
    [self _dragRotationToPositionX:positionX
                         positionY:positionY
                         modifiers:modifiers
                       forceUpdate:forceUpdate
                            atTime:time];
    return;
  }
  if (activePart == kOSCScalePart) {
    [self _dragScaleToPositionX:positionX
                      positionY:positionY
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

- (void)_dragRotationToPositionX:(double)positionX
                       positionY:(double)positionY
                       modifiers:(NSUInteger)modifiers
                     forceUpdate:(BOOL *)forceUpdate
                          atTime:(CMTime)time {
  NSInteger axis = self.rotationOSC.activeAxis;
  if (axis < 0)
    return;
  double dAngle = [self.rotationOSC
      angleDeltaFromPressPoint:self.rotPressCanvas
                  currentPoint:CGPointMake(positionX, positionY)];
  // Cmd-snap rounds the OBJECT-axis delta itself to a 15° step, BEFORE
  // composing into Euler. Snapping the decomposed axis values directly
  // jiggles the other two axes (their decomposed values change tick-to-
  // tick as the object rotates, and rounding only one axis leaves a
  // matrix that doesn't correspond to a pure ring rotation).
  if (modifiers & kFxModifierKey_COMMAND) {
    const double kSnapRad = 15.0 * M_PI / 180.0;
    dAngle = round(dAngle / kSnapRad) * kSnapRad;
  }
  // Compose around the OBJECT's current ring axis: R_new = R_press *
  // R_axis(dAngle). This rotates around the visible ring (which is the
  // image's current basis), so dragging the X ring after a Y rotation
  // spins the image around its current X, not global X - matching the
  // physical-knob intuition the user expects.
  //
  // The earlier "additive on dragged axis only" version dodged the asin
  // gimbal-clamp at ±90° but rotated around global axes instead, which
  // felt wrong once any other axis was non-zero. We bring back the compose
  // and handle the asin discontinuity by picking the Euler decomposition
  // closest to the press pose - so a 0→90→180 sweep stays continuous.
  double lastRx = self.rotLastWrittenX;
  double lastRy = self.rotLastWrittenY;
  double lastRz = self.rotLastWrittenZ;
  double rx = 0, ry = 0, rz = 0;
  KKRotationComposeAxisDelta((int)axis, dAngle, self.rotPressX, self.rotPressY,
                             self.rotPressZ, &lastRx, &lastRy, &lastRz, &rx,
                             &ry, &rz);
  self.rotLastWrittenX = lastRx;
  self.rotLastWrittenY = lastRy;
  self.rotLastWrittenZ = lastRz;
  const double kRadToDeg = 180.0 / M_PI;
  double xDeg = rx * kRadToDeg;
  double yDeg = ry * kRadToDeg;
  double zDeg = rz * kRadToDeg;
  NSArray<NSNumber *> *newValues = @[ @(xDeg), @(yDeg), @(zDeg) ];

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
                              snap, @"Rotation", frac, newValues)
                        : nil;
  if (!tl) {
    tl = snap ? [snap copy] : [KKTimeline timeline];
    NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
    KKLane *rotLane = [KKLane laneWithLabel:@"Rotation"];
    rotLane.valueType = KKLaneValueTypeGeneric;
    rotLane.componentUnits = @[ @"°", @"°", @"°" ];
    rotLane.componentLabels = @[ @"X", @"Y", @"Z" ];
    rotLane.enabled = NO;
    rotLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    [lanes addObject:rotLane];
    tl.lanes = lanes;
  }

  KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                           kKKParamTimelineData);
  [actionAPI endAction:self];
  *forceUpdate = YES;
}

- (void)_dragScaleToPositionX:(double)positionX
                    positionY:(double)positionY
                    modifiers:(NSUInteger)modifiers
                  forceUpdate:(BOOL *)forceUpdate
                       atTime:(CMTime)time {
  NSInteger h = self.scaleGrabHandle;
  if (h < 0)
    return;
  // Advance the effective cursor by the raw movement (scaled down for
  // Cmd-fine). The value comes from its distance to centre through the gizmo
  // curve, so the grabbed handle tracks the cursor 1:1 in normal mode
  // (deterministic).
  double rawDx = positionX - self.scaleLastCursor.x;
  double rawDy = positionY - self.scaleLastCursor.y;
  self.scaleLastCursor = CGPointMake(positionX, positionY);
  double fine = (modifiers & kFxModifierKey_COMMAND) ? kScaleFineFactor : 1.0;
  CGPoint eff = self.scaleEffCursor;
  eff.x += rawDx * fine;
  eff.y += rawDy * fine;
  self.scaleEffCursor = eff;

  CGPoint c = self.scalePressCenter;
  double pX = self.scalePressSclX, pY = self.scalePressSclY;
  double e0 = 0, span = 0;
  [self _scaleGizmoE0:&e0 span:&span];
  // Candidate per-axis percents from the effective cursor's distance to centre.
  double tX = KKScaleGizmoPercentForExtent(fabs(eff.x - c.x), e0, span);
  double tY = KKScaleGizmoPercentForExtent(fabs(eff.y - c.y), e0, span);
  // Link is global per-lane; Shift temporarily inverts it for this drag.
  BOOL shift = (modifiers & kFxModifierKey_SHIFT) != 0;
  BOOL effLinked = (_scaleLane().aspectLinked != 0) ^ shift;
  BOOL haveRatio = (pX > 1e-6 && pY > 1e-6);
  double newX = pX, newY = pY;

  if (kScaleHandleIsCorner(h)) {
    if (effLinked && haveRatio) {
      // Uniform: geometric mean of the two per-axis factors gives a single,
      // continuous scale factor (no dominant-axis flip); Y follows by ratio.
      double f = sqrt((tX / pX) * (tY / pY));
      newX = pX * f;
      newY = pY * f;
    } else {
      newX = tX;
      newY = tY;
    }
  } else if (kScaleHandleControlsX(h)) {
    newX = tX;
    newY = effLinked ? (haveRatio ? pY * (tX / pX) : tX) : pY;
  } else if (kScaleHandleControlsY(h)) {
    newY = tY;
    newX = effLinked ? (haveRatio ? pX * (tY / pY) : tY) : pX;
  }

  // Values snap to integers; floored at 0 (no negative scale).
  newX = fmax(0.0, round(newX));
  newY = fmax(0.0, round(newY));
  [self _writeScaleValues:@[ @(newX), @(newY) ]
                   atTime:time
              forceUpdate:forceUpdate];
}

- (void)_writeScaleValues:(NSArray<NSNumber *> *)newValues
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
                              snap, @"Scale", frac, newValues)
                        : nil;
  if (!tl) {
    tl = snap ? [snap copy] : [KKTimeline timeline];
    NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
    KKLane *scaleLane = [KKLane laneWithLabel:@"Scale"];
    scaleLane.valueType = KKLaneValueTypeFloat;
    scaleLane.componentMin = @[ @0.0, @0.0 ];
    scaleLane.componentUnits = @[ @"%", @"%" ];
    scaleLane.componentLabels = @[ @"X", @"Y" ];
    scaleLane.aspectLinkable = YES;
    scaleLane.aspectLinked = YES;
    scaleLane.enabled = NO;
    scaleLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    [lanes addObject:scaleLane];
    tl.lanes = lanes;
  }

  KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                           kKKParamTimelineData);
  [actionAPI endAction:self];
  if (forceUpdate)
    *forceUpdate = YES;
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
