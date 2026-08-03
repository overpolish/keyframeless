/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPositionOSC.h"
#import "KKPositionElementModel.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <simd/simd.h>

@interface KKPositionOSC ()
@property(nonatomic, readwrite) KKPointOSC *anchorDotOSC;
@property(nonatomic, readwrite) KKPointOSC *tangentDotOSC;
@property(nonatomic, readwrite) KKSnapEngine *snapEngine;
@property(nonatomic, readwrite) BOOL hoverTargetIsAnchor;
// Drag state (was the host's state).
@property(nonatomic) BOOL cmdSnapActive;
@property(nonatomic) simd_float2 posPressObject;
@property(nonatomic) double dragAnchorFrac;
@property(nonatomic) double posGrabValX;
@property(nonatomic) double posGrabValY;
@property(nonatomic) double dragHandleFrac;
@property(nonatomic) BOOL dragHandleIsOut;
@property(nonatomic) double lastClickTime;
@property(nonatomic) double lastClickFrac;
// The clip fraction the NEXT lane<->object warp evaluation belongs to: the
// playhead for the handle / drags, each sample's own time along the motion
// path, the keypose's time for anchors + tangents. Only read when the warp
// closures are set.
@property(nonatomic) double warpFraction;
@end

@implementation KKPositionOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                         laneLabel:(NSString *)laneLabel
                         pathLabel:(NSString *)pathLabel {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _laneLabel = [laneLabel copy];
    _pathLabel = [pathLabel copy];
    _positionActivePart = 1;
    _tangentActivePart = 3;
    // The controller is always composed under a host OSC that clears the
    // destination once at the start of its drawOSC tick; the arc handle draws
    // LAST (over the path + the host's other controls), so it must NOT clear or
    // it wipes everything drawn before it (same reason the dots below don't).
    self.clearsOnDraw = NO;
    _snapEngine = [[KKSnapEngine alloc] init];
    // Match the crop/radius points so the anchors are easy to hit. Must
    // not clear the destination, or each dot wipes the path + earlier anchors.
    _anchorDotOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    _anchorDotOSC.oscRadius = 7.0f;
    _anchorDotOSC.outlineWidth = 2.0f;
    _anchorDotOSC.clearsOnDraw = NO;
    _tangentDotOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    _tangentDotOSC.oscRadius = 5.0f;
    _tangentDotOSC.outlineWidth = 1.5f;
    _tangentDotOSC.clearsOnDraw = NO;
    _dragAnchorFrac = NAN;
    _dragHandleFrac = NAN;
    _lastClickTime = -1.0;
    _lastClickFrac = NAN;
    _parentObjectTransform = matrix_identity_float3x3;
  }
  return self;
}

- (nullable KKLane *)_positionLane {
  for (KKLane *lane in KKProcessTimelineSnapshot().lanes)
    if ([lane.key isEqualToString:self.laneLabel])
      return lane;
  return nil;
}

- (BOOL)_positionVisibleAtFraction:(double)frac {
  return KKLaneVisibleAtFraction([self _positionLane], frac,
                                 KKProcessFrameDurationSeconds());
}

// Raw (un-rounded) value so the arc handle lands exactly on the keypose anchors
// (drawn from raw kp.values). The Smoothed variant corner-rounds at interior
// joins, which pulls the handle off the active anchor.
- (NSArray<NSNumber *> *)_positionValuesAtFraction:(double)frac {
  KKLane *lane = [self _positionLane];
  if (!lane)
    return @[ @0.5, @0.5 ];
  NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, frac);
  return v.count >= 2 ? v : @[ @0.5, @0.5 ];
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return CGPointZero;
  double objX, objY;
  KKOSCGuideBridge *bridge = self.guideProvider.positionGuideBridge;
  if (bridge && bridge.guideStep > 0) {
    // During the guide the handle follows the guide-scoped position the drag
    // pushes in (the blob is unreadable in this tick).
    CGPoint g = [self.guideProvider positionGuideObjectValue];
    objX = g.x;
    objY = g.y;
  } else {
    double frac = [self fractionAtTime:time];
    NSArray<NSNumber *> *vals = [self _positionValuesAtFraction:frac];
    objX = vals[0].doubleValue;
    objY = vals[1].doubleValue;
    self.warpFraction = frac;
  }
  return [self _canvasFromObjX:objX y:objY];
}

- (CGPoint)positionCanvasAtTime:(CMTime)time {
  return [self oscPositionAtTime:time];
}

// OBJECT (the control's own lane space) -> parent space (parentObjectTransform)
// -> CANVAS. The parent transform is identity unless a host nests this control
// inside a transformed parent (e.g. a Canvas member in a group).
- (CGPoint)_canvasFromObjX:(double)ox y:(double)oy {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  // The block-supplied warp (lane value -> object) runs INSIDE the parent
  // transform, at whatever fraction the caller staged in warpFraction.
  if (self.laneToObjectWarp) {
    simd_float2 w = self.laneToObjectWarp((simd_float2){(float)ox, (float)oy},
                                          self.warpFraction);
    ox = w.x;
    oy = w.y;
  }
  simd_float3 p = simd_mul(self.parentObjectTransform,
                           simd_make_float3((float)ox, (float)oy, 1.0f));
  double px = (p.z != 0.0f) ? p.x / p.z : p.x;
  double py = (p.z != 0.0f) ? p.y / p.z : p.y;
  CGPoint c = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:px
                          fromY:py
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&c.x
                            toY:&c.y];
  return c;
}

// CANVAS -> parent space -> INVERSE parentObjectTransform -> the control's own
// lane space, so a drag maps the cursor back through the parent (reacting to
// its rotation/scale) into the value's space.
- (CGPoint)_objFromCanvasX:(double)cx y:(double)cy {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  double qx = 0.0, qy = 0.0;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:cx
                          fromY:cy
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&qx
                            toY:&qy];
  simd_float3 l = simd_mul(simd_inverse(self.parentObjectTransform),
                           simd_make_float3((float)qx, (float)qy, 1.0f));
  double lx = (l.z != 0.0f) ? l.x / l.z : l.x;
  double ly = (l.z != 0.0f) ? l.y / l.z : l.y;
  if (self.objectToLaneWarp) {
    simd_float2 w = self.objectToLaneWarp((simd_float2){(float)lx, (float)ly},
                                          self.warpFraction);
    lx = w.x;
    ly = w.y;
  }
  return CGPointMake(lx, ly);
}

// Read-only motion path: the trajectory the clip's centre travels, sampled
// geometrically (no temporal easing) so overshooting curves don't draw loops.
- (void)_drawPositionPathToDestination:(FxImageTile *)destinationImage
                            ghostAlpha:(float)ghostAlpha {
  KKLane *lane = [self _positionLane];
  if (!lane || lane.keyposes.count < 2)
    return;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return;
  NSArray<NSNumber *> *fracs = nil;
  NSArray<NSValue *> *path =
      KKLanePositionPathPointsWithFractions(lane, 24, &fracs);
  NSUInteger n = path.count;
  if (n < 2)
    return;
  CGPoint *pts = malloc(sizeof(CGPoint) * n);
  for (NSUInteger i = 0; i < n; i++) {
    NSPoint o = path[i].pointValue;
    // Per-sample fraction: a warp referencing animated values maps each path
    // point at ITS OWN time, so the drawn path is the true trajectory.
    if (i < fracs.count)
      self.warpFraction = fracs[i].doubleValue;
    pts[i] = [self _canvasFromObjX:o.x y:o.y];
  }
  simd_float4 red = {1.0f, 0.25f, 0.25f, 0.9f * ghostAlpha};
  [self drawLineStripWithPoints:pts
                          count:n
                          color:red
                      halfWidth:2.0f
               destinationImage:destinationImage];
  free(pts);
}

// Tangent handles for every smooth keypose.
- (void)_drawHandlesToDestination:(FxImageTile *)destinationImage
                           atTime:(CMTime)time
                       ghostAlpha:(float)ghostAlpha {
  KKLane *lane = [self _positionLane];
  if (!lane || lane.keyposes.count < 2)
    return;
  self.tangentDotOSC.ghostAlpha = ghostAlpha;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  simd_float4 hc = {1.0f, 1.0f, 1.0f, 0.85f * ghostAlpha};
  for (NSUInteger i = 0; i < kps.count; i++) {
    KKKeyPose *kp = kps[i];
    if (!kp.spatialSmooth || kp.values.count < 2)
      continue;
    double ax = kp.values[0].doubleValue, ay = kp.values[1].doubleValue;
    self.warpFraction = kp.time; // tangents map at their keypose's time
    CGPoint anchorC = [self _canvasFromObjX:ax y:ay];
    CGPoint inH = CGPointZero, outH = CGPointZero;
    KKLaneSpatialHandlesForKeypose(lane, i, &inH, &outH);
    CGPoint sides[2] = {outH, inH};
    for (int s = 0; s < 2; s++) {
      if (hypot(sides[s].x, sides[s].y) < 1e-6)
        continue;
      CGPoint hCanvas = [self _canvasFromObjX:(ax + sides[s].x)
                                            y:(ay + sides[s].y)];
      [self drawLineFrom:anchorC
                        to:hCanvas
                     color:hc
                 halfWidth:2.0f
          destinationImage:destinationImage];
      [self.tangentDotOSC drawAtCanvasPosition:hCanvas
                                     isHovered:NO
                                      isActive:NO
                              destinationImage:destinationImage
                                        atTime:time];
    }
  }
}

// A small dot at every Position keypose - the draggable anchors of the path.
- (void)_drawKeyposeAnchorsToDestination:(FxImageTile *)destinationImage
                                  atTime:(CMTime)time
                                skipFrac:(double)skipFrac
                              skipActive:(BOOL)skipActive
                              ghostAlpha:(float)ghostAlpha {
  KKLane *lane = [self _positionLane];
  if (!lane || lane.keyposes.count < 2)
    return;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return;
  self.anchorDotOSC.ghostAlpha = ghostAlpha;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  NSInteger skipIdx = -1;
  if (skipActive) {
    double bd = 1e9;
    for (NSInteger i = 0; i < (NSInteger)kps.count; i++) {
      double d = fabs(kps[i].time - skipFrac);
      if (d < bd) {
        bd = d;
        skipIdx = i;
      }
    }
  }
  NSArray<NSNumber *> *anchorFracs = nil;
  NSArray<NSValue *> *anchors =
      KKLaneCoalescedAnchorsWithFractions(lane, skipIdx, &anchorFracs);
  for (NSUInteger i = 0; i < anchors.count; i++) {
    NSPoint v = anchors[i].pointValue;
    if (i < anchorFracs.count)
      self.warpFraction = anchorFracs[i].doubleValue;
    CGPoint c = [self _canvasFromObjX:v.x y:v.y];
    [self.anchorDotOSC drawAtCanvasPosition:c
                                  isHovered:NO
                                   isActive:NO
                           destinationImage:destinationImage
                                     atTime:time];
  }
}

// Compute the handle's visibility booleans shared by drawPath + drawHandle.
- (BOOL)_posVisibleAtFraction:(double)frac
                   activePart:(NSInteger)activePart
               handleTargeted:(BOOL *)outHT
               draggingHandle:(BOOL *)outDH
                      inGuide:(BOOL *)outIG {
  BOOL posShownHere = [self _positionVisibleAtFraction:frac];
  BOOL posEnabled = [self kkOSCElementVisible:self.laneLabel];
  // The arc handle is the target only when the interaction is the handle, not a
  // grabbed keypose anchor (both report the same activePart).
  BOOL handleTargeted =
      (activePart == self.positionActivePart) &&
      (self.dragging ? isnan(self.dragAnchorFrac) : !self.hoverTargetIsAnchor);
  BOOL draggingHandle = self.dragging && handleTargeted;
  KKOSCGuideBridge *bridge = self.guideProvider.positionGuideBridge;
  BOOL inGuide = bridge && bridge.guideStep > 0;
  if (outHT)
    *outHT = handleTargeted;
  if (outDH)
    *outDH = draggingHandle;
  if (outIG)
    *outIG = inGuide;
  return draggingHandle || (posEnabled && (posShownHere || inGuide));
}

- (void)drawPathInDestination:(FxImageTile *)destinationImage
                       atTime:(CMTime)time
                   activePart:(NSInteger)activePart {
  double frac = [self fractionAtTime:time];
  BOOL posVisible = [self _posVisibleAtFraction:frac
                                     activePart:activePart
                                 handleTargeted:NULL
                                 draggingHandle:NULL
                                        inGuide:NULL];
  BOOL pathEnabled = [self kkOSCElementVisible:self.pathLabel];
  BOOL pathReveal =
      self.optRevealActive && [self kkOSCRevealEligible:self.pathLabel];
  if (!pathEnabled && !pathReveal)
    return;
  float pg = pathEnabled ? 1.0f : [self kkRevealGhostAlpha];
  [self _drawPositionPathToDestination:destinationImage ghostAlpha:pg];
  [self _drawHandlesToDestination:destinationImage atTime:time ghostAlpha:pg];
  [self _drawKeyposeAnchorsToDestination:destinationImage
                                  atTime:time
                                skipFrac:frac
                              skipActive:posVisible
                              ghostAlpha:pg];
}

- (void)drawHandleInDestination:(FxImageTile *)destinationImage
                         atTime:(CMTime)time
                     activePart:(NSInteger)activePart {
  double frac = [self fractionAtTime:time];
  BOOL handleTargeted = NO, draggingHandle = NO, inGuide = NO;
  BOOL posVisible = [self _posVisibleAtFraction:frac
                                     activePart:activePart
                                 handleTargeted:&handleTargeted
                                 draggingHandle:&draggingHandle
                                        inGuide:&inGuide];
  BOOL posGhost = !posVisible && self.optRevealActive &&
                  [self kkOSCRevealEligible:self.laneLabel] &&
                  [self _positionVisibleAtFraction:frac];
  CGPoint pos = [self positionCanvasAtTime:time];
  if (posVisible || posGhost) {
    self.fillAlpha = posGhost ? [self kkRevealGhostAlpha] : 1.0f;
    KKOSCGuideBridge *bridge = self.guideProvider.positionGuideBridge;
    BOOL guideHover = inGuide && bridge.handleHovered;
    [self drawAtCanvasPosition:pos
                     isHovered:(handleTargeted || guideHover)
                      isActive:draggingHandle
              destinationImage:destinationImage
                        atTime:time];
  }
  if (self.dragging && activePart == self.positionActivePart &&
      self.cmdSnapActive) {
    simd_float4 yellow, accent;
    KKSnapGuideColors(&yellow, &accent);
    [self.snapEngine drawSnapGuidesWithOSC:self
                             isObjectSpace:YES
                               canvasColor:yellow
                               objectColor:accent
                          destinationImage:destinationImage];
  }
}

// Screen projection for the shared KKPositionElementModel hit helpers: warp
// to the keypose's fraction (side effect the canvas mapping reads), then map
// object space into canvas px through the parent transform.
- (KKPositionProjection)_canvasProjection {
  return ^CGPoint(double ox, double oy, double fraction) {
    self.warpFraction = fraction;
    return [self _canvasFromObjX:ox y:oy];
  };
}

- (double)_anchorFracNearCanvasX:(double)x y:(double)y {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return NAN;
  KKLane *lane = [self _positionLane];
  NSInteger idx = KKPositionAnchorHitIndex(
      lane, CGPointMake(x, y), KKPositionHitTolPt(self.anchorDotOSC.oscRadius),
      -1, [self _canvasProjection]);
  return idx >= 0 ? lane.keyposes[idx].time : NAN;
}

- (BOOL)_handleHitAtCanvasX:(double)x
                          y:(double)y
                    outFrac:(double *)outFrac
                   outIsOut:(BOOL *)outIsOut {
  KKLane *lane = [self _positionLane];
  BOOL isOut = NO;
  NSInteger idx = KKPositionTangentHitIndex(
      lane, CGPointMake(x, y), KKPositionHitTolPt(self.tangentDotOSC.oscRadius),
      &isOut, [self _canvasProjection]);
  if (idx < 0)
    return NO;
  if (outFrac)
    *outFrac = lane.keyposes[idx].time;
  if (outIsOut)
    *outIsOut = isOut;
  return YES;
}

- (void)_setCursorForLabel:(NSString *)label {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  [oscAPI setCursor:([self kkVisibilityCursorForLabel:label]
                         ?: KKPointMoveCursor())];
}

- (KKPositionHit)hitTestAtX:(double)x y:(double)y atTime:(CMTime)time {
  double frac = [self fractionAtTime:time];
  self.hoverTargetIsAnchor = NO;
  BOOL pathReach =
      [self kkOSCElementVisible:self.pathLabel] ||
      (self.optRevealActive && [self kkOSCRevealEligible:self.pathLabel]);
  BOOL posReachable =
      ([self kkOSCElementVisible:self.laneLabel] ||
       (self.optRevealActive && [self kkOSCRevealEligible:self.laneLabel])) &&
      [self _positionVisibleAtFraction:frac];
  KKPositionHit result = KKPositionHitNone;
  // Tangent handles sit on top of the path - grab them before the arc/anchors.
  if (pathReach && [self _handleHitAtCanvasX:x
                                           y:y
                                     outFrac:NULL
                                    outIsOut:NULL]) {
    [self _setCursorForLabel:self.pathLabel];
    result = KKPositionHitTangentHandle;
  } else if (posReachable && [self hitTestAtMousePositionX:x
                                                 positionY:y
                                                    atTime:time]) {
    [self _setCursorForLabel:self.laneLabel];
    result = KKPositionHitHandle;
  } else if (pathReach && !isnan([self _anchorFracNearCanvasX:x y:y])) {
    // Any keypose anchor dot is grabbable, independent of the playhead.
    self.hoverTargetIsAnchor = YES;
    [self _setCursorForLabel:self.pathLabel];
    result = KKPositionHitAnchorDot;
  }
  return result;
}

- (void)mouseDownAtX:(double)x
                   y:(double)y
                 hit:(KKPositionHit)hit
           modifiers:(NSUInteger)modifiers
         forceUpdate:(BOOL *)forceUpdate
              atTime:(CMTime)time {
  if (hit == KKPositionHitTangentHandle) {
    double hf = NAN;
    BOOL hOut = NO;
    if ([self _handleHitAtCanvasX:x y:y outFrac:&hf outIsOut:&hOut]) {
      self.dragHandleFrac = hf;
      self.dragHandleIsOut = hOut;
    }
    return;
  }
  double pressFrac = [self fractionAtTime:time];
  self.warpFraction = pressFrac;
  CGPoint pressObj = [self _objFromCanvasX:x y:y];
  self.posPressObject = (simd_float2){(float)pressObj.x, (float)pressObj.y};
  BOOL onHandle = [self _positionVisibleAtFraction:pressFrac] &&
                  [self hitTestAtMousePositionX:x positionY:y atTime:time];
  self.dragAnchorFrac = onHandle ? NAN : [self _anchorFracNearCanvasX:x y:y];
  if (!isnan(self.dragAnchorFrac)) {
    // An anchor drag writes at the ANCHOR's keypose, so re-invert the press
    // point at that fraction - keeping press + drag conversions in the same
    // frame when a warp references animated values.
    self.warpFraction = self.dragAnchorFrac;
    CGPoint ap = [self _objFromCanvasX:x y:y];
    self.posPressObject = (simd_float2){(float)ap.x, (float)ap.y};
  }
  double clickFrac =
      isnan(self.dragAnchorFrac) ? pressFrac : self.dragAnchorFrac;
  double now = [NSDate timeIntervalSinceReferenceDate];
  if (now - self.lastClickTime < 0.4 && !isnan(self.lastClickFrac) &&
      fabs(self.lastClickFrac - clickFrac) < 1e-6) {
    [self _toggleSmoothForFrac:clickFrac];
    self.lastClickTime = -1.0;
    self.lastClickFrac = NAN;
    self.dragAnchorFrac = NAN; // consumed by the toggle, don't also drag
    if (forceUpdate)
      *forceUpdate = YES;
    return;
  }
  self.lastClickTime = now;
  self.lastClickFrac = clickFrac;
  self.posGrabValX = self.posPressObject.x;
  self.posGrabValY = self.posPressObject.y;
  KKLane *pl = [self _positionLane];
  if (pl.keyposes.count) {
    NSInteger b = KKLaneNearestKeyposeIndex(pl, clickFrac);
    NSArray<NSNumber *> *v = pl.keyposes[b].values;
    if (v.count >= 2) {
      self.posGrabValX = v[0].doubleValue;
      self.posGrabValY = v[1].doubleValue;
    }
  }
}

- (void)mouseDraggedAtX:(double)x
                      y:(double)y
                    hit:(KKPositionHit)hit
              modifiers:(NSUInteger)modifiers
            forceUpdate:(BOOL *)forceUpdate
                 atTime:(CMTime)time {
  if (hit == KKPositionHitTangentHandle) {
    [self _dragHandleToX:x
                       y:y
               modifiers:modifiers
             forceUpdate:forceUpdate
                  atTime:time];
    return;
  }
  double dragFrac = [self fractionAtTime:time];
  self.warpFraction =
      isnan(self.dragAnchorFrac) ? dragFrac : self.dragAnchorFrac;
  CGPoint cur = [self _objFromCanvasX:x y:y];
  double curX = cur.x, curY = cur.y;
  // Delta-based drag from the grab point; Shift pins the axis with less
  // travel (shared shaping).
  double newX = 0, newY = 0;
  KKPositionShapeAnchorDrag(
      self.posGrabValX, self.posGrabValY, curX - (double)self.posPressObject.x,
      curY - (double)self.posPressObject.y,
      (modifiers & kFxModifierKey_SHIFT) != 0, &newX, &newY);

  // Snap OFF by default; Cmd engages it (unless this control opted out).
  self.cmdSnapActive =
      !self.snapDisabled && (modifiers & kFxModifierKey_COMMAND) != 0;
  double frac = [self fractionAtTime:time];
  double targetFrac = isnan(self.dragAnchorFrac) ? frac : self.dragAnchorFrac;
  if (self.cmdSnapActive) {
    simd_float2 snapped =
        [self _snapPosition:(simd_float2){(float)newX, (float)newY}
                 atFraction:targetFrac];
    newX = snapped.x;
    newY = snapped.y;
  } else if (!self.snapDisabled && self.canvasSnapProvider) {
    // Use the parent-aware conversion pair (_canvasFromObjX / _objFromCanvasX)
    // so the round-trip stays consistent when the control is nested in a
    // transformed parent (a Canvas member in a rotated group).
    // canvasPointFromObjectPoint is the raw object->canvas and would mismatch
    // the inverse below, offsetting the snapped handle.
    CGPoint cp = [self _canvasFromObjX:newX y:newY];
    CGPoint sp = self.canvasSnapProvider(cp);
    CGPoint so = [self _objFromCanvasX:sp.x y:sp.y];
    newX = so.x;
    newY = so.y;
    [self.snapEngine reset];
  } else {
    [self.snapEngine reset];
  }

  __block BOOL wrote = NO;
  KKPerformUndoable(
      self.apiManager, self, nil,
      ^(id<FxParameterRetrievalAPI_v6> getAPI,
        id<FxParameterSettingAPI_v5> setAPI, CMTime actionTime) {
        if (!setAPI)
          return;
        // Snapshot is canonical - the param read returns empty inside the OSC
        // action scope. Copy-preserves spatial-curve fields + propagates
        // hold-links.
        NSArray<NSNumber *> *newValues = @[ @(newX), @(newY) ];
        KKTimeline *snap = KKProcessTimelineSnapshot();
        KKTimeline *tl = snap ? KKTimelineSettingValuesNearestFraction(
                                    snap, self.laneLabel, targetFrac, newValues)
                              : nil;
        if (!tl) {
          tl = snap ? [snap copy] : [KKTimeline timeline];
          NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
          KKLane *posLane = [self.templateLane copy]
                                ?: [KKLane laneWithKey:self.laneLabel
                                                 label:self.laneLabel];
          posLane.enabled = NO;
          posLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                                  values:newValues] ];
          [lanes addObject:posLane];
          tl.lanes = lanes;
        }
        if (self.onTimelinePersist)
          self.onTimelinePersist(tl);
        else
          KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                                   kKKParamTimelineData);
        wrote = YES;
      });
  if (wrote && forceUpdate)
    *forceUpdate = YES;
}

- (void)mouseUp {
  [self.snapEngine reset];
  self.dragAnchorFrac = NAN;
  self.dragHandleFrac = NAN;
}

// Snap the drag against canvas edges (0/1), centre (0.5), thirds (0.25/0.75),
// and every other keypose's stored position. Object space.
- (simd_float2)_snapPosition:(simd_float2)p atFraction:(double)frac {
  KKLane *lane = [self _positionLane];
  // The drag edits the keypose nearest `frac` - excluded (with its hold-linked
  // twins) by the shared model so the anchor can't snap to itself. Threshold:
  // engine px converted to object units through the canvas scale.
  NSInteger edited =
      lane.keyposes.count ? KKLaneNearestKeyposeIndex(lane, frac) : -1;
  CGPoint o0 = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint o1 = [self canvasPointFromObjectPoint:(simd_float2){1, 0}];
  float pxPerUnit = (float)fabs(o1.x - o0.x);
  float thr = (pxPerUnit > 0) ? self.snapEngine.threshold / pxPerUnit : 0.005f;
  // With a placement warp the LANE value is NOT where the handle is drawn - an
  // offset lane sits near (0,0) while its handle is mid-frame - but the canvas
  // anchors below are object space. Snapping the raw lane value against them
  // dragged the handle to the frame's bottom-left corner. Snap in OBJECT space
  // and map back, warping the lane's own keypose targets to match so
  // handle-to-keypose snapping stays in one space too.
  if (self.laneToObjectWarp && self.objectToLaneWarp) {
    KKLane *warped = [lane copy];
    NSMutableArray<KKKeyPose *> *kps = [warped.keyposes mutableCopy];
    for (NSUInteger i = 0; i < kps.count; i++) {
      KKKeyPose *k = kps[i];
      if (k.values.count < 2)
        continue;
      simd_float2 w = self.laneToObjectWarp(
          (simd_float2){k.values[0].floatValue, k.values[1].floatValue},
          k.time);
      KKKeyPose *nk = [k copy];
      nk.values = @[ @(w.x), @(w.y) ];
      kps[i] = nk;
    }
    warped.keyposes = kps;
    simd_float2 snapped =
        KKPositionSnapPoint(self.snapEngine, self.laneToObjectWarp(p, frac),
                            warped, edited, self.externalSnapTargets, thr, thr);
    return self.objectToLaneWarp(snapped, frac);
  }
  return KKPositionSnapPoint(self.snapEngine, p, lane, edited,
                             self.externalSnapTargets, thr, thr);
}

// Double-click toggle: flip the keypose nearest `frac` between smooth and
// corner.
- (void)_toggleSmoothForFrac:(double)frac {
  KKPerformUndoable(
      self.apiManager, self, nil,
      ^(id<FxParameterRetrievalAPI_v6> getAPI,
        id<FxParameterSettingAPI_v5> setAPI, CMTime actionTime) {
        KKTimeline *snap = KKProcessTimelineSnapshot();
        if (!setAPI || !snap)
          return;
        KKLane *lane = [self _positionLane];
        BOOL cur = NO;
        if (lane.keyposes.count)
          cur = lane.keyposes[KKLaneNearestKeyposeIndex(lane, frac)]
                    .spatialSmooth;
        KKTimeline *tl =
            KKTimelineSettingSpatialSmooth(snap, self.laneLabel, frac, !cur);
        if (tl) {
          if (self.onTimelinePersist)
            self.onTimelinePersist(tl);
          else
            KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                                     kKKParamTimelineData);
        }
      });
}

// Drag a tangent handle: set the dragged keypose's in/out handle to the cursor
// offset from the anchor. Shift axis-locks the handle to H/V; Cmd snaps its
// angle to 45-degree steps; Ctrl breaks the tangent into a cusp (in/out move
// independently) - otherwise the opposite side mirrors for a smooth curve.
- (void)_dragHandleToX:(double)x
                     y:(double)y
             modifiers:(NSUInteger)modifiers
           forceUpdate:(BOOL *)forceUpdate
                atTime:(CMTime)time {
  if (isnan(self.dragHandleFrac))
    return;
  self.warpFraction = self.dragHandleFrac; // tangent maps at its keypose
  CGPoint cur = [self _objFromCanvasX:x y:y];
  double curX = cur.x, curY = cur.y;
  __block BOOL wrote = NO;
  KKPerformUndoable(
      self.apiManager, self, nil,
      ^(id<FxParameterRetrievalAPI_v6> getAPI,
        id<FxParameterSettingAPI_v5> setAPI, CMTime actionTime) {
        KKTimeline *snap = KKProcessTimelineSnapshot();
        if (!setAPI || !snap)
          return;
        KKTimeline *tl = [snap copy];
        NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
        NSInteger laneIdx = NSNotFound;
        for (NSInteger i = 0; i < (NSInteger)lanes.count; i++)
          if ([((KKLane *)lanes[i]).key isEqualToString:self.laneLabel]) {
            laneIdx = i;
            break;
          }
        if (laneIdx == NSNotFound)
          return;
        KKLane *posLane = [lanes[laneIdx] copy];
        NSArray<KKKeyPose *> *kps = posLane.keyposes;
        if (kps.count == 0)
          return;
        NSInteger best =
            KKLaneNearestKeyposeIndex(posLane, self.dragHandleFrac);
        NSMutableArray<KKKeyPose *> *out = [NSMutableArray arrayWithArray:kps];
        KKKeyPose *nk =
            (best >= 0 && best < (NSInteger)out.count) ? [out[best] copy] : nil;
        // A malformed / mid-transition keypose (short values) must not reach
        // the mutation below - bail cleanly (the wrapper's @finally would close
        // the scope even on a throw, but a clean bail keeps the write out
        // entirely).
        if (!nk || nk.values.count < 2)
          return;
        double ax = nk.values[0].doubleValue, ay = nk.values[1].doubleValue;
        // Ctrl is safe mid-drag - it only opens a context menu on a fresh
        // Ctrl-click, not once a drag is under way.
        KKPositionApplyTangentDrag(nk, self.dragHandleIsOut, curX - ax,
                                   curY - ay,
                                   (modifiers & kFxModifierKey_SHIFT) != 0,
                                   (modifiers & kFxModifierKey_COMMAND) != 0,
                                   (modifiers & kFxModifierKey_CONTROL) != 0);
        out[best] = nk;
        posLane.keyposes = out;
        lanes[laneIdx] = posLane;
        tl.lanes = lanes;
        if (self.onTimelinePersist)
          self.onTimelinePersist(tl);
        else
          KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                                   kKKParamTimelineData);
        wrote = YES;
      });
  if (wrote && forceUpdate)
    *forceUpdate = YES;
}

- (NSArray<NSString *> *)oscElementKeys {
  return @[ self.laneLabel, self.pathLabel ];
}

@end
