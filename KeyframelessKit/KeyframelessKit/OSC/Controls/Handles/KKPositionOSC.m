/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPositionOSC.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <simd/simd.h>

@interface KKPositionOSC ()
@property(nonatomic, readwrite) KKPointOSC *anchorDotOSC;
@property(nonatomic, readwrite) KKPointOSC *tangentDotOSC;
@property(nonatomic, readwrite) KKSnapEngine *snapEngine;
@property(nonatomic, readwrite) BOOL hoverTargetIsAnchor;
// Drag state (was MagicMove's host state).
@property(nonatomic) BOOL cmdSnapActive;
@property(nonatomic) simd_float2 posPressObject;
@property(nonatomic) double dragAnchorFrac;
@property(nonatomic) double posGrabValX;
@property(nonatomic) double posGrabValY;
@property(nonatomic) double dragHandleFrac;
@property(nonatomic) BOOL dragHandleIsOut;
@property(nonatomic) double lastClickTime;
@property(nonatomic) double lastClickFrac;
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
    // Match Rounded's crop/radius points so the anchors are easy to hit. Must
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
  }
  return self;
}

- (nullable KKLane *)_positionLane {
  for (KKLane *lane in KKProcessTimelineSnapshot().lanes)
    if ([lane.label isEqualToString:self.laneLabel])
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
    NSArray<NSNumber *> *vals =
        [self _positionValuesAtFraction:[self fractionAtTime:time]];
    objX = vals[0].doubleValue;
    objY = vals[1].doubleValue;
  }
  CGPoint canvas = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:objX
                          fromY:objY
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&canvas.x
                            toY:&canvas.y];
  return canvas;
}

- (CGPoint)positionCanvasAtTime:(CMTime)time {
  return [self oscPositionAtTime:time];
}

- (CGPoint)_canvasFromObjX:(double)ox y:(double)oy {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  CGPoint c = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:ox
                          fromY:oy
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&c.x
                            toY:&c.y];
  return c;
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
  NSArray<NSValue *> *path = KKLanePositionPathPoints(lane, 24);
  NSUInteger n = path.count;
  if (n < 2)
    return;
  CGPoint *pts = malloc(sizeof(CGPoint) * n);
  for (NSUInteger i = 0; i < n; i++) {
    NSPoint o = path[i].pointValue;
    CGPoint c = CGPointZero;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:o.x
                            fromY:o.y
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&c.x
                              toY:&c.y];
    pts[i] = c;
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
  for (NSValue *pv in KKLaneCoalescedAnchors(lane, skipIdx)) {
    NSPoint v = pv.pointValue;
    CGPoint c = CGPointZero;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:v.x
                            fromY:v.y
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&c.x
                              toY:&c.y];
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
    simd_float4 yellow = {1, 1, 0, 1};
    NSColor *accentNS = [[NSColor accentMatchingHost]
        colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    CGFloat ar = 1, ag = 1, ab = 1, aa = 1;
    [accentNS getRed:&ar green:&ag blue:&ab alpha:&aa];
    simd_float4 accent = {(float)ar, (float)ag, (float)ab, (float)aa};
    [self.snapEngine drawSnapGuidesWithOSC:self
                             isObjectSpace:YES
                               canvasColor:yellow
                               objectColor:accent
                          destinationImage:destinationImage];
  }
}

- (double)_anchorFracNearCanvasX:(double)x y:(double)y {
  KKLane *lane = [self _positionLane];
  if (!lane || lane.keyposes.count < 2)
    return NAN;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return NAN;
  double hitR = self.anchorDotOSC.oscRadius + 6.0;
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

- (BOOL)_handleHitAtCanvasX:(double)x
                          y:(double)y
                    outFrac:(double *)outFrac
                   outIsOut:(BOOL *)outIsOut {
  KKLane *lane = [self _positionLane];
  if (!lane || lane.keyposes.count < 2)
    return NO;
  double hitR = self.tangentDotOSC.oscRadius + 6.0;
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
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (oscAPI) {
    double objX = 0.0, objY = 0.0;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                            fromX:x
                            fromY:y
                          toSpace:kFxDrawingCoordinates_OBJECT
                              toX:&objX
                              toY:&objY];
    self.posPressObject = (simd_float2){(float)objX, (float)objY};
  }
  double pressFrac = [self fractionAtTime:time];
  BOOL onHandle = [self _positionVisibleAtFraction:pressFrac] &&
                  [self hitTestAtMousePositionX:x positionY:y atTime:time];
  self.dragAnchorFrac = onHandle ? NAN : [self _anchorFracNearCanvasX:x y:y];
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
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return;
  double curX = 0.0, curY = 0.0;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:x
                          fromY:y
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&curX
                            toY:&curY];
  // Delta-based drag: move by the cursor's offset from the grab point.
  double newX = self.posGrabValX + (curX - (double)self.posPressObject.x);
  double newY = self.posGrabValY + (curY - (double)self.posPressObject.y);

  // Shift axis-lock: pin whichever axis has less travel from the press point.
  if (modifiers & kFxModifierKey_SHIFT) {
    double dx = curX - (double)self.posPressObject.x;
    double dy = curY - (double)self.posPressObject.y;
    if (fabs(dx) >= fabs(dy))
      newY = self.posGrabValY;
    else
      newX = self.posGrabValX;
  }

  // Snap OFF by default; Cmd engages it.
  self.cmdSnapActive = (modifiers & kFxModifierKey_COMMAND) != 0;
  double frac = [self fractionAtTime:time];
  double targetFrac = isnan(self.dragAnchorFrac) ? frac : self.dragAnchorFrac;
  if (self.cmdSnapActive) {
    simd_float2 snapped =
        [self _snapPosition:(simd_float2){(float)newX, (float)newY}
                 atFraction:targetFrac];
    newX = snapped.x;
    newY = snapped.y;
  } else {
    [self.snapEngine reset];
  }

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

  // Snapshot is canonical - the param read returns empty inside the OSC action
  // scope. Copy-preserves spatial-curve fields + propagates hold-links.
  NSArray<NSNumber *> *newValues = @[ @(newX), @(newY) ];
  KKTimeline *snap = KKProcessTimelineSnapshot();
  KKTimeline *tl = snap ? KKTimelineSettingValuesNearestFraction(
                              snap, self.laneLabel, targetFrac, newValues)
                        : nil;
  if (!tl) {
    tl = snap ? [snap copy] : [KKTimeline timeline];
    NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
    KKLane *posLane =
        [self.templateLane copy] ?: [KKLane laneWithLabel:self.laneLabel];
    posLane.enabled = NO;
    posLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    [lanes addObject:posLane];
    tl.lanes = lanes;
  }

  if (self.onTimelinePersist)
    self.onTimelinePersist(tl);
  else
    KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                             kKKParamTimelineData);
  [actionAPI endAction:self];
  if (forceUpdate)
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
  static const float anchors[] = {0.0f, 0.25f, 0.5f, 0.75f, 1.0f};
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  NSInteger best = -1;
  if (kps.count > 0) {
    double bd = 1e9;
    for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
      double d = fabs(kps[k].time - frac);
      if (d < bd) {
        bd = d;
        best = k;
      }
    }
  }
  // Skip the edited keypose AND its hold-linked twins: a coincident keypose
  // joined by a linked interval moves WITH the drag, so it's the same point -
  // leaving it in would snap the anchor to itself.
  NSMutableIndexSet *skip = [NSMutableIndexSet indexSet];
  if (best >= 0) {
    [skip addIndex:(NSUInteger)best];
    for (NSInteger i = best;
         i + 1 < (NSInteger)kps.count && kps[i].outgoing.endpointsLinked; i++)
      [skip addIndex:(NSUInteger)(i + 1)];
    for (NSInteger i = best; i > 0 && kps[i - 1].outgoing.endpointsLinked; i--)
      [skip addIndex:(NSUInteger)(i - 1)];
  }
  NSUInteger nObj = 0;
  simd_float2 *objs =
      kps.count ? malloc(kps.count * sizeof(simd_float2)) : NULL;
  for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
    if ([skip containsIndex:(NSUInteger)k])
      continue;
    NSArray<NSNumber *> *v = kps[k].values;
    if (v.count < 2)
      continue;
    objs[nObj++] =
        (simd_float2){(float)v[0].doubleValue, (float)v[1].doubleValue};
  }
  CGPoint o0 = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint o1 = [self canvasPointFromObjectPoint:(simd_float2){1, 0}];
  float pxPerUnit = (float)fabs(o1.x - o0.x);
  float thr = (pxPerUnit > 0) ? self.snapEngine.threshold / pxPerUnit : 0.005f;
  simd_float2 snapped = [self.snapEngine snapPoint:p
                                    canvasAnchorsX:anchors
                                            countX:5
                                    canvasAnchorsY:anchors
                                            countY:5
                                     objectTargets:objs
                                             count:nObj
                                        thresholdX:thr
                                        thresholdY:thr];
  if (objs)
    free(objs);
  return snapped;
}

// Double-click toggle: flip the keypose nearest `frac` between smooth and
// corner.
- (void)_toggleSmoothForFrac:(double)frac {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  [actionAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  KKTimeline *snap = KKProcessTimelineSnapshot();
  if (!setAPI || !snap) {
    [actionAPI endAction:self];
    return;
  }
  KKLane *lane = [self _positionLane];
  BOOL cur = NO;
  if (lane.keyposes.count)
    cur = lane.keyposes[KKLaneNearestKeyposeIndex(lane, frac)].spatialSmooth;
  KKTimeline *tl =
      KKTimelineSettingSpatialSmooth(snap, self.laneLabel, frac, !cur);
  if (tl) {
    if (self.onTimelinePersist)
      self.onTimelinePersist(tl);
    else
      KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                               kKKParamTimelineData);
  }
  [actionAPI endAction:self];
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
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return;
  double curX = 0, curY = 0;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_CANVAS
                          fromX:x
                          fromY:y
                        toSpace:kFxDrawingCoordinates_OBJECT
                            toX:&curX
                            toY:&curY];
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  [actionAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  KKTimeline *snap = KKProcessTimelineSnapshot();
  if (!setAPI || !snap) {
    [actionAPI endAction:self];
    return;
  }
  KKTimeline *tl = [snap copy];
  NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
  NSInteger laneIdx = NSNotFound;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++)
    if ([((KKLane *)lanes[i]).label isEqualToString:self.laneLabel]) {
      laneIdx = i;
      break;
    }
  if (laneIdx == NSNotFound) {
    [actionAPI endAction:self];
    return;
  }
  KKLane *posLane = [lanes[laneIdx] copy];
  NSArray<KKKeyPose *> *kps = posLane.keyposes;
  if (kps.count == 0) {
    [actionAPI endAction:self];
    return;
  }
  NSInteger best = KKLaneNearestKeyposeIndex(posLane, self.dragHandleFrac);
  NSMutableArray<KKKeyPose *> *out = [NSMutableArray arrayWithArray:kps];
  KKKeyPose *nk = [out[best] copy];
  double ax = nk.values[0].doubleValue, ay = nk.values[1].doubleValue;
  double dx = curX - ax, dy = curY - ay;
  // Shift: axis-lock to the dominant axis (horizontal or vertical tangent).
  if (modifiers & kFxModifierKey_SHIFT) {
    if (fabs(dx) >= fabs(dy))
      dy = 0.0;
    else
      dx = 0.0;
  }
  // Cmd: snap the handle's angle to 45-degree increments (length preserved).
  if (modifiers & kFxModifierKey_COMMAND) {
    double len = hypot(dx, dy);
    if (len > 1e-9) {
      double step = M_PI / 4.0;
      double ang = round(atan2(dy, dx) / step) * step;
      dx = cos(ang) * len;
      dy = sin(ang) * len;
    }
  }
  NSArray<NSNumber *> *off = @[ @(dx), @(dy) ];
  NSArray<NSNumber *> *mirror = @[ @(-dx), @(-dy) ];
  // Ctrl breaks the tangent into a cusp (in/out independent); otherwise the
  // opposite side mirrors for a smooth curve. Ctrl is safe mid-drag - it only
  // opens a context menu on a fresh Ctrl-click, not once a drag is under way.
  BOOL cusp = (modifiers & kFxModifierKey_CONTROL) != 0;
  nk.spatialSmooth = YES;
  if (self.dragHandleIsOut) {
    nk.outHandle = off;
    if (!cusp)
      nk.inHandle = mirror;
  } else {
    nk.inHandle = off;
    if (!cusp)
      nk.outHandle = mirror;
  }
  out[best] = nk;
  posLane.keyposes = out;
  lanes[laneIdx] = posLane;
  tl.lanes = lanes;
  if (self.onTimelinePersist)
    self.onTimelinePersist(tl);
  else
    KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                             kKKParamTimelineData);
  [actionAPI endAction:self];
  if (forceUpdate)
    *forceUpdate = YES;
}

- (NSArray<NSString *> *)oscElementKeys {
  return @[ self.laneLabel, self.pathLabel ];
}

@end
