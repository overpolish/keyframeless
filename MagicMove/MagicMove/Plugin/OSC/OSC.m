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
static NSInteger const kOSCScalePart = 4;
static NSInteger const kOSCAnchorPart = 5;

// Scale box handle indices: 0-3 corners (BL, BR, TR, TL), 4-7 edge midpoints
// (bottom, right, top, left). Corners drive both axes; bottom/top drive Y,
// right/left drive X.
static inline BOOL kScaleHandleIsCorner(NSInteger h) {
  return h >= 0 && h <= 3;
}
static inline BOOL kScaleHandleControlsX(NSInteger h) {
  return kScaleHandleIsCorner(h) || h == 5 || h == 7;
}
static inline BOOL kScaleHandleControlsY(NSInteger h) {
  return kScaleHandleIsCorner(h) || h == 4 || h == 6;
}

static KKLane *_laneNamed(NSString *label) {
  for (KKLane *lane in KKProcessTimelineSnapshot().lanes)
    if ([lane.label isEqualToString:label])
      return lane;
  return nil;
}

static KKLane *_positionLane(void) { return _laneNamed(@"Position"); }
static KKLane *_rotationLane(void) { return _laneNamed(@"Rotation"); }
static KKLane *_scaleLane(void) { return _laneNamed(@"Scale"); }
static KKLane *_anchorLane(void) { return _laneNamed(@"Anchor"); }

// Scale gizmo half-extent as a fraction of the clip's on-screen frame, so the
// box tracks the clip (scales with viewer zoom) instead of being a fixed screen
// size. e0 = 0% half-extent, span = the 0->100% growth; >100% sqrt-compresses
// (see KKScaleGizmo). Same proportion as the mini-canvas box.
static const double kScaleGizmoE0Frac = 0.12;
static const double kScaleGizmoSpanFrac = 0.057;

// Scale drag is absolute: the grabbed handle tracks the cursor (deterministic,
// in sync), mapping cursor distance to centre back through the gizmo curve.
// Holding Cmd engages a fine mode that scales cursor movement down for precise
// adjustment (essential at high scale, where the compressed box is otherwise
// hyper-sensitive).
static const double kScaleFineFactor = 0.2;

static BOOL _positionVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_positionLane(), frac,
                                 KKProcessFrameDurationSeconds());
}
static BOOL _rotationVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_rotationLane(), frac,
                                 KKProcessFrameDurationSeconds());
}
static BOOL _scaleVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_scaleLane(), frac,
                                 KKProcessFrameDurationSeconds());
}
static BOOL _anchorVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_anchorLane(), frac,
                                 KKProcessFrameDurationSeconds());
}

// (anchorX, anchorY) in normalized object space (0.5,0.5 = clip center),
// defaulting to centre when the lane is absent.
static NSArray<NSNumber *> *_anchorValuesAtFraction(double frac) {
  KKLane *lane = _anchorLane();
  // No lane, or a lane present in the cold-boot snapshot with no keyposes yet
  // (untouched Anchor on a fresh instance): default to centre. Without the
  // keypose-count guard the evaluator returns [0,0] for an empty lane, which
  // drew the pivot square at the left edge even though the inspector lane shows
  // the real 0.5,0.5 default.
  if (!lane || lane.keyposes.count == 0)
    return @[ @0.5, @0.5 ];
  NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, frac);
  return v.count >= 2 ? v : @[ @0.5, @0.5 ];
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

// (scaleX, scaleY) in PERCENT (100 = identity). Floored at 0 so overshoot
// easing never shows the box / readout a negative (flipped) scale.
static NSArray<NSNumber *> *_scaleValuesAtFraction(double frac) {
  KKLane *lane = _scaleLane();
  if (!lane)
    return @[ @100.0, @100.0 ];
  NSArray<NSNumber *> *v =
      KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithArray:v ?: @[]];
  while (out.count < 2)
    [out addObject:@100.0];
  out[0] = @(fmax(0.0, out[0].doubleValue));
  out[1] = @(fmax(0.0, out[1].doubleValue));
  return out;
}

// Canvas positions of the 8 scale-box handles for a given centre + scale
// percents: out[0..3] corners (BL, BR, TR, TL), out[4..7] edge midpoints
// (bottom, right, top, left). Shared by draw + hit-test so they agree.
static void KKScaleHandlePositions(CGPoint center, double sclX, double sclY,
                                   double e0, double span, CGPoint out[8]) {
  double halfW = KKScaleGizmoExtentForPercent(sclX, e0, span);
  double halfH = KKScaleGizmoExtentForPercent(sclY, e0, span);
  double l = center.x - halfW, r = center.x + halfW;
  double b = center.y - halfH, t = center.y + halfH;
  out[0] = CGPointMake(l, b);
  out[1] = CGPointMake(r, b);
  out[2] = CGPointMake(r, t);
  out[3] = CGPointMake(l, t);
  out[4] = CGPointMake(center.x, b);
  out[5] = CGPointMake(r, center.y);
  out[6] = CGPointMake(center.x, t);
  out[7] = CGPointMake(l, center.y);
}

@interface MagicMoveOSC ()
@property(nonatomic, retain) KKSnapEngine *snapEngine;
@property(nonatomic, retain) KKRotationOSC *rotationOSC;
@property(nonatomic, retain) KKPointOSC *anchorOSC;
@property(nonatomic, retain) KKPointOSC *handleOSC;
/// Scale transform-box gizmo: the shared KKBoxOSC (border + 8 corner/edge
/// handles + a "X% x Y%" readout). Sized via KKScaleGizmo from the Scale lane,
/// centred on Position, drawn outside the rotation rings.
@property(nonatomic, retain) KKBoxOSC *scaleBox;
/// Anchor-point pivot: a draggable square at the clip's rotation/scale pivot
/// (Position + Anchor offset). Snaps to the clip's center / corners / edges /
/// thirds unless Cmd is held. anchorGrabVal + anchorPressObject give it the
/// same delta-based drag as Position.
@property(nonatomic, retain) KKSquarePointOSC *anchorPointOSC;
@property(nonatomic, retain) KKSnapEngine *anchorSnap;
@property(nonatomic) BOOL anchorHovered;
@property(nonatomic) double anchorGrabValX;
@property(nonatomic) double anchorGrabValY;
@property(nonatomic) simd_float2 anchorPressObject;
/// Which scale handle (0-7) the hit-test last landed on, and the one currently
/// grabbed for a drag. -1 = none.
@property(nonatomic) NSInteger scaleHitHandle;
@property(nonatomic) NSInteger scaleGrabHandle;
/// Press state captured at scale mouseDown: the box centre (= Position) and the
/// scale percents, so the drag preserves ratio / inverts the gizmo curve from a
/// stable reference rather than tick-to-tick.
@property(nonatomic) CGPoint scalePressCenter;
@property(nonatomic) double scalePressSclX;
@property(nonatomic) double scalePressSclY;
/// Absolute drag state: the "effective" cursor canvas point that drives the
/// value (initialised to the grabbed handle so there is no press snap, then
/// moved by the raw cursor delta - scaled down while Cmd-fine is held), plus
/// the previous raw cursor for that per-tick delta. Written values round to
/// integers.
@property(nonatomic) CGPoint scaleEffCursor;
@property(nonatomic) CGPoint scaleLastCursor;
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
    _scaleBox = [[KKBoxOSC alloc] initWithAPIManager:apiManager];
    // Extra grab slack so the compact gizmo's handles stay easy to hit.
    _scaleBox.hitPadding = 6.0;
    _anchorPointOSC = [[KKSquarePointOSC alloc] initWithAPIManager:apiManager];
    _anchorPointOSC.clearsOnDraw = NO;
    _anchorSnap = [[KKSnapEngine alloc] init];
    _scaleHitHandle = -1;
    _scaleGrabHandle = -1;
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

// Min dimension of the clip's frame in canvas space (object [0,1]^2 corners
// converted to canvas). Scales with viewer zoom, so a box sized off it tracks
// the clip rather than staying a fixed screen size.
- (double)_onScreenFrameMin {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return 1000.0;
  CGPoint c0 = CGPointZero, cx = CGPointZero, cy = CGPointZero;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0
                          fromY:0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&c0.x
                            toY:&c0.y];
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:1
                          fromY:0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&cx.x
                            toY:&cx.y];
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0
                          fromY:1
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&cy.x
                            toY:&cy.y];
  double w = hypot(cx.x - c0.x, cx.y - c0.y);
  double h = hypot(cy.x - c0.x, cy.y - c0.y);
  double m = MIN(w, h);
  return (m > 1.0) ? m : 1000.0;
}

// Gizmo curve params for the current zoom: fractions of the on-screen frame.
- (void)_scaleGizmoE0:(double *)outE0 span:(double *)outSpan {
  double frameMin = [self _onScreenFrameMin];
  *outE0 = frameMin * kScaleGizmoE0Frac;
  *outSpan = frameMin * kScaleGizmoSpanFrac;
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
  [self.anchorSnap reset];
  self.anchorHovered = NO;
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

// Canvas point of the anchor pivot at a fraction: the clip centre (Position)
// shifted by the Anchor offset, in object space, mapped to canvas. The pivot
// travels with the clip, so it tracks Position as the playhead moves.
- (CGPoint)_anchorCanvasAtFraction:(double)frac {
  NSArray<NSNumber *> *pv = _positionValuesAtFraction(frac);
  NSArray<NSNumber *> *av = _anchorValuesAtFraction(frac);
  double objX = pv[0].doubleValue + av[0].doubleValue - 0.5;
  double objY = pv[1].doubleValue + av[1].doubleValue - 0.5;
  return [self _canvasFromObjX:objX y:objY];
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

// Scale transform box: border + 8 handles (4 corners, 4 edge midpoints) + a
// "X% x Y%" readout, centred on `center`. Half-extents come from the scale
// percent through the KKScaleGizmo curve (per axis), so the box is a compact
// screen-space gizmo that stays grabbable at any value rather than tracking the
// clip's real pixel bounds.
- (void)_drawScaleBoxAtCenter:(CGPoint)center
                       atTime:(CMTime)time
                   ghostAlpha:(float)ghostAlpha
                 activeHandle:(NSInteger)activeHandle
             destinationImage:(FxImageTile *)destinationImage {
  double frac = [self _fractionAtTime:time];
  NSArray<NSNumber *> *sv = _scaleValuesAtFraction(frac);
  double sclX = sv.count > 0 ? sv[0].doubleValue : 100.0;
  double sclY = sv.count > 1 ? sv[1].doubleValue : 100.0;
  double e0 = 0, span = 0;
  [self _scaleGizmoE0:&e0 span:&span];
  CGPoint handles[8];
  KKScaleHandlePositions(center, sclX, sclY, e0, span, handles);
  CGPoint bl = handles[0], tr = handles[2];

  self.scaleBox.ghostAlpha = ghostAlpha;
  NSString *readout =
      [NSString stringWithFormat:@"%.0f%% x %.0f%%", sclX, sclY];
  [self.scaleBox drawWithTopRight:tr
                       bottomLeft:bl
                          readout:readout
                     activeHandle:activeHandle
                 destinationImage:destinationImage
                           atTime:time];
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

  // Layering (bottom -> top): path, rotation, scale, position, anchor. `pos` is
  // needed by rotation/scale below, but the Position arc itself is drawn after
  // them so the arc sits on top of the rings/box and stays easy to see + grab.
  CGPoint pos = [self oscPositionAtTime:time];

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
  // Scale transform box, drawn outside the rotation rings. Only on screen where
  // the Scale lane is visible (keypose times / constant), same as Position.
  // Opt-hold reveals a hidden box as a dimmed ghost.
  BOOL scaleShownHere = _scaleVisibleAtFraction(frac);
  BOOL scaleEnabled = [self kkOSCElementVisible:@"Scale"];
  BOOL scaleDragging = self.isDragging && activePart == kOSCScalePart;
  BOOL scaleVisible = scaleDragging || (scaleEnabled && scaleShownHere);
  BOOL scaleGhost =
      !scaleVisible && self.optRevealActive && !scaleEnabled && scaleShownHere;
  if (scaleVisible || scaleGhost) {
    NSInteger activeHandle = scaleDragging ? self.scaleGrabHandle : -1;
    [self _drawScaleBoxAtCenter:pos
                         atTime:time
                     ghostAlpha:(scaleGhost ? 0.3f : 1.0f)activeHandle
                               :activeHandle
               destinationImage:destinationImage];
  }

  // Position arc handle, drawn above rotation + scale so it stays on top.
  if (posVisible || posGhost) {
    self.fillAlpha = posGhost ? 0.3f : 1.0f;
    [self drawAtCanvasPosition:pos
                     isHovered:handleTargeted
                      isActive:draggingHandle
              destinationImage:destinationImage
                        atTime:time];
  }

  // Anchor-point pivot square, at the clip's pivot (Position + Anchor offset).
  // Shown where the Anchor lane is visible (keypose times / constant), same as
  // Scale/Position; opt-hold reveals a hidden one as a dimmed ghost.
  BOOL anchorShownHere = _anchorVisibleAtFraction(frac);
  BOOL anchorEnabled = [self kkOSCElementVisible:@"Anchor"];
  BOOL anchorDragging = self.isDragging && activePart == kOSCAnchorPart;
  BOOL anchorVisible = anchorDragging || (anchorEnabled && anchorShownHere);
  BOOL anchorGhost = !anchorVisible && self.optRevealActive && !anchorEnabled &&
                     anchorShownHere;
  if (anchorVisible || anchorGhost) {
    self.anchorPointOSC.ghostAlpha = anchorGhost ? 0.3f : 1.0f;
    CGPoint ac = [self _anchorCanvasAtFraction:frac];
    [self.anchorPointOSC drawAtCanvasPosition:ac
                                    isHovered:self.anchorHovered
                                     isActive:anchorDragging
                             destinationImage:destinationImage
                                       atTime:time];
  }

  [self.anchorSnap drawSnapGuidesWithOSC:self
                           isObjectSpace:YES
                        destinationImage:destinationImage];

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
  self.anchorHovered = NO;
  self.scaleHitHandle = -1;
  double frac = [self _fractionAtTime:time];
  // Anchor pivot square is the topmost control: checked first so it is always
  // grabbable / opt-hideable. It is small, so the larger Position arc ring
  // around it stays clickable - the two coincide at the clip centre by default.
  if (([self kkOSCElementVisible:@"Anchor"] || self.optRevealActive) &&
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
  // Scale box handles sit just outside the rotation rings; check them before
  // rotation so an edge handle near the ring radius wins over the ring. Only
  // reachable where the box is shown (or opt-reveal exposes a hidden one).
  BOOL scaleReachable =
      ([self kkOSCElementVisible:@"Scale"] || self.optRevealActive) &&
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
  KKScaleHandlePositions(center, sclX, sclY, e0, span, handles);
  NSInteger part = [self.scaleBox hitTestAtX:x
                                           y:y
                                    topRight:handles[2]
                                  bottomLeft:handles[0]];
  return part >= KKBoxPartHandleBase ? part - KKBoxPartHandleBase : -1;
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
  if (activePart == kOSCScalePart)
    return @"Scale";
  if (activePart == kOSCAnchorPart)
    return @"Anchor";
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
    KKScaleHandlePositions(self.scalePressCenter, self.scalePressSclX,
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

  KKTimeline *snap = KKProcessTimelineSnapshot();
  KKTimeline *tl = snap ? [snap copy] : [KKTimeline timeline];
  NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
  NSInteger laneIdx = NSNotFound;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([((KKLane *)lanes[i]).label isEqualToString:@"Scale"]) {
      laneIdx = i;
      break;
    }
  }
  double frac = [self _fractionAtTime:time];
  if (laneIdx == NSNotFound) {
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
  } else {
    KKLane *scaleLane = [lanes[laneIdx] copy];
    NSArray<KKKeyPose *> *kps = scaleLane.keyposes;
    if (kps.count == 0) {
      scaleLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
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
      KKKeyPose *nk = [KKKeyPose keyposeAtTime:out[best].time values:newValues];
      nk.outgoing = out[best].outgoing;
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
      scaleLane.keyposes = out;
    }
    lanes[laneIdx] = scaleLane;
  }
  tl.lanes = lanes;

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

  KKTimeline *snap = KKProcessTimelineSnapshot();
  KKTimeline *tl = snap ? [snap copy] : [KKTimeline timeline];
  NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
  NSInteger laneIdx = NSNotFound;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([((KKLane *)lanes[i]).label isEqualToString:@"Anchor"]) {
      laneIdx = i;
      break;
    }
  }
  double frac = [self _fractionAtTime:time];
  if (laneIdx == NSNotFound) {
    KKLane *anchorLane = [KKLane laneWithLabel:@"Anchor"];
    anchorLane.valueType = KKLaneValueTypeGeneric;
    anchorLane.componentMin = @[];
    anchorLane.componentMax = @[];
    anchorLane.componentUnits = @[ @"px", @"px" ];
    anchorLane.componentLabels = @[ @"X", @"Y" ];
    anchorLane.enabled = NO;
    anchorLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
    [lanes addObject:anchorLane];
  } else {
    KKLane *anchorLane = [lanes[laneIdx] copy];
    NSArray<KKKeyPose *> *kps = anchorLane.keyposes;
    if (kps.count == 0) {
      anchorLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
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
      KKKeyPose *nk = [KKKeyPose keyposeAtTime:out[best].time values:newValues];
      nk.outgoing = out[best].outgoing;
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
      anchorLane.keyposes = out;
    }
    lanes[laneIdx] = anchorLane;
  }
  tl.lanes = lanes;

  KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                           kKKParamTimelineData);
  [actionAPI endAction:self];
  if (forceUpdate)
    *forceUpdate = YES;
}

@end
