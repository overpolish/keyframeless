/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKRotationOSC.h"
#import "KKOSCShaderTypes.h"
#import "KKResizeCursor.h"
#import "KKRotationOSCMath.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#include <AppKit/AppKit.h>
#import <AppKit/NSCursor.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKRenderPrimitives.h>
#import <KeyframelessKit/KeyframelessKit.h>

KKLane *KKRotationLaneWithLabel(NSString *label, KKRotationAxes axes) {
  if (axes == 0)
    axes = KKRotationAxesAll;
  // Standard 3D-axis tint convention (Motion / Blender / Maya): X=red, Y=green,
  // Z=blue, slightly desaturated for the inspector.
  NSColor *cx = [NSColor colorWithSRGBRed:0.95 green:0.35 blue:0.35 alpha:1.0];
  NSColor *cy = [NSColor colorWithSRGBRed:0.40 green:0.85 blue:0.45 alpha:1.0];
  NSColor *cz = [NSColor colorWithSRGBRed:0.40 green:0.60 blue:0.95 alpha:1.0];
  NSMutableArray<NSString *> *units = [NSMutableArray array];
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  NSMutableArray<NSColor *> *colors = [NSMutableArray array];
  NSMutableArray<NSNumber *> *zeros = [NSMutableArray array];
  if (axes & KKRotationAxisX) {
    [units addObject:@"°"];
    [labels addObject:@"X"];
    [colors addObject:cx];
    [zeros addObject:@0.0];
  }
  if (axes & KKRotationAxisY) {
    [units addObject:@"°"];
    [labels addObject:@"Y"];
    [colors addObject:cy];
    [zeros addObject:@0.0];
  }
  if (axes & KKRotationAxisZ) {
    [units addObject:@"°"];
    [labels addObject:@"Z"];
    [colors addObject:cz];
    [zeros addObject:@0.0];
  }
  KKLane *lane = [KKLane laneWithKey:label label:label];
  lane.valueType = KKLaneValueTypeAngle;
  // Knobs cover one revolution visually but values accumulate past 360°
  // (2 turns = 720°). Empty min/max = unconstrained.
  lane.componentMin = @[];
  lane.componentMax = @[];
  lane.componentUnits = units;
  lane.componentLabels = labels;
  lane.componentLabelColors = colors;
  [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:zeros]];
  return lane;
}

static const int kRingSamples = 192;
static const float kHitThresholdPixels = 10.0f;

@implementation KKRotationOSC {
  NSInteger _activeAxis; // -1 / 0 / 1 / 2
  double _pressAngle;    // ring t-angle at press point
  double _pressTangentX; // screen tangent at press (unit)
  double _pressTangentY;
  float _pressRotX; // original angles at press for redo math
  float _pressRotY;
  float _pressRotZ;
  BOOL _cursorSet; // YES while we've forced a rotate cursor over a ring
  // High-level (self-contained) drag state. Press baseline is captured from
  // the NEAREST KEYPOSE (radians) so non-dragged axes aren't polluted by
  // easing overshoot at write time; lastWritten anchors the decompose so a
  // 0->90->180 sweep stays continuous past the asin clamp.
  double _rotPressKpX, _rotPressKpY, _rotPressKpZ;
  double _rotLastWrittenX, _rotLastWrittenY, _rotLastWrittenZ;
  CGPoint _rotPressCanvas;
}

@synthesize colorX = _colorX;
@synthesize colorY = _colorY;
@synthesize colorZ = _colorZ;
@synthesize outlineColor = _outlineColor;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _radius = 90.0f;
    _ringHalfWidth = 2.5f;
    _outlineWidth = 1.0f;
    _backDim = 0.3f;
    _activeAxis = -1;
    _enabledAxes = KKRotationAxesAll;
    _showX = YES;
    _showY = YES;
    _showZ = YES;
    _ringAlphaX = 1.0f;
    _ringAlphaY = 1.0f;
    _ringAlphaZ = 1.0f;
    _colorX = [NSColor colorWithRed:1.0 green:0.30 blue:0.30 alpha:1.0];
    _colorY = [NSColor colorWithRed:0.35 green:0.85 blue:0.40 alpha:1.0];
    _colorZ = [NSColor colorWithRed:0.40 green:0.55 blue:1.0 alpha:1.0];
    _outlineColor = [NSColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.75];
    _baseRotation = KKRotMatrixIdentity();
  }
  return self;
}

// The displayed pose = parent/group rotation · the object's own Euler. Used for
// drawing the rings, hit-testing them, and capturing the screen-space drag
// tangent, so a nested object's rings show + drag in the parent's frame. The
// written value stays the object's own Euler (the parent factors out).
- (KKRotMatrix3)_displayMatrix {
  return KKRotMatrixMul(_baseRotation,
                        KKBuildRotationMatrix(_rotX, _rotY, _rotZ));
}

// Ring `k`'s display frame: the full pose for a 3-axis gizmo (trackball drag
// spins about the visible axis), the NESTED frame for a partial axis set
// (drag = Euler increment, so each ring sits where its rotation applies).
// Composed under the parent/base rotation like _displayMatrix.
- (KKRotMatrix3)_ringDisplayMatrix:(int)k {
  return KKRotMatrixMul(
      _baseRotation,
      KKRingDisplayMatrix(_rotX, _rotY, _rotZ, (int)self.enabledAxes, k));
}

- (NSString *)pipelinePluginID {
  return @"co.overpolish.keyframelesskit.RotationOSC";
}
- (NSString *)fragmentFunctionName {
  return @"KKRotationOSCFragment";
}

- (float)hitRadius {
  return _radius + _ringHalfWidth + _outlineWidth + kHitThresholdPixels;
}
- (float)oscSize {
  return _radius + _ringHalfWidth + _outlineWidth + 2.0f;
}

- (BOOL)hitTestAtMousePositionX:(double)positionX
                      positionY:(double)positionY
                         atTime:(CMTime)time {
  // Hit-test in Y-DOWN screen space so it agrees with both the shader's
  // textureCoordinate.y and the renderer's internal screen convention. The
  // canvas itself is Y-UP (positionY increases upward), so negate Y when
  // forming the local-relative point.
  CGPoint local = CGPointMake(positionX - _center.x, _center.y - positionY);
  // Front-only: the shader visibly dims the back half, so back portions
  // are easy to mistake for empty space. Only the bright front hemisphere
  // is grabbable - what you see is what you can hit. Each ring hit-tests in
  // ITS display frame (nested for partial axis sets), matching the draw.
  double bestFront = 1e9;
  NSInteger bestFrontK = -1;
  double bestFrontT = 0;
  const BOOL ringShown[3] = {_showX, _showY, _showZ};
  for (int k = 0; k < 3; k++) {
    if (!ringShown[k])
      continue; // hidden ring is not grabbable
    KKRingHit h = KKClosestAngleOnRing([self _ringDisplayMatrix:k], k, _radius,
                                       local, kRingSamples);
    if (h.frontDist < bestFront) {
      bestFront = h.frontDist;
      bestFrontK = k;
      bestFrontT = h.frontT;
    }
  }
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (bestFrontK < 0 || bestFront > kHitThresholdPixels) {
    _activeAxis = -1;
    if (_cursorSet) {
      [oscAPI setCursor:[NSCursor arrowCursor]];
      _cursorSet = NO;
    }
    return NO;
  }
  _activeAxis = bestFrontK;
  _pressAngle = bestFrontT;
  if (bestFrontK == 2) {
    // Z: in-plane spin -> the rotate cursor, oriented by the hover quadrant
    // (canvas Y-up: dy = posY - centerY).
    double cursorAngle = atan2(positionY - _center.y, positionX - _center.x);
    [oscAPI setCursor:KKRotationAxisCursor(bestFrontK, cursorAngle)];
  } else {
    // X/Y: a drag moves the grab point ALONG the ring, so the resize cursor
    // follows the ring's on-screen TANGENT at the hovered angle - correct at
    // any gizmo pose (a reoriented X ring lying horizontal gets a horizontal
    // cursor, not its base-pose vertical one). Ring point = r(cos t·U +
    // sin t·V), tangent = -sin t·U + cos t·V; the local frame is Y-down, so
    // flip for the Y-up cursor angle.
    simd_float3 U, V;
    KKRingBasis([self _ringDisplayMatrix:(int)bestFrontK], (int)bestFrontK, &U,
                &V);
    double tx = -sin(bestFrontT) * U.x + cos(bestFrontT) * V.x;
    double ty = -(-sin(bestFrontT) * U.y + cos(bestFrontT) * V.y);
    [oscAPI setCursor:KKResizeCursorForAngle(atan2(ty, tx))];
  }
  _cursorSet = YES;
  return YES;
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
  // Lock the tangent + rotation values at press time so dragging is
  // consistent even if rotX/Y/Z get nudged mid-drag by something else.
  _pressRotX = _rotX;
  _pressRotY = _rotY;
  _pressRotZ = _rotZ;
  if (_activeAxis < 0)
    return;
  KKRingScreenTangentAtT([self _ringDisplayMatrix:(int)_activeAxis],
                         (int)_activeAxis, _pressAngle, &_pressTangentX,
                         &_pressTangentY);
}

- (void)drawAtCanvasPosition:(CGPoint)canvasPosition
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time {
  id<MTLRenderPipelineState> ps =
      [self pipelineStateForDestinationImage:destinationImage];
  if (!ps)
    return;

  float quadHalf = _radius + _ringHalfWidth + _outlineWidth + 2.0f;

  KKRotationOSCParams params = {
      .radius = _radius / quadHalf,
      .ringHalfWidth = _ringHalfWidth / quadHalf,
      .outlineWidth = _outlineWidth / quadHalf,
      .backDim = _backDim,
      .ringColorX = [_colorX simdFloat4],
      .ringColorY = [_colorY simdFloat4],
      .ringColorZ = [_colorZ simdFloat4],
      .outlineColor = [_outlineColor simdFloat4],
      .activeRing = (int)((isActive || isHovered) ? _activeAxis : -1),
      .activeBoost = isActive ? 0.35f : (isHovered ? 0.15f : 0.0f),
      .ringVisible = (vector_float3){_showX ? _ringAlphaX : 0.0f,
                                     _showY ? _ringAlphaY : 0.0f,
                                     _showZ ? _ringAlphaZ : 0.0f},
  };
  KKRotMatrix3 mX = [self _ringDisplayMatrix:0];
  KKRotMatrix3 mY = [self _ringDisplayMatrix:1];
  KKRotMatrix3 mZ = [self _ringDisplayMatrix:2];
  KKRotationOSCParamsSetRingBases(&params, mX, mY, mZ);

  [self drawQuadForDestinationImage:destinationImage
                     canvasPosition:canvasPosition
                   clearDestination:NO
                      pipelineState:ps
                       fragmentData:&params
                   fragmentDataSize:sizeof(params)
                               size:quadHalf];
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                         laneLabel:(NSString *)laneLabel {
  self = [self initWithAPIManager:apiManager];
  if (self) {
    _laneLabel = [laneLabel copy];
    // Composed under a host OSC that clears the destination once at the start
    // of its drawOSC tick, so it must not clear again.
    self.clearsOnDraw = NO;
  }
  return self;
}

- (nullable KKLane *)_rotationLane {
  for (KKLane *lane in KKProcessTimelineSnapshot().lanes)
    if ([lane.key isEqualToString:self.laneLabel])
      return lane;
  return nil;
}

- (BOOL)_rotationVisibleAtFraction:(double)frac {
  return KKLaneVisibleAtFraction([self _rotationLane], frac,
                                 KKProcessFrameDurationSeconds());
}

// Expand a lane value (one component per enabled axis, X/Y/Z order) to a full
// [X,Y,Z] Euler in degrees; disabled axes read 0.
- (NSArray<NSNumber *> *)_eulerDegFromLaneValues:(NSArray<NSNumber *> *)v {
  double xyz[3] = {0.0, 0.0, 0.0};
  NSUInteger idx = 0;
  if (self.enabledAxes & KKRotationAxisX)
    xyz[0] = (idx < v.count) ? v[idx++].doubleValue : 0.0;
  if (self.enabledAxes & KKRotationAxisY)
    xyz[1] = (idx < v.count) ? v[idx++].doubleValue : 0.0;
  if (self.enabledAxes & KKRotationAxisZ)
    xyz[2] = (idx < v.count) ? v[idx++].doubleValue : 0.0;
  return @[ @(xyz[0]), @(xyz[1]), @(xyz[2]) ];
}

// Collapse a full [X,Y,Z] Euler back to the lane's components (only the enabled
// axes, in X/Y/Z order).
- (NSArray<NSNumber *> *)_laneValuesFromEulerDeg:(NSArray<NSNumber *> *)e {
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  if (self.enabledAxes & KKRotationAxisX)
    [out addObject:e[0]];
  if (self.enabledAxes & KKRotationAxisY)
    [out addObject:e[1]];
  if (self.enabledAxes & KKRotationAxisZ)
    [out addObject:e[2]];
  return out;
}

// 3-axis Euler [X,Y,Z] in DEGREES, smoothed (what's on screen). Always 3 comps.
- (NSArray<NSNumber *> *)_rotationValuesAtFraction:(double)frac {
  KKLane *lane = [self _rotationLane];
  if (!lane)
    return @[ @0.0, @0.0, @0.0 ];
  NSArray<NSNumber *> *v =
      KKLaneDisplayValueAtFraction(lane, frac);
  return [self _eulerDegFromLaneValues:v];
}

// Per-ring visibility + ghost alpha from the OSC-visibility state (master
// "Rotation" + per-axis "Rotation.X/Y/Z" pills + opt-reveal). Mirrors the box's
// gating in KKScaleOSC. Returns YES if any ring is shown this frame.
- (BOOL)_configureRingsAtFraction:(double)frac dragging:(BOOL)dragging {
  NSString *xKey = [self.laneLabel stringByAppendingString:@".X"];
  NSString *yKey = [self.laneLabel stringByAppendingString:@".Y"];
  NSString *zKey = [self.laneLabel stringByAppendingString:@".Z"];
  BOOL shownHere = [self _rotationVisibleAtFraction:frac];
  BOOL activeHere = shownHere || dragging;
  BOOL master = [self kkOSCElementVisible:self.laneLabel];
  BOOL xEn = master && [self kkOSCElementVisible:xKey];
  BOOL yEn = master && [self kkOSCElementVisible:yKey];
  BOOL zEn = master && [self kkOSCElementVisible:zKey];
  BOOL reveal = self.optRevealActive && shownHere;
  BOOL xShow =
      (xEn && activeHere) || (reveal && [self kkOSCRevealEligible:xKey]);
  BOOL yShow =
      (yEn && activeHere) || (reveal && [self kkOSCRevealEligible:yKey]);
  BOOL zShow =
      (zEn && activeHere) || (reveal && [self kkOSCRevealEligible:zKey]);
  self.showX = xShow && (self.enabledAxes & KKRotationAxisX) != 0;
  self.showY = yShow && (self.enabledAxes & KKRotationAxisY) != 0;
  self.showZ = zShow && (self.enabledAxes & KKRotationAxisZ) != 0;
  float ghost = [self kkRevealGhostAlpha];
  self.ringAlphaX = xEn ? 1.0f : ghost;
  self.ringAlphaY = yEn ? 1.0f : ghost;
  self.ringAlphaZ = zEn ? 1.0f : ghost;
  return dragging || xShow || yShow || zShow;
}

// Pull X/Y/Z ring colours from the lane's componentLabelColors so the OSC
// matches the inspector.
- (void)_syncColorsFromLane {
  KKLane *lane = [self _rotationLane];
  // Colours map to the lane's components in enabled-axis order (a 1-component
  // Z lane's single colour becomes the Z ring).
  NSArray<NSColor *> *cols = lane.componentLabelColors;
  NSUInteger idx = 0;
  if ((self.enabledAxes & KKRotationAxisX) && idx < cols.count)
    self.colorX = cols[idx++];
  if ((self.enabledAxes & KKRotationAxisY) && idx < cols.count)
    self.colorY = cols[idx++];
  if ((self.enabledAxes & KKRotationAxisZ) && idx < cols.count)
    self.colorZ = cols[idx++];
}

// Sync the drawn/hit pose (radians) to the smoothed on-screen values.
- (void)_syncPoseToSmoothedAtFraction:(double)frac {
  NSArray<NSNumber *> *r = [self _rotationValuesAtFraction:frac];
  self.rotX = (float)(r[0].doubleValue * M_PI / 180.0);
  self.rotY = (float)(r[1].doubleValue * M_PI / 180.0);
  self.rotZ = (float)(r[2].doubleValue * M_PI / 180.0);
}

- (void)drawInDestination:(FxImageTile *)destinationImage
                   atTime:(CMTime)time
               activePart:(NSInteger)activePart {
  double frac = [self fractionAtTime:time];
  BOOL dragging = self.dragging && activePart == self.rotationActivePart;
  if (![self _configureRingsAtFraction:frac dragging:dragging])
    return;
  [self _syncColorsFromLane];
  [self _syncPoseToSmoothedAtFraction:frac];
  // Hover boost when the pointer is over the gizmo (host activePart matches)
  // but not yet dragging; the grabbed ring brightens more once dragging.
  BOOL hovered = (activePart == self.rotationActivePart) && !dragging;
  [self drawAtCanvasPosition:self.center
                   isHovered:hovered
                    isActive:dragging
            destinationImage:destinationImage
                      atTime:time];
}

- (NSInteger)hitTestRingAtX:(double)x y:(double)y atTime:(CMTime)time {
  double frac = [self fractionAtTime:time];
  // Configure rings first so hidden axes aren't grabbable; if none are shown
  // (wrong time / fully hidden and no opt-peek) there's nothing to hit.
  if (![self _configureRingsAtFraction:frac dragging:NO])
    return -1;
  [self _syncPoseToSmoothedAtFraction:frac];
  if (![self hitTestAtMousePositionX:x positionY:y atTime:time])
    return -1;
  // Opt-hover hide/show affordance for the HIT ring's own axis (eye/eye.slash);
  // falls back to the axis rotate cursor the low-level hit-test already set.
  // The per-axis key matches what an opt-click toggles (Rotation.X/Y/Z).
  NSInteger ax = self.activeAxis;
  NSString *axisSuffix = (ax == 0) ? @".X" : (ax == 1) ? @".Y" : @".Z";
  NSCursor *eye =
      [self kkVisibilityCursorForLabel:[self.laneLabel
                                           stringByAppendingString:axisSuffix]];
  if (eye) {
    id<FxOnScreenControlAPI_v4> oscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
    [oscAPI setCursor:eye];
  }
  return self.activeAxis;
}

- (void)mouseDownAtX:(double)x
                   y:(double)y
           modifiers:(NSUInteger)modifiers
         forceUpdate:(BOOL *)forceUpdate
              atTime:(CMTime)time {
  double frac = [self fractionAtTime:time];
  // Press baseline from the keypose we'll write to (nearest the playhead), NOT
  // the smoothed interpolation - the easing curve overshoots near keypose
  // boundaries, and using it as the baseline would let the non-dragged axes
  // inherit that overshoot and silently overwrite the keypose's real values.
  KKLane *lane = [self _rotationLane];
  NSArray<NSNumber *> *r = nil;
  if (lane.keyposes.count > 0)
    r = lane.keyposes[KKLaneNearestKeyposeIndex(lane, frac)].values;
  r = [self _eulerDegFromLaneValues:r ?: @[]];
  _rotPressKpX = r[0].doubleValue * M_PI / 180.0;
  _rotPressKpY = r[1].doubleValue * M_PI / 180.0;
  _rotPressKpZ = r[2].doubleValue * M_PI / 180.0;
  _rotLastWrittenX = _rotPressKpX;
  _rotLastWrittenY = _rotPressKpY;
  _rotLastWrittenZ = _rotPressKpZ;
  _rotPressCanvas = CGPointMake(x, y);
  // The press tangent must be computed against the SMOOTHED pose (what's on
  // screen), so sync the inner pose to it before the low-level capture. The
  // host has already set `center` this tick.
  [self _syncPoseToSmoothedAtFraction:frac];
  [self mouseDownAtPositionX:x
                   positionY:y
                  activePart:self.rotationActivePart
                   modifiers:modifiers
                 forceUpdate:forceUpdate
                      atTime:time];
}

- (void)mouseDraggedAtX:(double)x
                      y:(double)y
              modifiers:(NSUInteger)modifiers
            forceUpdate:(BOOL *)forceUpdate
                 atTime:(CMTime)time {
  NSInteger axis = self.activeAxis;
  if (axis < 0 || _radius <= 0)
    return;
  // Mouse y comes in canvas Y-UP; the press tangent is Y-DOWN screen space
  // (same convention as the shader / hit-test), so flip dy. Delta + Cmd-snap
  // + full/partial apply are the shared ring-drag model's.
  double dAngle = KKRingDragAngleDelta(
      (int)axis, x - _rotPressCanvas.x, _rotPressCanvas.y - y, _pressTangentX,
      _pressTangentY, (double)_radius,
      (modifiers & kFxModifierKey_COMMAND) != 0);
  double lastRx = _rotLastWrittenX, lastRy = _rotLastWrittenY,
         lastRz = _rotLastWrittenZ;
  double rx = 0, ry = 0, rz = 0;
  KKRotationAxes all = KKRotationAxisX | KKRotationAxisY | KKRotationAxisZ;
  KKRingApplyDragDelta((int)axis, (self.enabledAxes & all) == all, dAngle,
                       _rotPressKpX, _rotPressKpY, _rotPressKpZ, &lastRx,
                       &lastRy, &lastRz, &rx, &ry, &rz);
  _rotLastWrittenX = lastRx;
  _rotLastWrittenY = lastRy;
  _rotLastWrittenZ = lastRz;
  const double kRadToDeg = 180.0 / M_PI;
  NSArray<NSNumber *> *euler =
      @[ @(rx * kRadToDeg), @(ry * kRadToDeg), @(rz * kRadToDeg) ];
  // Persist only the enabled axes (the lane carries one component per axis).
  [self _writeRotationValues:[self _laneValuesFromEulerDeg:euler]
                      atTime:time
                 forceUpdate:forceUpdate];
}

- (void)_writeRotationValues:(NSArray<NSNumber *> *)newValues
                      atTime:(CMTime)time
                 forceUpdate:(BOOL *)forceUpdate {
  __block BOOL wrote = NO;
  KKPerformUndoable(
      self.apiManager, self, nil,
      ^(id<FxParameterRetrievalAPI_v6> getAPI,
        id<FxParameterSettingAPI_v5> setAPI, CMTime actionTime) {
        if (!setAPI)
          return;

        double frac = [self fractionAtTime:time];
        KKTimeline *snap = KKProcessTimelineSnapshot();
        KKTimeline *tl = snap ? KKTimelineSettingValuesNearestFraction(
                                    snap, self.laneLabel, frac, newValues)
                              : nil;
        if (!tl) {
          tl = snap ? [snap copy] : [KKTimeline timeline];
          NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
          KKLane *rotLane =
              [self.templateLane copy] ?: [KKLane laneWithKey:self.laneLabel label:self.laneLabel];
          rotLane.enabled = NO;
          rotLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:newValues] ];
          [lanes addObject:rotLane];
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
  // The active axis is re-evaluated on the next hit-test; nothing to reset.
}

- (NSArray<NSString *> *)oscElementKeys {
  if (!self.laneLabel)
    return @[];
  NSMutableArray<NSString *> *keys =
      [NSMutableArray arrayWithObject:self.laneLabel];
  if (self.enabledAxes & KKRotationAxisX)
    [keys addObject:[self.laneLabel stringByAppendingString:@".X"]];
  if (self.enabledAxes & KKRotationAxisY)
    [keys addObject:[self.laneLabel stringByAppendingString:@".Y"]];
  if (self.enabledAxes & KKRotationAxisZ)
    [keys addObject:[self.laneLabel stringByAppendingString:@".Z"]];
  return keys;
}

@end
