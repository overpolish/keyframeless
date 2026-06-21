/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasCornerFillet.h" // corner widget geometry + radius
#import "CanvasPathEditController_Internal.h"
#import "CanvasPathEditGeometry.h" // CanvasDist2
#import "CanvasPathMorph.h"        // CanvasPathByWritingWorkingGeometry
#import <KeyframelessKit/KKBezierPath.h>

static const double kCornerWidgetGrabPx = 9.0; // widget hit radius (surface px)

@implementation CanvasPathEditController (Corners)

// The corner-radius widget under a surface point, or -1. Widgets sit just
// inside each interior corner (offset along the bisector), so they live in the
// path's empty area - checked after anchors / handles, before a marquee.
- (NSInteger)_cornerWidgetHitAtX:(double)x y:(double)y {
  if ([self _animatedOffKeypose])
    return -1;
  KKBezierPath *path = [self _workingPath];
  if (!path)
    return -1;
  float aspect = (float)[_surface penCanvasAspect];
  NSArray<KKBezierPath *> *layers = [_surface penAllLayers];
  double frac = [_surface penEditFraction];
  double grab2 = kCornerWidgetGrabPx * kCornerWidgetGrabPx;
  for (NSUInteger i = 0; i < path.count; i++) {
    CanvasCornerWidget w = CanvasCornerWidgetObj(layers, path, frac, aspect, i);
    if (!w.valid)
      continue;
    CGPoint s = [_surface
        penSurfacePointFromObj:CGPointMake(w.widgetObj.x, w.widgetObj.y)];
    if (CanvasDist2(s, x, y) <= grab2)
      return (NSInteger)i;
  }
  return -1;
}

- (BOOL)cornerWidgetHitAtX:(double)x y:(double)y {
  return [self _cornerWidgetHitAtX:x y:y] >= 0;
}

// Live corner-radius drag: map the cursor's bisector projection (object space,
// like an anchor drag) to a radius, written per-keypose (live; one undo on
// mouseUp). The grabbed corner is `_grabCorner`, geometry frozen at
// `_dragStartGeom`.
- (void)_dragCornerToX:(double)x
                     y:(double)y
             modifiers:(CanvasPenModifiers)mods {
  KKBezierPath *base = [self _path];
  KKBezierPath *start = _dragStartGeom;
  if (!base || !start)
    return;
  float aspect = (float)[_surface penCanvasAspect];
  NSArray<KKBezierPath *> *layers = [_surface penAllLayers];
  double frac = [_surface penEditFraction];
  CanvasCornerWidget w = CanvasCornerWidgetObj(layers, start, frac, aspect,
                                               (NSUInteger)_grabCorner);
  if (!w.valid)
    return;
  _didEdit = YES;
  // Cursor in object space (post-layer-transform), projected onto the grabbed
  // corner's interior bisector; the offset matches the widget's resting gap, so
  // there's no jump on grab. Convert the object-space radius back to the stored
  // local (the per-object scale is the same for every corner of the path).
  CGPoint so = [_surface penObjFromSurfaceX:x y:y];
  simd_float2 curPx = simd_make_float2((float)so.x * aspect, (float)so.y);
  float proj = simd_dot(curPx - w.anchorObjPx, w.bisObj);
  float rObj = proj - w.baseOffsetObjPx;
  if (rObj < 0)
    rObj = 0;
  if (rObj > w.maxRadiusObjPx)
    rObj = w.maxRadiusObjPx;
  float localRadius = rObj * w.localPerObjScale;
  KKBezierPath *edited = [start copy];
  // Apply to every selected corner when the grabbed one is part of a
  // multi-selection (so dragging one ring rounds them all); otherwise just the
  // grabbed corner. Each corner clamps to ITS OWN max (a tighter corner can't
  // round as far), and non-fillettable anchors (endpoints / near-straight) are
  // skipped.
  BOOL multi = _selectedAnchors.count > 1 &&
               [_selectedAnchors containsIndex:(NSUInteger)_grabCorner];
  NSIndexSet *targets =
      multi ? _selectedAnchors
            : [NSIndexSet indexSetWithIndex:(NSUInteger)_grabCorner];
  [targets enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
    if (i >= start.count)
      return;
    CanvasCornerWidget wt =
        (i == (NSUInteger)_grabCorner)
            ? w
            : CanvasCornerWidgetObj(layers, start, frac, aspect, i);
    if (!wt.valid)
      return;
    float maxLocal = wt.maxRadiusObjPx * wt.localPerObjScale;
    float r = localRadius > maxLocal ? maxLocal : localRadius;
    [edited setCornerRadius:r atIndex:i];
  }];
  KKBezierPath *result = CanvasPathByWritingWorkingGeometry(base, frac, edited);
  NSMutableArray<KKBezierPath *> *paths = [layers mutableCopy];
  for (NSUInteger i = 0; i < paths.count; i++)
    if ([paths[i].layerID isEqualToString:base.layerID]) {
      paths[i] = result;
      break;
    }
  [_surface penSetLiveLayers:paths];
}

@end
