/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKRotationOSCSet.h"

#import "KKOSCVisibilityModel.h"
#import "KKRadialOSCSet_Protected.h"

#import <KeyframelessKit/KKResizeCursor.h> // KKRotationAxisCursor, eye cursors
#import <KeyframelessKit/KKRotationOSCMath.h>
#import <math.h>
#import <simd/simd.h>

// Mirror of the single-lane rotation constants in KKMiniViewerRenderer.m so the
// N-gizmo path sizes / hit-tests / snaps identically.
static const CGFloat kRotBaselineRadiusPt = 28.0;
static const CGFloat kRotBaselineCanvasH = 230.0;
static const double kRotHitThresholdRatio = 10.0 / 90.0;
static const int kRotRingSamples = 192;
static const double kDegToRad = M_PI / 180.0;
static const double kRadToDeg = 180.0 / M_PI;

// The standard 3D-axis ring tints (matching KKMiniViewerRenderer / the viewer
// KKRotationOSC / the catalog lane): X=red, Y=green, Z=blue.
static simd_float4 kRotAxisColors[3] = {
    {1.00f, 0.30f, 0.30f, 1.0f},
    {0.35f, 0.85f, 0.40f, 1.0f},
    {0.40f, 0.55f, 1.00f, 1.0f},
};

// The visibility/cursor element-key suffix for an axis index (0=X, 1=Y, 2=Z).
static NSString *kkAxisLetter(int k) {
  return (k == 0) ? @"X" : (k == 1) ? @"Y" : @"Z";
}

@implementation KKRotationOSCSet {
  // Active drag state (only one gizmo drags at a time). `_grabLabel` is the
  // grabbed lane; the base's `activeLabel` mirrors it.
  NSString *_grabLabel;
  int _activeAxis; // -1 / 0 / 1 / 2
  double _pressAngle;
  CGPoint _pressMouse;
  double _pressRx, _pressRy, _pressRz;
  double _lastWrittenRx, _lastWrittenRy, _lastWrittenRz;
  double _pressTangentX, _pressTangentY;
}

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer {
  self = [super initWithRenderer:renderer];
  if (self)
    _activeAxis = -1;
  return self;
}

- (void)setRotations:(NSArray<NSDictionary<NSString *, id> *> *)rotations {
  self.specs = rotations;
  if (!self.activeLabel) {
    _grabLabel = nil;
    _activeAxis = -1;
  }
}

- (KKRotationAxes)_axesForSpec:(NSDictionary *)s {
  KKRotationAxes a = (KKRotationAxes)[s[@"axes"] integerValue];
  return a ?: KKRotationAxisZ;
}

// Expand the lane's stored components (one per enabled axis, canonical X<Y<Z
// order) to a full [X,Y,Z] Euler in degrees; disabled axes read 0.
- (void)_eulerDegForLabel:(NSString *)label
                     axes:(KKRotationAxes)axes
                      out:(double[3])xyz {
  NSArray<NSNumber *> *v = [self valuesForLabel:label];
  xyz[0] = xyz[1] = xyz[2] = 0.0;
  NSUInteger idx = 0;
  if (axes & KKRotationAxisX)
    xyz[0] = (idx < v.count) ? v[idx++].doubleValue : 0.0;
  if (axes & KKRotationAxisY)
    xyz[1] = (idx < v.count) ? v[idx++].doubleValue : 0.0;
  if (axes & KKRotationAxisZ)
    xyz[2] = (idx < v.count) ? v[idx++].doubleValue : 0.0;
}

// Collapse a full [X,Y,Z] Euler (degrees) back to the lane's components (only
// the enabled axes, canonical order).
- (NSArray<NSNumber *> *)_laneValuesFromEulerDeg:(const double[3])e
                                            axes:(KKRotationAxes)axes {
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  if (axes & KKRotationAxisX)
    [out addObject:@(e[0])];
  if (axes & KKRotationAxisY)
    [out addObject:@(e[1])];
  if (axes & KKRotationAxisZ)
    [out addObject:@(e[2])];
  return out;
}

// A spec's DISPLAY-ONLY pose offset as a matrix pre-applied to the drawn /
// hit-tested / dragged frame (the viewer gizmo's `baseRotation`). `offsetDeg`
// is a constant [X,Y,Z] in degrees; `offsetDegBlock` supplies the same live per
// draw, for an offset derived from other lanes. The written value never sees
// it - only where the rings sit.
- (KKRotMatrix3)_baseMatrixForLabel:(NSString *)label {
  NSDictionary *s = [self specForLabel:label];
  NSArray<NSNumber *> * (^live)(void) = s[@"offsetDegBlock"];
  NSArray<NSNumber *> *deg = live ? live() : s[@"offsetDeg"];
  if (deg.count == 0)
    return KKRotMatrixIdentity();
  double e[3] = {0.0, 0.0, 0.0};
  for (NSUInteger i = 0; i < deg.count && i < 3; i++)
    e[i] = deg[i].doubleValue;
  return KKBuildRotationMatrix((float)(e[0] * kDegToRad),
                               (float)(e[1] * kDegToRad),
                               (float)(e[2] * kDegToRad));
}

- (KKRotMatrix3)_matrixForLabel:(NSString *)label axes:(KKRotationAxes)axes {
  double e[3];
  [self _eulerDegForLabel:label axes:axes out:e];
  return KKRotMatrixMul([self _baseMatrixForLabel:label],
                        KKBuildRotationMatrix((float)(e[0] * kDegToRad),
                                              (float)(e[1] * kDegToRad),
                                              (float)(e[2] * kDegToRad)));
}

// Ring `k`'s display frame: the full pose for a 3-axis gizmo, the NESTED
// frame for a partial axis set (drag = Euler increment there), matching the
// viewer gizmo's _ringDisplayMatrix.
- (KKRotMatrix3)_ringMatrixForLabel:(NSString *)label
                               axes:(KKRotationAxes)axes
                               ring:(int)k {
  double e[3];
  [self _eulerDegForLabel:label axes:axes out:e];
  return KKRotMatrixMul(
      [self _baseMatrixForLabel:label],
      KKRingDisplayMatrix((float)(e[0] * kDegToRad), (float)(e[1] * kDegToRad),
                          (float)(e[2] * kDegToRad), (int)axes, k));
}

- (CGFloat)_radiusForCanvas:(KKMiniViewerView *)canvas {
  CGFloat h = canvas.oscSizingHeight;
  CGFloat scale = (h > 0) ? (h / kRotBaselineCanvasH) : 1.0;
  return kRotBaselineRadiusPt * scale;
}

- (BOOL)_axisSuppressed:(int)k forLabel:(NSString *)label {
  // Hidden either by boundary-phase suppression (suppressedHandleLabels) OR by
  // the OSC-visibility checklist, which stores its hidden elements in
  // hiddenHandleLabels - checking only the former let a checklist-hidden ring
  // (master "Rotation" or per-axis "Rotation.Z") keep drawing in the mini
  // viewer. Mirrors the single-lane -_ringIndividuallyHiddenAtAxis:.
  NSArray<NSString *> *sup = self.renderer.suppressedHandleLabels;
  NSSet<NSString *> *hid = self.renderer.hiddenHandleLabels;
  NSString *axisKey = [label stringByAppendingFormat:@".%@", kkAxisLetter(k)];
  return [sup containsObject:label] || [hid containsObject:label] ||
         [sup containsObject:axisKey] || [hid containsObject:axisKey];
}

// Per-axis draw alpha: 0 = not drawn (disabled or hidden with no reveal), 0.3 =
// revealed ghost, 1.0 = shown. Whole-gizmo gating (master + constant) is done
// by -isActiveLabel: before this is consulted.
- (float)_ringAlphaForLabel:(NSString *)label
                       axes:(KKRotationAxes)axes
                       axis:(int)k {
  if (!(axes & (1 << k)))
    return 0.0f;
  BOOL suppressed = [self _axisSuppressed:k forLabel:label];
  BOOL reveal = self.renderer.revealHidden &&
                self.renderer.onHandleVisibilityToggled != nil;
  if (!suppressed)
    return 1.0f;
  return reveal ? kKKOSCGhostAlpha : 0.0f;
}

- (NSArray<KKMiniRotation *> *)rotationsForContentRect:(CGRect)cr
                                                canvas:
                                                    (KKMiniViewerView *)canvas {
  NSMutableArray<KKMiniRotation *> *out = [NSMutableArray array];
  CGFloat radius = [self _radiusForCanvas:canvas];
  if (radius <= 0)
    return out;
  for (NSDictionary *s in self.specs) {
    NSString *label = s[@"label"];
    if (![self isActiveLabel:label forContentRect:cr])
      continue;
    KKRotationAxes axes = [self _axesForSpec:s];
    CGPoint center = [self centerForSpec:s contentRect:cr];
    BOOL grabbed = [label isEqualToString:_grabLabel];
    KKRotationOSCParams p = {
        .radius = 1.0f,
        .ringHalfWidth = 3.5f / 90.0f,
        .outlineWidth = 1.0f / 90.0f,
        .backDim = 0.3f,
        .ringColorX = kRotAxisColors[0],
        .ringColorY = kRotAxisColors[1],
        .ringColorZ = kRotAxisColors[2],
        .outlineColor = {0.0f, 0.0f, 0.0f, 0.75f},
        .activeRing = grabbed ? _activeAxis : -1,
        .activeBoost = (grabbed && _activeAxis >= 0) ? 0.35f : 0.0f,
        .ringVisible = {[self _ringAlphaForLabel:label axes:axes axis:0],
                        [self _ringAlphaForLabel:label axes:axes axis:1],
                        [self _ringAlphaForLabel:label axes:axes axis:2]},
    };
    KKRotMatrix3 mX = [self _ringMatrixForLabel:label axes:axes ring:0];
    KKRotMatrix3 mY = [self _ringMatrixForLabel:label axes:axes ring:1];
    KKRotMatrix3 mZ = [self _ringMatrixForLabel:label axes:axes ring:2];
    KKRotationOSCParamsSetRingBases(&p, mX, mY, mZ);
    [out addObject:[KKMiniRotation rotationWithCenter:center
                                             radiusPx:radius
                                               params:p]];
  }
  return out;
}

// The nearest grabbable ring under `p` across every shown gizmo, or nil. Sets
// `*outAxis` to its axis + `*outAngle` to the ring t at the press point.
- (nullable NSString *)_ringAtPoint:(CGPoint)p
                        contentRect:(CGRect)cr
                             canvas:(KKMiniViewerView *)canvas
                            outAxis:(int *)outAxis
                           outAngle:(double *)outAngle {
  CGFloat radius = [self _radiusForCanvas:canvas];
  if (radius <= 0)
    return nil;
  double threshold = radius * kRotHitThresholdRatio;
  double bestFront = 1e9;
  NSString *bestLabel = nil;
  int bestK = -1;
  double bestT = 0;
  for (NSDictionary *s in self.specs) {
    NSString *label = s[@"label"];
    if (![self isActiveLabel:label forContentRect:cr])
      continue;
    KKRotationAxes axes = [self _axesForSpec:s];
    CGPoint center = [self centerForSpec:s contentRect:cr];
    // Overlay is Y-UP; the rotation math works in Y-DOWN screen space. Each
    // ring hit-tests in ITS display frame (nested for partial axis sets),
    // matching the draw.
    CGPoint local = CGPointMake(p.x - center.x, center.y - p.y);
    for (int k = 0; k < 3; k++) {
      if ([self _ringAlphaForLabel:label axes:axes axis:k] <= 0.0f)
        continue; // hidden/disabled ring not grabbable
      KKRingHit h = KKClosestAngleOnRing([self _ringMatrixForLabel:label
                                                              axes:axes
                                                              ring:k],
                                         k, radius, local, kRotRingSamples);
      if (h.frontDist < bestFront) {
        bestFront = h.frontDist;
        bestLabel = label;
        bestK = k;
        bestT = h.frontT;
      }
    }
  }
  if (!bestLabel || bestFront > threshold)
    return nil;
  if (outAxis)
    *outAxis = bestK;
  if (outAngle)
    *outAngle = bestT;
  return bestLabel;
}

- (BOOL)handleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  return [self cursorAtPoint:p contentRect:cr] != nil;
}

- (NSCursor *)cursorAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  int axis = -1;
  double t = 0;
  NSString *hit = [self _ringAtPoint:p
                         contentRect:cr
                              canvas:self.renderer.canvas
                             outAxis:&axis
                            outAngle:&t];
  if (!hit)
    return nil;
  NSString *ringKey = [hit stringByAppendingFormat:@".%@", kkAxisLetter(axis)];
  NSCursor *vis = [self.renderer kkVisibilityCursorForLabel:ringKey];
  if (vis)
    return vis;
  CGPoint c = [self centerForSpec:[self specForLabel:hit] contentRect:cr];
  if (axis == 2)
    return KKRotationAxisCursor(axis, atan2(p.y - c.y, p.x - c.x));
  // X/Y: the resize cursor follows the ring's on-screen TANGENT at the hovered
  // angle (same pose-aware fix as the viewer gizmo) - the drag already uses
  // this exact tangent. KKRingBasis is Y-down; flip for the Y-up overlay.
  KKRotationAxes axes = [self _axesForSpec:[self specForLabel:hit]];
  simd_float3 U, V;
  KKRingBasis([self _ringMatrixForLabel:hit axes:axes ring:axis], axis, &U, &V);
  double tx = -sin(t) * U.x + cos(t) * V.x;
  double ty = -(-sin(t) * U.y + cos(t) * V.y);
  return KKResizeCursorForAngle(atan2(ty, tx));
}

- (BOOL)beginDragAtPoint:(CGPoint)p
             contentRect:(CGRect)cr
                  canvas:(KKMiniViewerView *)canvas {
  int axis = -1;
  double t = 0;
  NSString *hit = [self _ringAtPoint:p
                         contentRect:cr
                              canvas:canvas
                             outAxis:&axis
                            outAngle:&t];
  if (!hit)
    return NO;
  _grabLabel = hit;
  self.activeLabel = hit;
  _activeAxis = axis;
  _pressAngle = t;
  _pressMouse = p;
  KKRotationAxes axes = [self _axesForSpec:[self specForLabel:hit]];
  double e[3];
  [self _eulerDegForLabel:hit axes:axes out:e];
  _pressRx = e[0] * kDegToRad;
  _pressRy = e[1] * kDegToRad;
  _pressRz = e[2] * kDegToRad;
  _lastWrittenRx = _pressRx;
  _lastWrittenRy = _pressRy;
  _lastWrittenRz = _pressRz;
  // Y-DOWN screen tangent at the press ring point, in the ring's own display
  // frame (nested for partial axis sets, matching draw + hit).
  KKRingScreenTangentAtT([self _ringMatrixForLabel:hit axes:axes ring:axis],
                         axis, t, &_pressTangentX, &_pressTangentY);
  [canvas setNeedsDisplay:YES];
  return YES;
}

- (BOOL)dragToPoint:(CGPoint)p
        contentRect:(CGRect)cr
             canvas:(KKMiniViewerView *)canvas
          modifiers:(NSEventModifierFlags)modifiers {
  if (!_grabLabel || _activeAxis < 0)
    return NO;
  KKRotationAxes axes = [self _axesForSpec:[self specForLabel:_grabLabel]];
  CGFloat radius = [self _radiusForCanvas:canvas];
  if (radius <= 0)
    return YES;
  // Delta (dy flipped: overlay Y-UP into the tangent's Y-DOWN convention),
  // Cmd-snap and full/partial apply are the shared ring-drag model's - one
  // rule set with the viewer gizmo.
  double dAngle = KKRingDragAngleDelta(
      _activeAxis, p.x - _pressMouse.x, _pressMouse.y - p.y, _pressTangentX,
      _pressTangentY, (double)radius,
      (modifiers & NSEventModifierFlagCommand) != 0);
  double rx = 0, ry = 0, rz = 0;
  KKRotationAxes all = KKRotationAxisX | KKRotationAxisY | KKRotationAxisZ;
  KKRingApplyDragDelta(_activeAxis, (axes & all) == all, dAngle, _pressRx,
                       _pressRy, _pressRz, &_lastWrittenRx, &_lastWrittenRy,
                       &_lastWrittenRz, &rx, &ry, &rz);
  double euler[3] = {rx * kRadToDeg, ry * kRadToDeg, rz * kRadToDeg};
  [self.renderer commitValues:[self _laneValuesFromEulerDeg:euler axes:axes]
                     forLabel:_grabLabel
                       canvas:canvas];
  [canvas setNeedsDisplay:YES];
  return YES;
}

- (BOOL)endDragOnCanvas:(KKMiniViewerView *)canvas {
  if (!_grabLabel)
    return NO;
  _grabLabel = nil;
  self.activeLabel = nil;
  _activeAxis = -1;
  [canvas setNeedsDisplay:YES];
  return YES;
}

- (BOOL)optClickAtPoint:(CGPoint)p
            contentRect:(CGRect)cr
                 canvas:(KKMiniViewerView *)canvas {
  int axis = -1;
  double t = 0;
  NSString *hit = [self _ringAtPoint:p
                         contentRect:cr
                              canvas:canvas
                             outAxis:&axis
                            outAngle:&t];
  if (!hit)
    return NO;
  // Toggle the specific axis ring (matching the viewer + checklist keys). Claim
  // the hit even without a callback so it never falls through to a drag.
  if (self.renderer.onHandleVisibilityToggled)
    self.renderer.onHandleVisibilityToggled(
        [hit stringByAppendingFormat:@".%@", kkAxisLetter(axis)]);
  [canvas setNeedsDisplay:YES];
  return YES;
}

@end
