/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h" // project / unproject
#import "CanvasPathEditController_Internal.h"
#import "CanvasPathEditGeometry.h" // CanvasDist2 / CanvasDistPtToSeg
#import "CanvasPathMorph.h" // morphed-at-frac geometry + keypose snapshots
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKShape.h> // KKRectShape (image extent)

// Surface-px grab radii. Handles checked first (they extend out from the
// anchor).
static const double kAnchorGrabPx = 10.0;
static const double kHandleGrabPx = 9.0;
static const double kSegmentGrabPx = 6.0; // pen "add point" reach to the curve

// PUBLIC methods (declared in CanvasPathEditController.h) implemented here as
// part of the intentional category split - silence the warning that they're not
// in the primary @implementation (which suppresses the matching -Wincomplete).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasPathEditController (Query)

- (KKBezierPath *)_path {
  NSString *sel = [_surface penSelectedLayerID];
  KKBezierPath *p = sel.length ? [_surface penLayerWithID:sel] : nil;
  if (!p || p.isImage || p.isGroup || (!p.strokeEnabled && !p.fillEnabled) ||
      p.count < 1)
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

// Context-reusing variant: the caller builds the projection context ONCE
// (CanvasProjCtxMake) and passes it in, so a whole-path hit-test loop is O(N)
// not O(N^2). The context is invariant under view pan/zoom (it is the LAYER
// transform, not the view's), so it stays valid across a pan gesture - and the
// per-anchor hit-test (_hitAtX / _cornerWidgetHitAtX) is what AppKit's
// -hitTest: hammers on every mouse/scroll event, so its O(N^2) form was what
// jammed the main thread (the cursor couldn't even move) on a busy path.
- (CGPoint)_surfaceForLocalX:(float)lx
                           y:(float)ly
                         ctx:(const CanvasProjCtx *)ctx {
  simd_float2 so = CanvasProjectWithCtx(ctx, lx, ly);
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
  if (path.count > kCanvasMaxEditableAnchors)
    return CanvasPathEditHitNone; // too large to edit per-anchor (perf)
  // Build the projection context ONCE - this loop runs on every AppKit
  // -hitTest:, so the old per-point rebuild made panning a busy path O(N^2) per
  // mouse event and jammed the main thread.
  CanvasProjCtx ctx = CanvasProjCtxMake([_surface penAllLayers], path,
                                        [_surface penEditFraction],
                                        (float)[_surface penCanvasAspect]);
  double rh2 = kHandleGrabPx * kHandleGrabPx,
         ra2 = kAnchorGrabPx * kAnchorGrabPx;
  // Prioritise the ANCHOR: a handle dot whose SURFACE position lands within the
  // anchor's grab disc is visually coincident with the anchor (e.g. a near-zero
  // tangent - nonzero in local coords but drawn right on top of the point), so
  // there's no distinct region to aim at. Skip it here and let the anchor loop
  // below win; only a handle extended clear of the anchor stays its own target.
  // (The local-coord 1e-6 skip alone missed this - a tiny tangent passes it but
  // still sits under the anchor, making the point impossible to grab.)
  for (NSUInteger i = 0; i < path.count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    CGPoint sa = [self _surfaceForLocalX:pt.x y:pt.y ctx:&ctx];
    if (fabsf(pt.outX) + fabsf(pt.outY) > 1e-6f) {
      CGPoint s = [self _surfaceForLocalX:pt.x + pt.outX
                                        y:pt.y + pt.outY
                                      ctx:&ctx];
      if (CanvasDist2(s, sa.x, sa.y) > ra2 && CanvasDist2(s, x, y) <= rh2) {
        *outAnchor = (NSInteger)i;
        *outHandleOut = YES;
        return CanvasPathEditHitHandle;
      }
    }
    if (fabsf(pt.inX) + fabsf(pt.inY) > 1e-6f) {
      CGPoint s = [self _surfaceForLocalX:pt.x + pt.inX
                                        y:pt.y + pt.inY
                                      ctx:&ctx];
      if (CanvasDist2(s, sa.x, sa.y) > ra2 && CanvasDist2(s, x, y) <= rh2) {
        *outAnchor = (NSInteger)i;
        *outHandleOut = NO;
        return CanvasPathEditHitHandle;
      }
    }
  }
  for (NSUInteger i = 0; i < path.count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    CGPoint s = [self _surfaceForLocalX:pt.x y:pt.y ctx:&ctx];
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

- (NSArray<NSString *> *)_layerIDsFullyInsideRect:(CGRect)r {
  if (CGRectIsEmpty(r))
    return @[];
  NSArray<KKBezierPath *> *layers = [_surface penAllLayers];
  NSSet<NSString *> *nonSelectable =
      [_surface respondsToSelector:@selector(penNonSelectableLayerIDs)]
          ? [_surface penNonSelectableLayerIDs]
          : nil;
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (KKBezierPath *layer in layers) {
    if (!layer.layerID.length || layer.hidden)
      continue;
    if ([nonSelectable containsObject:layer.layerID])
      continue; // not selectable in this popover scope (matches a click)
    CGFloat minX = CGFLOAT_MAX, minY = CGFLOAT_MAX;
    CGFloat maxX = -CGFLOAT_MAX, maxY = -CGFLOAT_MAX;
    // The layer's on-screen extent: a vector path's anchor bbox; an image's
    // RECT SHAPE corners (its actual quad, like the hit-test - NOT the unit
    // square, which is oversized so the image never enclosed); else the unit
    // square.
    if (!layer.isImage && layer.count >= 2) {
      for (NSUInteger i = 0; i < layer.count; i++) {
        KKBezierPoint pt = [layer pointAtIndex:i];
        CGPoint s = [self _surfaceForLocalX:pt.x y:pt.y path:layer];
        minX = MIN(minX, s.x);
        minY = MIN(minY, s.y);
        maxX = MAX(maxX, s.x);
        maxY = MAX(maxY, s.y);
      }
    } else {
      simd_float2 c[4];
      if ([layer.shape isKindOfClass:[KKRectShape class]]) {
        KKRectShape *r = (KKRectShape *)layer.shape;
        c[0] = simd_make_float2(r.min.x, r.min.y);
        c[1] = simd_make_float2(r.max.x, r.min.y);
        c[2] = simd_make_float2(r.max.x, r.max.y);
        c[3] = simd_make_float2(r.min.x, r.max.y);
      } else {
        c[0] = simd_make_float2(0, 0);
        c[1] = simd_make_float2(1, 0);
        c[2] = simd_make_float2(1, 1);
        c[3] = simd_make_float2(0, 1);
      }
      for (int k = 0; k < 4; k++) {
        CGPoint s = [self _surfaceForLocalX:c[k].x y:c[k].y path:layer];
        minX = MIN(minX, s.x);
        minY = MIN(minY, s.y);
        maxX = MAX(maxX, s.x);
        maxY = MAX(maxY, s.y);
      }
    }
    if (maxX < minX)
      continue;
    CGRect bb = CGRectMake(minX, minY, maxX - minX, maxY - minY);
    if (CGRectContainsRect(r, bb))
      [out addObject:layer.layerID];
  }
  return out;
}

- (BOOL)canMarqueeAtX:(double)x y:(double)y {
  // The marquee is now purely LAYER-level (it selects whole layers), so the
  // selected path's keypose / size state is irrelevant - it must only NOT start
  // on a live anchor / handle of the selected path (that's a point edit).
  // hitTestAtX already returns None when off-keypose / too-large / no path, so
  // this one check covers every case (and unblocks the marquee when an animated
  // path is selected between keyposes - the cause of the mini panning).
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
  if (path.count > kCanvasMaxEditableAnchors)
    return NO; // not editable per-anchor: skip the O(N) segment scan
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

#pragma clang diagnostic pop
