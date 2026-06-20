/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPathEditController.h"
#import "CanvasLayerRender.h" // project / unproject
#import "CanvasPathMorph.h"   // morphed-at-frac geometry + keypose snapshots
#import <KeyframelessKit/KKBezierPath.h>

// Surface-px grab radii. Handles checked first (they extend out from the anchor).
static const double kAnchorGrabPx = 10.0;
static const double kHandleGrabPx = 9.0;

static inline double CanvasDist2(CGPoint s, double x, double y) {
  return (s.x - x) * (s.x - x) + (s.y - y) * (s.y - y);
}

@implementation CanvasPathEditController {
  __weak id<CanvasPenSurface> _surface;
  BOOL _dragging;
  NSInteger _grabAnchor; // index, -1 = none
  BOOL _grabIsHandle;
  BOOL _grabHandleIsOut; // which tangent handle of the anchor
}

- (instancetype)initWithSurface:(id<CanvasPenSurface>)surface {
  self = [super init];
  if (self) {
    _surface = surface;
    _grabAnchor = -1;
  }
  return self;
}

- (BOOL)dragging {
  return _dragging;
}

// The selected layer if it's an editable vector path, else nil.
- (KKBezierPath *)_path {
  NSString *sel = [_surface penSelectedLayerID];
  KKBezierPath *p = sel.length ? [_surface penLayerWithID:sel] : nil;
  if (!p || p.isImage || p.isGroup || !p.strokeEnabled || p.count < 1)
    return nil;
  return p;
}

// The geometry shown / edited at the current fraction: the base for a constant
// path, or the interpolated shape for an animated one. nil if no editable path.
- (KKBezierPath *)_workingPath {
  KKBezierPath *p = [self _path];
  if (!p)
    return nil;
  return CanvasPathMorphedAtFraction(p, [_surface penEditFraction]);
}

// YES when the path is animated but the playhead is NOT parked on a Points
// keypose - geometry isn't editable there (add a keypose to edit that moment).
- (BOOL)_animatedOffKeypose {
  KKBezierPath *p = [self _path];
  if (!p)
    return NO;
  return !CanvasPathGeometryEditableAtFraction(p, [_surface penEditFraction]);
}

// Local (Y-up) -> surface point, through the layer transform + groups.
- (CGPoint)_surfaceForLocalX:(float)lx y:(float)ly path:(KKBezierPath *)path {
  simd_float2 so = CanvasProjectLayerPointObj(
      [_surface penAllLayers], path, [_surface penEditFraction],
      (float)[_surface penCanvasAspect], lx, ly);
  return [_surface penSurfacePointFromObj:CGPointMake(so.x, so.y)];
}

- (CanvasPathEditHit)_hitAtX:(double)x
                           y:(double)y
                   outAnchor:(NSInteger *)outAnchor
                outHandleOut:(BOOL *)outHandleOut {
  if ([self _animatedOffKeypose])
    return CanvasPathEditHitNone; // between keyposes: read-only
  KKBezierPath *path = [self _workingPath];
  if (!path)
    return CanvasPathEditHitNone;
  double rh2 = kHandleGrabPx * kHandleGrabPx, ra2 = kAnchorGrabPx * kAnchorGrabPx;
  for (NSUInteger i = 0; i < path.count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    if (fabsf(pt.outX) + fabsf(pt.outY) > 1e-6f) {
      CGPoint s = [self _surfaceForLocalX:pt.x + pt.outX y:pt.y + pt.outY
                                     path:path];
      if (CanvasDist2(s, x, y) <= rh2) {
        *outAnchor = (NSInteger)i;
        *outHandleOut = YES;
        return CanvasPathEditHitHandle;
      }
    }
    if (fabsf(pt.inX) + fabsf(pt.inY) > 1e-6f) {
      CGPoint s = [self _surfaceForLocalX:pt.x + pt.inX y:pt.y + pt.inY
                                     path:path];
      if (CanvasDist2(s, x, y) <= rh2) {
        *outAnchor = (NSInteger)i;
        *outHandleOut = NO;
        return CanvasPathEditHitHandle;
      }
    }
  }
  for (NSUInteger i = 0; i < path.count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    CGPoint s = [self _surfaceForLocalX:pt.x y:pt.y path:path];
    if (CanvasDist2(s, x, y) <= ra2) {
      *outAnchor = (NSInteger)i;
      *outHandleOut = NO;
      return CanvasPathEditHitAnchor;
    }
  }
  return CanvasPathEditHitNone;
}

- (CanvasPathEditHit)hitTestAtX:(double)x y:(double)y {
  NSInteger a = -1;
  BOOL ho = NO;
  return [self _hitAtX:x y:y outAnchor:&a outHandleOut:&ho];
}

- (BOOL)mouseDownAtX:(double)x y:(double)y modifiers:(CanvasPenModifiers)mods {
  NSInteger a = -1;
  BOOL ho = NO;
  CanvasPathEditHit hit = [self _hitAtX:x y:y outAnchor:&a outHandleOut:&ho];
  if (hit == CanvasPathEditHitNone)
    return NO;
  _grabAnchor = a;
  _grabIsHandle = (hit == CanvasPathEditHitHandle);
  _grabHandleIsOut = ho;
  _dragging = YES;
  return YES;
}

- (void)mouseDraggedAtX:(double)x
                      y:(double)y
              modifiers:(CanvasPenModifiers)mods {
  if (!_dragging || _grabAnchor < 0)
    return;
  KKBezierPath *base = [self _path];
  KKBezierPath *work = [self _workingPath]; // morphed geometry at this fraction
  if (!base || !work || _grabAnchor >= (NSInteger)work.count)
    return;
  NSArray<KKBezierPath *> *layers = [_surface penAllLayers];
  double frac = [_surface penEditFraction];
  float aspect = (float)[_surface penCanvasAspect];
  NSInteger idx = _grabAnchor;
  BOOL isHandle = _grabIsHandle, isOut = _grabHandleIsOut;
  NSString *targetID = base.layerID;

  // Handles drag free; anchors grid-snap (like the pen). Unproject through the
  // WORKING geometry's transform so the cursor maps to its local point space.
  CGPoint so = isHandle ? [_surface penObjFromSurfaceX:x y:y]
                        : [_surface penSnappedObjFromSurfaceX:x y:y];
  simd_float2 local = CanvasUnprojectLayerPointObj(layers, work, frac, aspect,
                                                   (float)so.x, (float)so.y);
  // Apply the move to a copy of the working geometry.
  KKBezierPath *edited = [work copy];
  if (isHandle) {
    KKBezierPoint pt = [edited pointAtIndex:idx];
    simd_float2 off = simd_make_float2(local.x - pt.x, local.y - pt.y);
    off = [self _constrain:off aspect:aspect modifiers:mods];
    [edited setType:KKBezierPointBezier atIndex:idx];
    if (isOut) {
      [edited setOutHandle:off atIndex:idx];
      if (!(mods & CanvasPenModCtrl))
        [edited setInHandle:simd_make_float2(-off.x, -off.y) atIndex:idx];
    } else {
      [edited setInHandle:off atIndex:idx];
      if (!(mods & CanvasPenModCtrl))
        [edited setOutHandle:simd_make_float2(-off.x, -off.y) atIndex:idx];
    }
  } else {
    [edited moveAtIndex:idx to:simd_make_float2(local.x, local.y)];
  }

  // Write to the active keypose's snapshot when animated + parked at one, else
  // the base geometry. Live (no undo) for a smooth drag; mouseUp commits once.
  NSInteger kp =
      CanvasPathActiveKeyposeAtFraction(base, frac, kCanvasPathKeyposeEps);
  KKBezierPath *result =
      (kp >= 0) ? CanvasPathBySettingKeyposeGeometry(base, kp, edited) : edited;
  NSMutableArray<KKBezierPath *> *paths = [layers mutableCopy];
  for (NSUInteger i = 0; i < paths.count; i++)
    if ([paths[i].layerID isEqualToString:targetID]) {
      paths[i] = result;
      break;
    }
  [_surface penSetLiveLayers:paths];
}

- (void)mouseUp {
  if (_dragging)
    [_surface penCommitLiveLayers];
  _dragging = NO;
  _grabAnchor = -1;
}

// Shift = axis-lock, Cmd = 45deg snap, computed in pixel space (object X scaled
// by the canvas aspect) so the constraint is visual - same as the pen.
- (simd_float2)_constrain:(simd_float2)h
                   aspect:(float)aspect
                modifiers:(CanvasPenModifiers)mods {
  if (aspect <= 0)
    aspect = 1.0f;
  double px = h.x * aspect, py = h.y;
  if (mods & CanvasPenModShift) {
    if (fabs(px) >= fabs(py))
      py = 0;
    else
      px = 0;
  } else if (mods & CanvasPenModCmd) {
    double mag = hypot(px, py), step = M_PI / 4.0;
    double ang = round(atan2(py, px) / step) * step;
    px = mag * cos(ang);
    py = mag * sin(ang);
  }
  return simd_make_float2((float)(px / aspect), (float)py);
}

@end
