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

// Some PUBLIC methods (declared in CanvasPathEditController.h) are implemented
// here rather than in the primary @implementation - the intentional category
// split. That trips the category-implements-primary-method warning, so silence
// it for this file (the primary suppresses the matching -Wincomplete).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasPathEditController (Corners)

// The corner-radius widget under a surface point, or -1. Widgets sit just
// inside each interior corner (offset along the bisector), so they live in the
// path's empty area - checked after anchors / handles, before a marquee.
- (NSInteger)_cornerWidgetHitAtX:(double)x y:(double)y {
  if (!self.cornerWidgetsActive)
    return -1; // "Corners" OSC element hidden: widgets aren't grabbable
  if ([self _animatedOffKeypose])
    return -1;
  KKBezierPath *path = [self _workingPath];
  if (!path)
    return -1;
  float aspect = (float)[_surface penCanvasAspect];
  NSArray<KKBezierPath *> *layers = [_surface penAllLayers];
  double frac = [_surface penEditFraction];
  // Build the projection context ONCE - this runs on every AppKit -hitTest:, so
  // the per-corner CanvasProjCtxMake rebuild was O(N^2) per mouse event.
  CanvasProjCtx ctx = CanvasProjCtxMake(layers, path, frac, aspect);
  double grab2 = kCornerWidgetGrabPx * kCornerWidgetGrabPx;
  for (NSUInteger i = 0; i < path.count; i++) {
    CanvasCornerWidget w = CanvasCornerWidgetObjCtx(path, i, &ctx);
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
  // Which corners receive the new radius:
  //  - Shift held: ALL corners at once (no selection needed) - the "tweak every
  //    corner" gesture.
  //  - else grabbed one is in a multi-selection: every SELECTED corner.
  //  - else: just the grabbed corner.
  // Each corner clamps to ITS OWN max (a tighter corner can't round as far),
  // and non-fillettable anchors (endpoints / near-straight) are skipped.
  BOOL all = (mods & CanvasPenModShift) != 0;
  BOOL multi = _selectedAnchors.count > 1 &&
               [_selectedAnchors containsIndex:(NSUInteger)_grabCorner];
  NSIndexSet *targets =
      all ? [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, start.count)]
          : (multi ? _selectedAnchors
                   : [NSIndexSet indexSetWithIndex:(NSUInteger)_grabCorner]);
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

#pragma clang diagnostic pop
