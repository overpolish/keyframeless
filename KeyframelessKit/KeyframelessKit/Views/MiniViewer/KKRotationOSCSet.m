/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKRotationOSCSet.h"
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
static const double kRotSnapStep = 15.0 * M_PI / 180.0;
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

- (KKRotMatrix3)_matrixForLabel:(NSString *)label axes:(KKRotationAxes)axes {
  double e[3];
  [self _eulerDegForLabel:label axes:axes out:e];
  return KKBuildRotationMatrix((float)(e[0] * kDegToRad),
                               (float)(e[1] * kDegToRad),
                               (float)(e[2] * kDegToRad));
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
  return reveal ? 0.3f : 0.0f;
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
    KKRotMatrix3 m = [self _matrixForLabel:label axes:axes];
    BOOL grabbed = [label isEqualToString:_grabLabel];
    KKRotationOSCParams p = {
        .rotCol0 = m.col0,
        .rotCol1 = m.col1,
        .rotCol2 = m.col2,
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
    // Overlay is Y-UP; the rotation math works in Y-DOWN screen space.
    CGPoint local = CGPointMake(p.x - center.x, center.y - p.y);
    KKRotMatrix3 m = [self _matrixForLabel:label axes:axes];
    for (int k = 0; k < 3; k++) {
      if ([self _ringAlphaForLabel:label axes:axes axis:k] <= 0.0f)
        continue; // hidden/disabled ring not grabbable
      KKRingHit h = KKClosestAngleOnRing(m, k, radius, local, kRotRingSamples);
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
  return [self _ringAtPoint:p
                contentRect:cr
                     canvas:self.renderer.canvas
                    outAxis:NULL
                   outAngle:NULL] != nil;
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
  return KKRotationAxisCursor(axis, atan2(p.y - c.y, p.x - c.x));
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
  // Y-DOWN screen tangent at the press ring point.
  KKRotMatrix3 m = [self _matrixForLabel:hit axes:axes];
  simd_float3 U, V;
  KKRingBasis(m, axis, &U, &V);
  double tx = -sin(t) * U.x + cos(t) * V.x;
  double ty = -sin(t) * U.y + cos(t) * V.y;
  double len = sqrt(tx * tx + ty * ty);
  if (len > 1e-6) {
    tx /= len;
    ty /= len;
  }
  _pressTangentX = tx;
  _pressTangentY = ty;
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
  // Project overlay-space mouse displacement onto the press-time tangent (dy
  // negated to bring overlay Y-UP into the tangent's Y-DOWN convention).
  double dx = p.x - _pressMouse.x;
  double dy = _pressMouse.y - p.y;
  double projected = dx * _pressTangentX + dy * _pressTangentY;
  // Axis signs {+1,-1,+1}, matching the single-lane path.
  double sign = (_activeAxis == 1) ? -1.0 : 1.0;
  double dAngle = sign * projected / (double)radius;
  if (modifiers & NSEventModifierFlagCommand)
    dAngle = round(dAngle / kRotSnapStep) * kRotSnapStep;
  double rx = 0, ry = 0, rz = 0;
  KKRotationComposeAxisDelta(_activeAxis, dAngle, _pressRx, _pressRy, _pressRz,
                             &_lastWrittenRx, &_lastWrittenRy, &_lastWrittenRz,
                             &rx, &ry, &rz);
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
