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

// Scale gizmo half-extent as a fraction of the clip's on-screen frame, so the
// box tracks the clip (scales with viewer zoom) instead of being a fixed screen
// size. e0 = 0% half-extent, span = the 0->100% growth; >100% sqrt-compresses
// (see KKScaleGizmo). Same proportion as the mini-canvas box.
static const double kScaleGizmoE0Frac = 0.12;
static const double kScaleGizmoSpanFrac = 0.057;

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
  // Per-ring reveal: master-off peek shows only the rings left enabled (a ring
  // whose own pill or the Rotation compound is off stays off), while master-on
  // reveal still ghosts the hidden rings for re-showing.
  BOOL reveal = self.optRevealActive && shownHere;
  BOOL xShow = (xEn && activeHere) ||
               (reveal && [self kkOSCRevealEligible:@"Rotation.X"]);
  BOOL yShow = (yEn && activeHere) ||
               (reveal && [self kkOSCRevealEligible:@"Rotation.Y"]);
  BOOL zShow = (zEn && activeHere) ||
               (reveal && [self kkOSCRevealEligible:@"Rotation.Z"]);
  self.rotationOSC.showX = xShow;
  self.rotationOSC.showY = yShow;
  self.rotationOSC.showZ = zShow;
  float ghost = [self kkRevealGhostAlpha];
  self.rotationOSC.ringAlphaX = xEn ? 1.0f : ghost;
  self.rotationOSC.ringAlphaY = yEn ? 1.0f : ghost;
  self.rotationOSC.ringAlphaZ = zEn ? 1.0f : ghost;
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

@end
