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

@implementation MagicMoveOSC (HitTest)

// Time of the keypose whose on-canvas anchor dot is under (x,y), or NaN. Lets a
// drag start on any keypose's anchor, not just the playhead handle.
- (double)_anchorFracNearCanvasX:(double)x y:(double)y {
  KKLane *lane = _positionLane();
  if (!lane || lane.keyposes.count < 2)
    return NAN;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return NAN;
  double hitR = self.anchorOSC.oscRadius + 6.0;
  double bestFrac = NAN, bestD = 1e9;
  for (KKKeyPose *kp in lane.keyposes) {
    if (kp.values.count < 2)
      continue;
    CGPoint c = CGPointZero;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:kp.values[0].doubleValue
                            fromY:kp.values[1].doubleValue
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&c.x
                              toY:&c.y];
    double d = hypot(x - c.x, y - c.y);
    if (d < hitR && d < bestD) {
      bestD = d;
      bestFrac = kp.time;
    }
  }
  return bestFrac;
}

// A smooth keypose's tangent-handle dot under (x,y): outputs the keypose time +
// which side (out vs in). Returns YES on hit.
- (BOOL)_handleHitAtCanvasX:(double)x
                          y:(double)y
                    outFrac:(double *)outFrac
                   outIsOut:(BOOL *)outIsOut {
  KKLane *lane = _positionLane();
  if (!lane || lane.keyposes.count < 2)
    return NO;
  double hitR = self.handleOSC.oscRadius + 6.0;
  double bestD = 1e9, bestFrac = NAN;
  BOOL bestOut = NO, found = NO;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  for (NSUInteger i = 0; i < kps.count; i++) {
    KKKeyPose *kp = kps[i];
    if (!kp.spatialSmooth || kp.values.count < 2)
      continue;
    double ax = kp.values[0].doubleValue, ay = kp.values[1].doubleValue;
    CGPoint inH = CGPointZero, outH = CGPointZero;
    KKLaneSpatialHandlesForKeypose(lane, i, &inH, &outH);
    CGPoint sides[2] = {outH, inH};
    BOOL sideOut[2] = {YES, NO};
    for (int s = 0; s < 2; s++) {
      if (hypot(sides[s].x, sides[s].y) < 1e-6)
        continue;
      CGPoint hC = [self _canvasFromObjX:(ax + sides[s].x) y:(ay + sides[s].y)];
      double d = hypot(x - hC.x, y - hC.y);
      if (d < hitR && d < bestD) {
        bestD = d;
        bestFrac = kp.time;
        bestOut = sideOut[s];
        found = YES;
      }
    }
  }
  if (found) {
    if (outFrac)
      *outFrac = bestFrac;
    if (outIsOut)
      *outIsOut = bestOut;
  }
  return found;
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  self.hoverTargetIsAnchor = NO;
  self.anchorHovered = NO;
  self.scaleHitHandle = -1;
  double frac = [self _fractionAtTime:time];
  // Anchor pivot square is the topmost control: checked first so it is always
  // grabbable / opt-hideable. It is small, so the larger Position arc ring
  // around it stays clickable - the two coincide at the clip centre by default.
  if (([self kkOSCElementVisible:@"Anchor"] ||
       (self.optRevealActive && [self kkOSCRevealEligible:@"Anchor"])) &&
      _anchorVisibleAtFraction(frac)) {
    CGPoint ac = [self _anchorCanvasAtFraction:frac];
    if (fmax(fabs(positionX - ac.x), fabs(positionY - ac.y)) <
        [self.anchorPointOSC hitRadius]) {
      self.anchorHovered = YES;
      *activePart = kOSCAnchorPart;
      return;
    }
  }
  // Tangent handles sit on top of the path - grab them before the arc/anchors.
  if (([self kkOSCElementVisible:@"Path"] ||
       (self.optRevealActive && [self kkOSCRevealEligible:@"Path"])) &&
      [self _handleHitAtCanvasX:positionX
                              y:positionY
                        outFrac:NULL
                       outIsOut:NULL]) {
    *activePart = kOSCPathHandlePart;
    return;
  }
  // Opt-reveal makes a hidden handle hit-testable so an opt-click re-shows it.
  BOOL posReachable =
      ([self kkOSCElementVisible:@"Position"] ||
       (self.optRevealActive && [self kkOSCRevealEligible:@"Position"])) &&
      _positionVisibleAtFraction(frac);
  if (posReachable && [self hitTestAtMousePositionX:positionX
                                          positionY:positionY
                                             atTime:time]) {
    *activePart = kOSCPositionPart;
    return;
  }
  // Any keypose anchor dot is grabbable, independent of the playhead - so a
  // keypose's position can be dragged without first scrubbing onto it.
  if (([self kkOSCElementVisible:@"Path"] ||
       (self.optRevealActive && [self kkOSCRevealEligible:@"Path"])) &&
      !isnan([self _anchorFracNearCanvasX:positionX y:positionY])) {
    self.hoverTargetIsAnchor = YES;
    *activePart = kOSCPositionPart;
    return;
  }
  // Scale box handles sit just outside the rotation rings; check them before
  // rotation so an edge handle near the ring radius wins over the ring. Only
  // reachable where the box is shown (or opt-reveal exposes a hidden one).
  BOOL scaleReachable =
      ([self kkOSCElementVisible:@"Scale"] ||
       (self.optRevealActive && [self kkOSCRevealEligible:@"Scale"])) &&
      _scaleVisibleAtFraction(frac);
  if (scaleReachable) {
    NSInteger sh = [self _scaleHandleHitAtCanvasX:positionX
                                                y:positionY
                                           atTime:time];
    if (sh >= 0) {
      self.scaleHitHandle = sh;
      *activePart = kOSCScalePart;
      return;
    }
  }
  if ([self _configureRotationRingsAtFraction:frac dragging:NO]) {
    CGPoint c = [self oscPositionAtTime:time];
    NSArray<NSNumber *> *r = _rotationValuesAtFraction(frac);
    self.rotationOSC.rotX = (float)(r[0].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotY = (float)(r[1].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotZ = (float)(r[2].doubleValue * M_PI / 180.0);
    self.rotationOSC.center = c;
    if ([self.rotationOSC hitTestAtMousePositionX:positionX
                                        positionY:positionY
                                           atTime:time]) {
      *activePart = kOSCRotationPart;
    }
  }
}

- (NSInteger)_scaleHandleHitAtCanvasX:(double)x
                                    y:(double)y
                               atTime:(CMTime)time {
  double frac = [self _fractionAtTime:time];
  NSArray<NSNumber *> *sv = _scaleValuesAtFraction(frac);
  double sclX = sv.count > 0 ? sv[0].doubleValue : 100.0;
  double sclY = sv.count > 1 ? sv[1].doubleValue : 100.0;
  CGPoint center = [self oscPositionAtTime:time];
  double e0 = 0, span = 0;
  [self _scaleGizmoE0:&e0 span:&span];
  CGPoint handles[8];
  MMScaleHandlePositions(center, sclX, sclY, e0, span, handles);
  NSInteger part = [self.scaleBox hitTestAtX:x
                                           y:y
                                    topRight:handles[2]
                                  bottomLeft:handles[0]];
  return part >= KKBoxPartHandleBase ? part - KKBoxPartHandleBase : -1;
}

@end
