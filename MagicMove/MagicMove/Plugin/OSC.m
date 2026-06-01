/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC.h"
#import "Constants.h"
#import "Plugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <simd/simd.h>

static NSInteger const kOSCPositionPart = 1;
static NSInteger const kOSCRotationPart = 2;
static NSInteger const kOSCPathHandlePart = 3;

static KKLane *_laneNamed(NSString *label) {
  for (KKLane *lane in KKProcessTimelineSnapshot().lanes)
    if ([lane.label isEqualToString:label])
      return lane;
  return nil;
}

static KKLane *_positionLane(void) { return _laneNamed(@"Position"); }
static KKLane *_rotationLane(void) { return _laneNamed(@"Rotation"); }

static BOOL _positionVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_positionLane(), frac,
                                 KKProcessFrameDurationSeconds());
}
static BOOL _rotationVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_rotationLane(), frac,
                                 KKProcessFrameDurationSeconds());
}

static NSArray<NSNumber *> *_positionValuesAtFraction(double frac) {
  KKLane *lane = _positionLane();
  if (!lane)
    return @[ @0.5, @0.5 ];
  // Raw (un-rounded) value so the arc handle lands exactly on the keypose
  // anchors, which are drawn from raw kp.values. The Smoothed variant
  // corner-rounds at interior joins, which pulled the handle off the active
  // anchor (the mini-canvas already uses the raw value, hence stays aligned).
  NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, frac);
  return v.count >= 2 ? v : @[ @0.5, @0.5 ];
}

// (rotX, rotY, rotZ) in DEGREES (matches storage).
static NSArray<NSNumber *> *_rotationValuesAtFraction(double frac) {
  KKLane *lane = _rotationLane();
  if (!lane)
    return @[ @0.0, @0.0, @0.0 ];
  NSArray<NSNumber *> *v =
      KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  if (v.count >= 3)
    return v;
  NSMutableArray *out = [NSMutableArray arrayWithArray:v];
  while (out.count < 3)
    [out addObject:@0.0];
  return out;
}

@interface MagicMoveOSC ()
@property(nonatomic, retain) KKSnapEngine *snapEngine;
@property(nonatomic, retain) KKRotationOSC *rotationOSC;
@property(nonatomic, retain) KKPointOSC *anchorOSC;
@property(nonatomic, retain) KKPointOSC *handleOSC;
/// YES while the user holds Cmd during a position drag - snaps to canvas
/// anchors and other keypose positions. Default is free (no snap) so the
/// user can position pixel-precisely without fighting the engine.
@property(nonatomic) BOOL cmdSnapActive;
/// Object-space position captured at position-drag mouseDown. Used as the
/// anchor for Shift axis-lock: the locked axis stays pinned to this value,
/// the dominant axis tracks the cursor.
@property(nonatomic) simd_float2 posPressObject;
/// Time (0–1) of the keypose anchor the user grabbed for a position drag, or
/// NaN to edit the keypose nearest the playhead (handle drag / on-keypose
/// press) - the prior behaviour.
@property(nonatomic) double dragAnchorFrac;
/// Set by the hit-test: YES when the hovered position target is a keypose
/// anchor dot rather than the playhead arc handle (both report
/// kOSCPositionPart). Keeps the arc from lighting up when you hover an anchor.
@property(nonatomic) BOOL hoverTargetIsAnchor;
/// Time (0–1) of the keypose whose tangent handle is being dragged (NaN = none)
/// and which side. Set on mouseDown for kOSCPathHandlePart.
@property(nonatomic) double dragHandleFrac;
@property(nonatomic) BOOL dragHandleIsOut;
/// Wall-clock + keypose of the last position press, for active-part
/// double-click detection (FCP gives no reliable clickCount in the viewer).
@property(nonatomic) double lastClickTime;
@property(nonatomic) double lastClickFrac;
/// Grabbed keypose's object value at press, for delta-based dragging (so a
/// press off the dot centre doesn't jump the keypose to the cursor).
@property(nonatomic) double posGrabValX;
@property(nonatomic) double posGrabValY;
@property(nonatomic)
    CGPoint rotPressCanvas;            // canvas pixel where rot drag began
@property(nonatomic) double rotPressX; // rotation values (rad) at press
@property(nonatomic) double rotPressY;
@property(nonatomic) double rotPressZ;
// Per-drag continuity anchor: last-written Euler values. The Euler
// decomposition has two valid reps and as drag accumulates past ~270° the
// "nearest to press" rule starts picking the wrong one (because press is
// far away). Using the previous tick's output as the anchor keeps the
// per-tick angular step small and unambiguous.
@property(nonatomic) double rotLastWrittenX;
@property(nonatomic) double rotLastWrittenY;
@property(nonatomic) double rotLastWrittenZ;
@end

@implementation MagicMoveOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    _snapEngine = [[KKSnapEngine alloc] init];
    _rotationOSC = [[KKRotationOSC alloc] initWithAPIManager:apiManager];
    _anchorOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    // Match the crop/radius points in Rounded so the anchors are easy to hit.
    _anchorOSC.oscRadius = 7.0f;
    _anchorOSC.outlineWidth = 2.0f;
    // Must not clear the destination, or each dot wipes the path line and the
    // previously-drawn anchors (leaving only the last point).
    _anchorOSC.clearsOnDraw = NO;
    _handleOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    _handleOSC.oscRadius = 5.0f;
    _handleOSC.outlineWidth = 1.5f;
    _handleOSC.clearsOnDraw = NO;
    _dragAnchorFrac = NAN;
    _dragHandleFrac = NAN;
    _lastClickTime = -1.0;
    _lastClickFrac = NAN;
  }
  return self;
}

// Set the rotation rings' per-axis show + ghost-alpha for this frame, and
// report whether the sphere should be drawn / hit-tested at all. A ring is
// fully shown when the Rotation master and its own element are on; opt-reveal
// exposes a hidden ring as a dimmed (0.3), still-hittable ghost so an opt-click
// can re-show it. Ghosts only appear where the rotation OSC would normally be
// on screen at this playhead.
- (BOOL)_configureRotationRingsAtFraction:(double)frac dragging:(BOOL)dragging {
  BOOL shownHere = _rotationVisibleAtFraction(frac);
  BOOL activeHere = shownHere || dragging;
  BOOL master = [self kkOSCElementVisible:@"Rotation"];
  BOOL xEn = master && [self kkOSCElementVisible:@"Rotation.X"];
  BOOL yEn = master && [self kkOSCElementVisible:@"Rotation.Y"];
  BOOL zEn = master && [self kkOSCElementVisible:@"Rotation.Z"];
  BOOL reveal = self.optRevealActive && shownHere;
  BOOL xShow = (xEn && activeHere) || reveal;
  BOOL yShow = (yEn && activeHere) || reveal;
  BOOL zShow = (zEn && activeHere) || reveal;
  self.rotationOSC.showX = xShow;
  self.rotationOSC.showY = yShow;
  self.rotationOSC.showZ = zShow;
  self.rotationOSC.ringAlphaX = xEn ? 1.0f : 0.3f;
  self.rotationOSC.ringAlphaY = yEn ? 1.0f : 0.3f;
  self.rotationOSC.ringAlphaZ = zEn ? 1.0f : 0.3f;
  return dragging || xShow || yShow || zShow;
}

// Pull X/Y/Z ring colors from the Rotation lane's `componentLabelColors`
// (already red/green/blue in the timeline) so OSC matches the inspector.
- (void)_syncRotationColorsFromLane {
  KKLane *lane = _rotationLane();
  if (lane.componentLabelColors.count >= 3) {
    self.rotationOSC.colorX = lane.componentLabelColors[0];
    self.rotationOSC.colorY = lane.componentLabelColors[1];
    self.rotationOSC.colorZ = lane.componentLabelColors[2];
  }
}

- (double)_fractionAtTime:(CMTime)time {
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!timingAPI)
    return 0.0;
  CMTime effectStart = kCMTimeZero, effectDur = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDur];
  double durSec = CMTimeGetSeconds(effectDur);
  if (durSec <= 0)
    return 0.0;
  return MAX(0.0,
             MIN(1.0, (CMTimeGetSeconds(time) - CMTimeGetSeconds(effectStart)) /
                          durSec));
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return CGPointZero;
  NSArray<NSNumber *> *vals =
      _positionValuesAtFraction([self _fractionAtTime:time]);
  double objX = vals[0].doubleValue;
  double objY = vals[1].doubleValue;
  CGPoint canvas = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:objX
                          fromY:objY
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&canvas.x
                            toY:&canvas.y];
  return canvas;
}

// Snap the live drag position against canvas edges (0/1), the centre (0.5),
// thirds (0.25/0.75), and every other keypose's stored position. Object
// space; threshold defaults to ~8 canvas pixels via KKSnapEngine.
- (simd_float2)_snapPosition:(simd_float2)p atFraction:(double)frac {
  KKLane *lane = nil;
  for (KKLane *l in KKProcessTimelineSnapshot().lanes)
    if ([l.label isEqualToString:@"Position"]) {
      lane = l;
      break;
    }
  static const float anchors[] = {0.0f, 0.25f, 0.5f, 0.75f, 1.0f};
  // Skip the keypose being edited (closest to playhead frac - drag overwrites
  // it, so snapping back to it would lock the handle in place).
  NSInteger best = -1;
  if (lane.keyposes.count > 0) {
    double bd = 1e9;
    for (NSInteger k = 0; k < (NSInteger)lane.keyposes.count; k++) {
      double d = fabs(lane.keyposes[k].time - frac);
      if (d < bd) {
        bd = d;
        best = k;
      }
    }
  }
  NSUInteger nObj = 0;
  simd_float2 *objs = lane.keyposes.count
                          ? malloc(lane.keyposes.count * sizeof(simd_float2))
                          : NULL;
  for (NSInteger k = 0; k < (NSInteger)lane.keyposes.count; k++) {
    if (k == best)
      continue;
    NSArray<NSNumber *> *v = lane.keyposes[k].values;
    if (v.count < 2)
      continue;
    objs[nObj++] =
        (simd_float2){(float)v[0].doubleValue, (float)v[1].doubleValue};
  }
  // One object unit spans one image width in canvas pixels.
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

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  [self kkResetOptHideArming];
  [self.snapEngine reset];
  self.dragAnchorFrac = NAN;
  self.dragHandleFrac = NAN;
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

// Read-only motion path: the trajectory the clip's centre travels across the
// whole effect, sampled from the SAME evaluator the render uses
// (KKTimelineLaneValueAtVisualFractionSmoothed) so the line matches the clip's
// motion exactly, curved segments included. Object→canvas via the OSC API, the
// same mapping the Position handle uses.
- (void)_drawPositionPathToDestination:(FxImageTile *)destinationImage
                            ghostAlpha:(float)ghostAlpha {
  KKLane *lane = _positionLane();
  if (!lane || lane.keyposes.count < 2)
    return;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return;
  // Geometric route (no temporal easing), so overshooting easing curves don't
  // draw loops on the path - the line is the spatial trajectory, not the
  // timing dynamics (which are felt in playback).
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

// Tangent handles for every smooth keypose: a thin connector from the anchor to
// a small dot at the effective handle position (manual, or the auto Catmull-Rom
// tangent the curve uses). An endpoint's missing side is a zero-length handle
// and is skipped.
- (void)_drawHandlesToDestination:(FxImageTile *)destinationImage
                           atTime:(CMTime)time
                       ghostAlpha:(float)ghostAlpha {
  KKLane *lane = _positionLane();
  if (!lane || lane.keyposes.count < 2)
    return;
  self.handleOSC.ghostAlpha = ghostAlpha;
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
      [self.handleOSC drawAtCanvasPosition:hCanvas
                                 isHovered:NO
                                  isActive:NO
                          destinationImage:destinationImage
                                    atTime:time];
    }
  }
}

// A small dot at every Position keypose - the draggable anchors of the path.
// Drawn over the path line, under the playhead handle. The keypose under the
// playhead is skipped when `skipActive` (the big arc handle covers it, so its
// dot would be a redundant point inside the arc).
- (void)_drawKeyposeAnchorsToDestination:(FxImageTile *)destinationImage
                                  atTime:(CMTime)time
                                skipFrac:(double)skipFrac
                              skipActive:(BOOL)skipActive
                              ghostAlpha:(float)ghostAlpha {
  KKLane *lane = _positionLane();
  if (!lane || lane.keyposes.count < 2)
    return;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return;
  self.anchorOSC.ghostAlpha = ghostAlpha;
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
  // Linked keyposes share the active one's position; KKLaneCoalescedAnchors
  // drops it and any coincident partner (so they collapse under the position
  // handle) and dedups the rest. Returns object-space points to convert + draw.
  for (NSValue *pv in KKLaneCoalescedAnchors(lane, skipIdx)) {
    NSPoint v = pv.pointValue;
    CGPoint c = CGPointZero;
    [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                            fromX:v.x
                            fromY:v.y
                          toSpace:kFxDrawingCoordinates_CANVAS
                              toX:&c.x
                              toY:&c.y];
    [self.anchorOSC drawAtCanvasPosition:c
                               isHovered:NO
                                isActive:NO
                        destinationImage:destinationImage
                                  atTime:time];
  }
}

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

// Double-click toggle: flip the keypose nearest `frac` between smooth (bezier)
// and corner (linear). Reuses the kit's nearest-match writer.
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
  KKLane *lane = _positionLane();
  BOOL cur = NO;
  if (lane.keyposes.count) {
    NSInteger best = 0;
    double bd = 1e9;
    for (NSInteger k = 0; k < (NSInteger)lane.keyposes.count; k++) {
      double d = fabs(lane.keyposes[k].time - frac);
      if (d < bd) {
        bd = d;
        best = k;
      }
    }
    cur = lane.keyposes[best].spatialSmooth;
  }
  KKTimeline *tl =
      KKTimelineSettingSpatialSmooth(snap, @"Position", frac, !cur);
  if (tl)
    KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                             kKKParamTimelineData);
  [actionAPI endAction:self];
}

// Drag a tangent handle: set the dragged keypose's in/out handle to the cursor
// offset from the anchor (object space). First drag materialises the auto
// tangent into a manual one. In/out are independent (no mirroring yet).
- (void)_dragHandleToPositionX:(double)positionX
                     positionY:(double)positionY
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
                          fromX:positionX
                          fromY:positionY
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
    if ([((KKLane *)lanes[i]).label isEqualToString:@"Position"]) {
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
  NSInteger best = 0;
  double bd = 1e9;
  for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
    double d = fabs(kps[k].time - self.dragHandleFrac);
    if (d < bd) {
      bd = d;
      best = k;
    }
  }
  NSMutableArray<KKKeyPose *> *out = [NSMutableArray arrayWithArray:kps];
  KKKeyPose *nk = [out[best] copy];
  double ax = nk.values[0].doubleValue, ay = nk.values[1].doubleValue;
  double dx = curX - ax, dy = curY - ay;
  NSArray<NSNumber *> *off = @[ @(dx), @(dy) ];
  NSArray<NSNumber *> *mirror = @[ @(-dx), @(-dy) ];
  // Symmetric by default (the opposite handle mirrors); Shift breaks the
  // tangent so each side moves independently (allowing a cusp).
  BOOL shift = (modifiers & kFxModifierKey_SHIFT) != 0;
  nk.spatialSmooth = YES;
  if (self.dragHandleIsOut) {
    nk.outHandle = off;
    if (!shift)
      nk.inHandle = mirror;
  } else {
    nk.inHandle = off;
    if (!shift)
      nk.outHandle = mirror;
  }
  out[best] = nk;
  posLane.keyposes = out;
  lanes[laneIdx] = posLane;
  tl.lanes = lanes;
  KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                           kKKParamTimelineData);
  [actionAPI endAction:self];
  if (forceUpdate)
    *forceUpdate = YES;
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  // Clear the draw surface (the encode call is a no-op draw but resets the
  // attachment) so the handle is the only thing visible.
  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  double frac = [self _fractionAtTime:time];
  BOOL posShownHere = _positionVisibleAtFraction(frac);
  BOOL posEnabled = [self kkOSCElementVisible:@"Position"];
  // The arc handle is the position target only when the interaction is the
  // handle itself, not a grabbed keypose anchor (both report kOSCPositionPart).
  // Drag: dragAnchorFrac is NaN for the handle. Hover: hoverTargetIsAnchor was
  // set by the hit-test.
  BOOL handleTargeted = (activePart == kOSCPositionPart) &&
                        (self.isDragging ? isnan(self.dragAnchorFrac)
                                         : !self.hoverTargetIsAnchor);
  BOOL draggingHandle = self.isDragging && handleTargeted;
  BOOL posVisible = draggingHandle || (posEnabled && posShownHere);
  // Opt-hold reveals a hidden Position handle as a dimmed ghost (clickable to
  // re-show); only when it would otherwise be on screen at this playhead.
  BOOL posGhost =
      !posVisible && self.optRevealActive && !posEnabled && posShownHere;

  // The motion path (line + anchors + handles) is a SEPARATE hideable OSC from
  // the Position arc handle. Opt-hold reveals a hidden path as a dimmed ghost.
  BOOL pathEnabled = [self kkOSCElementVisible:@"Path"];
  BOOL pathReveal = !pathEnabled && self.optRevealActive;
  if (pathEnabled || pathReveal) {
    float pg = pathEnabled ? 1.0f : 0.3f;
    [self _drawPositionPathToDestination:destinationImage ghostAlpha:pg];
    [self _drawHandlesToDestination:destinationImage atTime:time ghostAlpha:pg];
    [self _drawKeyposeAnchorsToDestination:destinationImage
                                    atTime:time
                                  skipFrac:frac
                                skipActive:posVisible
                                ghostAlpha:pg];
  }

  CGPoint pos = [self oscPositionAtTime:time];
  if (posVisible || posGhost) {
    self.fillAlpha = posGhost ? 0.3f : 1.0f;
    [self drawAtCanvasPosition:pos
                     isHovered:handleTargeted
                      isActive:draggingHandle
              destinationImage:destinationImage
                        atTime:time];
  }

  // Rotation sphere is centred on the same canvas point as Position (the
  // image rotates around its centre, which is where Position translates it).
  BOOL rotDragging = self.isDragging && activePart == kOSCRotationPart;
  if ([self _configureRotationRingsAtFraction:frac dragging:rotDragging]) {
    [self _syncRotationColorsFromLane];
    NSArray<NSNumber *> *r = _rotationValuesAtFraction(frac);
    self.rotationOSC.rotX = (float)(r[0].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotY = (float)(r[1].doubleValue * M_PI / 180.0);
    self.rotationOSC.rotZ = (float)(r[2].doubleValue * M_PI / 180.0);
    self.rotationOSC.center = pos;
    [self.rotationOSC
        drawAtCanvasPosition:pos
                   isHovered:(activePart == kOSCRotationPart)
                    isActive:self.isDragging && (activePart == kOSCRotationPart)
            destinationImage:destinationImage
                      atTime:time];
  }
  if (self.isDragging && activePart == kOSCPositionPart && self.cmdSnapActive) {
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

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  self.hoverTargetIsAnchor = NO;
  double frac = [self _fractionAtTime:time];
  // Tangent handles sit on top of the path - grab them before the arc/anchors.
  if (([self kkOSCElementVisible:@"Path"] || self.optRevealActive) &&
      [self _handleHitAtCanvasX:positionX
                              y:positionY
                        outFrac:NULL
                       outIsOut:NULL]) {
    *activePart = kOSCPathHandlePart;
    return;
  }
  // Opt-reveal makes a hidden handle hit-testable so an opt-click re-shows it.
  BOOL posReachable =
      ([self kkOSCElementVisible:@"Position"] || self.optRevealActive) &&
      _positionVisibleAtFraction(frac);
  if (posReachable && [self hitTestAtMousePositionX:positionX
                                          positionY:positionY
                                             atTime:time]) {
    *activePart = kOSCPositionPart;
    return;
  }
  // Any keypose anchor dot is grabbable, independent of the playhead - so a
  // keypose's position can be dragged without first scrubbing onto it.
  if (([self kkOSCElementVisible:@"Path"] || self.optRevealActive) &&
      !isnan([self _anchorFracNearCanvasX:positionX y:positionY])) {
    self.hoverTargetIsAnchor = YES;
    *activePart = kOSCPositionPart;
    return;
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

// Override the base OSC-visibility hooks: the full element-key list, and the
// per-part mapping (granular for rotation rings - the preceding hit-test left
// the hit ring in rotationOSC.activeAxis). The toggle / arming / reveal / blob
// persistence all live in KKOnScreenControl now.
- (NSArray<NSString *> *)oscElementKeys {
  return [MagicMovePlugin oscElementKeys];
}

- (nullable NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  if (activePart == kOSCPathHandlePart)
    return @"Path";
  if (activePart == kOSCPositionPart)
    return self.hoverTargetIsAnchor ? @"Path" : @"Position";
  if (activePart == kOSCRotationPart) {
    switch (self.rotationOSC.activeAxis) {
    case 0:
      return @"Rotation.X";
    case 1:
      return @"Rotation.Y";
    case 2:
      return @"Rotation.Z";
    default:
      return @"Rotation";
    }
  }
  return nil;
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
  if (activePart == kOSCPositionPart) {
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
      self.posPressObject = (simd_float2){(float)objX, (float)objY};
    }
    // Target the grabbed keypose anchor; NaN when the press is the playhead
    // handle (or on the keypose under it) so the drag rewrites the keypose
    // nearest the playhead, exactly as before.
    double pressFrac = [self _fractionAtTime:time];
    BOOL onHandle = _positionVisibleAtFraction(pressFrac) &&
                    [self hitTestAtMousePositionX:positionX
                                        positionY:positionY
                                           atTime:time];
    self.dragAnchorFrac =
        onHandle ? NAN : [self _anchorFracNearCanvasX:positionX y:positionY];
    // Active-part double-click: two presses on the same keypose within 0.4s
    // toggle it smooth↔corner (the viewer gives no reliable clickCount).
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
    // Capture the grabbed keypose's value for delta-based dragging.
    self.posGrabValX = self.posPressObject.x;
    self.posGrabValY = self.posPressObject.y;
    KKLane *pl = _positionLane();
    if (pl.keyposes.count) {
      NSInteger b = 0;
      double bd = 1e9;
      for (NSInteger k = 0; k < (NSInteger)pl.keyposes.count; k++) {
        double d = fabs(pl.keyposes[k].time - clickFrac);
        if (d < bd) {
          bd = d;
          b = k;
        }
      }
      NSArray<NSNumber *> *v = pl.keyposes[b].values;
      if (v.count >= 2) {
        self.posGrabValX = v[0].doubleValue;
        self.posGrabValY = v[1].doubleValue;
      }
    }
  }
  if (activePart == kOSCPathHandlePart) {
    double hf = NAN;
    BOOL hOut = NO;
    if ([self _handleHitAtCanvasX:positionX
                                y:positionY
                          outFrac:&hf
                         outIsOut:&hOut]) {
      self.dragHandleFrac = hf;
      self.dragHandleIsOut = hOut;
    }
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
    if (rotLane.keyposes.count > 0) {
      NSInteger best = 0;
      double bd = 1e9;
      for (NSInteger k = 0; k < (NSInteger)rotLane.keyposes.count; k++) {
        double d = fabs(rotLane.keyposes[k].time - frac);
        if (d < bd) {
          bd = d;
          best = k;
        }
      }
      r = rotLane.keyposes[best].values;
    }
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
    [self _dragHandleToPositionX:positionX
                       positionY:positionY
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
  if (activePart != kOSCPositionPart)
    return;

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
  // Delta-based drag: move by the cursor's offset from the grab point, so the
  // keypose doesn't jump to the cursor when grabbed off the dot centre.
  double newX = self.posGrabValX + (curX - (double)self.posPressObject.x);
  double newY = self.posGrabValY + (curY - (double)self.posPressObject.y);

  // Shift axis-lock: pin whichever axis has less travel from the press
  // point, so the cursor controls the dominant axis only. Decided per
  // tick so the user can change their mind mid-drag.
  if (modifiers & kFxModifierKey_SHIFT) {
    double dx = curX - (double)self.posPressObject.x;
    double dy = curY - (double)self.posPressObject.y;
    if (fabs(dx) >= fabs(dy))
      newY = self.posGrabValY;
    else
      newX = self.posGrabValX;
  }

  // Snap is OFF by default; Cmd engages it. Free-by-default keeps
  // pixel-precise positioning quiet, and matches the rotation OSC where
  // Cmd snaps to 15deg.
  self.cmdSnapActive = (modifiers & kFxModifierKey_COMMAND) != 0;
  double frac = [self _fractionAtTime:time];
  // The keypose this drag edits: the grabbed anchor, or the one nearest the
  // playhead when dragging the handle (dragAnchorFrac == NaN).
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

  // Snapshot is canonical - the param read returns empty inside the OSC
  // action scope. Copy then mutate the Position lane's keypose nearest the
  // current playhead fraction, preserving structure / intervals.
  KKTimeline *snap = KKProcessTimelineSnapshot();
  KKTimeline *tl = snap ? [snap copy] : [KKTimeline timeline];
  NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
  NSInteger laneIdx = NSNotFound;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([((KKLane *)lanes[i]).label isEqualToString:@"Position"]) {
      laneIdx = i;
      break;
    }
  }

  NSArray<NSNumber *> *newValues = @[ @(newX), @(newY) ];
  KKLane *posLane;
  if (laneIdx == NSNotFound) {
    posLane = [KKLane laneWithLabel:@"Position"];
    posLane.valueType = KKLaneValueTypeGeneric;
    posLane.componentMin = @[];
    posLane.componentMax = @[];
    posLane.componentUnits = @[ @"px", @"px" ];
    posLane.componentLabels = @[ @"X", @"Y" ];
    posLane.enabled = NO;
    posLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    [lanes addObject:posLane];
  } else {
    posLane = [lanes[laneIdx] copy];
    NSArray<KKKeyPose *> *kps = posLane.keyposes;
    if (kps.count == 0) {
      posLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    } else {
      NSInteger best = 0;
      double bd = 1e9;
      for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
        double d = fabs(kps[k].time - targetFrac);
        if (d < bd) {
          bd = d;
          best = k;
        }
      }
      NSMutableArray<KKKeyPose *> *out = [NSMutableArray arrayWithArray:kps];
      // Copy-and-update (not reconstruct) so per-keypose fields beyond
      // time/values/outgoing - spatialSmooth + in/out handles - survive a
      // position drag instead of resetting the keypose to a linear corner.
      KKKeyPose *nk = [out[best] copy];
      nk.values = newValues;
      out[best] = nk;
      // Hold-link propagation: a linked endpoint shares its partner's value.
      if (best + 1 < (NSInteger)out.count && nk.outgoing.endpointsLinked) {
        KKKeyPose *np = [out[best + 1] copy];
        np.values = newValues;
        out[best + 1] = np;
      }
      if (best > 0) {
        if (out[best - 1].outgoing.endpointsLinked) {
          KKKeyPose *np = [out[best - 1] copy];
          np.values = newValues;
          out[best - 1] = np;
        }
      }
      posLane.keyposes = out;
    }
    lanes[laneIdx] = posLane;
  }
  tl.lanes = lanes;

  KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                           kKKParamTimelineData);
  [actionAPI endAction:self];
  *forceUpdate = YES;
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

  KKTimeline *snap = KKProcessTimelineSnapshot();
  KKTimeline *tl = snap ? [snap copy] : [KKTimeline timeline];
  NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
  NSInteger laneIdx = NSNotFound;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([((KKLane *)lanes[i]).label isEqualToString:@"Rotation"]) {
      laneIdx = i;
      break;
    }
  }
  double frac = [self _fractionAtTime:time];
  KKLane *rotLane;
  if (laneIdx == NSNotFound) {
    rotLane = [KKLane laneWithLabel:@"Rotation"];
    rotLane.valueType = KKLaneValueTypeGeneric;
    rotLane.componentUnits = @[ @"°", @"°", @"°" ];
    rotLane.componentLabels = @[ @"X", @"Y", @"Z" ];
    rotLane.enabled = NO;
    rotLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    [lanes addObject:rotLane];
  } else {
    rotLane = [lanes[laneIdx] copy];
    NSArray<KKKeyPose *> *kps = rotLane.keyposes;
    if (kps.count == 0) {
      rotLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    } else {
      NSInteger best = 0;
      double bd = 1e9;
      for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
        double d = fabs(kps[k].time - frac);
        if (d < bd) {
          bd = d;
          best = k;
        }
      }
      NSMutableArray<KKKeyPose *> *out = [NSMutableArray arrayWithArray:kps];
      double oldTime = out[best].time;
      KKInterval *oldOutgoing = out[best].outgoing;
      KKKeyPose *nk = [KKKeyPose keyposeAtTime:oldTime values:newValues];
      nk.outgoing = oldOutgoing;
      out[best] = nk;
      if (best + 1 < (NSInteger)out.count && nk.outgoing.endpointsLinked) {
        KKKeyPose *partner = out[best + 1];
        KKKeyPose *np = [KKKeyPose keyposeAtTime:partner.time values:newValues];
        np.outgoing = partner.outgoing;
        out[best + 1] = np;
      }
      if (best > 0) {
        KKKeyPose *prev = out[best - 1];
        if (prev.outgoing.endpointsLinked) {
          KKKeyPose *np = [KKKeyPose keyposeAtTime:prev.time values:newValues];
          np.outgoing = prev.outgoing;
          out[best - 1] = np;
        }
      }
      rotLane.keyposes = out;
    }
    lanes[laneIdx] = rotLane;
  }
  tl.lanes = lanes;

  KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                           kKKParamTimelineData);
  [actionAPI endAction:self];
  *forceUpdate = YES;
}

@end
