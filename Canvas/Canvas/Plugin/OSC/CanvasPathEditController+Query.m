/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h" // project / unproject
#import "CanvasPathEditController_Internal.h"
#import "CanvasPathEditGeometry.h" // CanvasDist2 / CanvasDistPtToSeg
#import "CanvasPathMorph.h" // morphed-at-frac geometry + keypose snapshots
#import <KeyframelessKit/KKBezierPath.h>

// Surface-px grab radii. Handles checked first (they extend out from the
// anchor).
static const double kAnchorGrabPx = 10.0;
static const double kHandleGrabPx = 9.0;
static const double kSegmentGrabPx = 6.0; // pen "add point" reach to the curve

@implementation CanvasPathEditController (Query)

- (KKBezierPath *)_path {
  NSString *sel = [_surface penSelectedLayerID];
  KKBezierPath *p = sel.length ? [_surface penLayerWithID:sel] : nil;
  if (!p || p.isImage || p.isGroup || !p.strokeEnabled || p.count < 1)
    return nil;
  return p;
}

- (KKBezierPath *)_workingPath {
  KKBezierPath *p = [self _path];
  if (!p)
    return nil;
  return CanvasPathMorphedAtFraction(p, [_surface penEditFraction]);
}

- (BOOL)_animatedOffKeypose {
  KKBezierPath *p = [self _path];
  if (!p)
    return NO;
  return !CanvasPathGeometryEditableAtFraction(p, [_surface penEditFraction]);
}

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
  double rh2 = kHandleGrabPx * kHandleGrabPx,
         ra2 = kAnchorGrabPx * kAnchorGrabPx;
  for (NSUInteger i = 0; i < path.count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    if (fabsf(pt.outX) + fabsf(pt.outY) > 1e-6f) {
      CGPoint s = [self _surfaceForLocalX:pt.x + pt.outX
                                        y:pt.y + pt.outY
                                     path:path];
      if (CanvasDist2(s, x, y) <= rh2) {
        *outAnchor = (NSInteger)i;
        *outHandleOut = YES;
        return CanvasPathEditHitHandle;
      }
    }
    if (fabsf(pt.inX) + fabsf(pt.inY) > 1e-6f) {
      CGPoint s = [self _surfaceForLocalX:pt.x + pt.inX
                                        y:pt.y + pt.inY
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

- (BOOL)canMarqueeAtX:(double)x y:(double)y {
  if ([self _animatedOffKeypose] || ![self _path])
    return NO;
  return [self hitTestAtX:x y:y] == CanvasPathEditHitNone;
}

- (BOOL)_segmentHitAtX:(double)x
                     y:(double)y
                outSeg:(NSUInteger *)outSeg
                  outT:(double *)outT {
  if ([self _animatedOffKeypose])
    return NO;
  KKBezierPath *path = [self _workingPath];
  if (!path || path.count < 2)
    return NO;
  NSUInteger segs = path.closed ? path.count : path.count - 1;
  const int kSteps = 24;
  double best = kSegmentGrabPx * kSegmentGrabPx;
  NSInteger bestSeg = -1;
  double bestT = 0;
  for (NSUInteger c = 0; c < segs; c++) {
    NSUInteger next = (c + 1) % path.count;
    CGPoint prev = CGPointZero;
    double prevTT = 0;
    BOOL have = NO;
    for (int i = 0; i <= kSteps; i++) {
      double tt = (double)i / kSteps;
      simd_float2 lp = [path evaluatePointAtIndex:c
                                        nextIndex:next
                                              atT:(float)tt];
      CGPoint s = [self _surfaceForLocalX:lp.x y:lp.y path:path];
      if (have) {
        double segT;
        double d2 = CanvasDistPtToSeg(x, y, prev, s, &segT);
        if (d2 < best) {
          best = d2;
          bestSeg = (NSInteger)c;
          bestT = prevTT + (tt - prevTT) * segT;
        }
      }
      prev = s;
      prevTT = tt;
      have = YES;
    }
  }
  if (bestSeg < 0)
    return NO;
  *outSeg = (NSUInteger)bestSeg;
  *outT = bestT;
  return YES;
}

- (BOOL)segmentHitAtX:(double)x y:(double)y {
  if (![self _path] || [self hitTestAtX:x y:y] != CanvasPathEditHitNone)
    return NO; // an anchor / handle under the point wins
  NSUInteger seg;
  double t;
  return [self _segmentHitAtX:x y:y outSeg:&seg outT:&t];
}

@end
