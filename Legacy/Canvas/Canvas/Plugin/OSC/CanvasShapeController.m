/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasShapeController.h"
#import "CanvasLocalized.h" // CLoc (default layer names)
#import <KeyframelessKit/KKBezierPath.h>

// The box must grow past this (surface px) before a press becomes a real drag,
// so a stray click doesn't drop a zero-size layer.
static const double kShapeMinDragPx = 3.0;
// Cubic control-handle ratio for a 4-point bezier circle/ellipse.
static const double kEllipseKappa = 0.5522847498307936;
// Preview-flatten steps per ellipse quadrant (rect corners need no
// subdivision).
#define kEllipsePreviewSteps 24

@implementation CanvasShapeController {
  __weak id<CanvasPenSurface> _surface;
  BOOL _dragging;
  BOOL _grew;         // moved past kShapeMinDragPx -> a box exists
  CGPoint _startObj;  // snapped Y-up object anchor (drag origin / centre)
  CGPoint _curObj;    // snapped Y-up object cursor
  CGPoint _startSurf; // press point (surface px) for the min-drag gate
  CanvasPenModifiers _mods;
}

- (instancetype)initWithSurface:(id<CanvasPenSurface>)surface {
  self = [super init];
  if (self)
    _surface = surface;
  return self;
}

- (BOOL)dragging {
  return _dragging;
}

// New shape layer defaults: identical to the pen's new path (stroke only) so
// the drawing tools are consistent; the corner widget / inspector tweak the
// rest.
static KKBezierPath *ShapeNewLayer(CanvasShapeKind kind) {
  KKBezierPath *layer = [[KKBezierPath alloc] init];
  layer.name =
      kind == CanvasShapeKindEllipse
          ? CLoc(@"Ellipse", @"Default name for a new ellipse layer")
          : CLoc(@"Rectangle", @"Default name for a new rectangle layer");
  layer.isImage = NO;
  layer.isGroup = NO;
  layer.strokeEnabled = YES;
  layer.strokeWidth = 20.0f;
  layer.strokeR = 1.0f;
  layer.strokeG = 0.0f;
  layer.strokeB = 0.0f;
  layer.opacity = 1.0f;
  return layer;
}

static void AddCorner(KKBezierPath *p, double x, double y) {
  NSUInteger i = p.count;
  [p insertAtIndex:i position:simd_make_float2((float)x, (float)y)];
}

static void AddBezier(KKBezierPath *p, double x, double y, double ox, double oy,
                      double ix, double iy) {
  NSUInteger i = p.count;
  [p insertAtIndex:i position:simd_make_float2((float)x, (float)y)];
  [p setType:KKBezierPointBezier atIndex:i];
  [p setOutHandle:simd_make_float2((float)ox, (float)oy) atIndex:i];
  [p setInHandle:simd_make_float2((float)ix, (float)iy) atIndex:i];
}

// Object-space bounding box from the drag, applying Shift (square in PIXEL
// space so the constraint is visual) + Opt (the anchor is the centre).
- (void)_boxMinX:(double *)minX
            minY:(double *)minY
            maxX:(double *)maxX
            maxY:(double *)maxY {
  double aspect = [_surface penCanvasAspect];
  if (aspect <= 0)
    aspect = 1.0;
  double dx = _curObj.x - _startObj.x, dy = _curObj.y - _startObj.y;
  if (_mods & CanvasPenModShift) {
    double side = MAX(fabs(dx) * aspect, fabs(dy)); // larger extent, in px
    dx = copysign(side / aspect, dx != 0 ? dx : 1.0);
    dy = copysign(side, dy != 0 ? dy : 1.0);
  }
  if (_mods & CanvasPenModOpt) {
    *minX = _startObj.x - fabs(dx);
    *maxX = _startObj.x + fabs(dx);
    *minY = _startObj.y - fabs(dy);
    *maxY = _startObj.y + fabs(dy);
  } else {
    *minX = MIN(_startObj.x, _startObj.x + dx);
    *maxX = MAX(_startObj.x, _startObj.x + dx);
    *minY = MIN(_startObj.y, _startObj.y + dy);
    *maxY = MAX(_startObj.y, _startObj.y + dy);
  }
}

// Build the closed shape from the current box, or nil if it's degenerate.
- (nullable KKBezierPath *)_buildShape {
  double minX, minY, maxX, maxY;
  [self _boxMinX:&minX minY:&minY maxX:&maxX maxY:&maxY];
  if (maxX - minX < 1e-5 || maxY - minY < 1e-5)
    return nil;
  KKBezierPath *p = ShapeNewLayer(self.kind);
  if (self.kind == CanvasShapeKindEllipse) {
    double cx = (minX + maxX) * 0.5, cy = (minY + maxY) * 0.5;
    double rx = (maxX - minX) * 0.5, ry = (maxY - minY) * 0.5;
    double hx = rx * kEllipseKappa, hy = ry * kEllipseKappa;
    // Counter-clockwise (Y-up): right, top, left, bottom.
    AddBezier(p, cx + rx, cy, 0, hy, 0, -hy);
    AddBezier(p, cx, cy + ry, -hx, 0, hx, 0);
    AddBezier(p, cx - rx, cy, 0, -hy, 0, hy);
    AddBezier(p, cx, cy - ry, hx, 0, -hx, 0);
  } else {
    AddCorner(p, minX, minY);
    AddCorner(p, maxX, minY);
    AddCorner(p, maxX, maxY);
    AddCorner(p, minX, maxY);
  }
  p.closed = YES;
  return p;
}

- (BOOL)mouseDownAtX:(double)x y:(double)y modifiers:(CanvasPenModifiers)mods {
  _startObj = _curObj = [_surface penSnappedObjFromSurfaceX:x y:y];
  _startSurf = CGPointMake(x, y);
  _mods = mods;
  _dragging = YES;
  _grew = NO;
  return YES;
}

- (void)mouseDraggedAtX:(double)x
                      y:(double)y
              modifiers:(CanvasPenModifiers)mods {
  if (!_dragging)
    return;
  _mods = mods;
  double dpx = x - _startSurf.x, dpy = y - _startSurf.y;
  if (!_grew && dpx * dpx + dpy * dpy < kShapeMinDragPx * kShapeMinDragPx)
    return; // not a real drag yet: no preview, no layer
  _grew = YES;
  _curObj = [_surface penSnappedObjFromSurfaceX:x y:y];
}

- (void)mouseUp {
  BOOL grew = _grew;
  _dragging = NO;
  _grew = NO;
  if (!grew)
    return; // a click with no drag: nothing to create
  KKBezierPath *shape = [self _buildShape];
  if (!shape)
    return;
  [_surface
      penMutateBlob:^(NSMutableArray<KKBezierPath *> *paths) {
        [paths insertObject:shape atIndex:0]; // index 0 = topmost
      }
      selectLayerID:shape.layerID];
}

- (void)draw {
  if (!_dragging || !_grew)
    return;
  KKBezierPath *shape = [self _buildShape];
  if (!shape || shape.count < 2)
    return;
  NSUInteger count = shape.count;
  NSUInteger steps =
      self.kind == CanvasShapeKindEllipse ? kEllipsePreviewSteps : 1;
  CGPoint pts[4 * kEllipsePreviewSteps + 1];
  NSUInteger n = 0;
  for (NSUInteger c = 0; c < count; c++) {
    NSUInteger next = (c + 1) % count;
    for (NSUInteger i = 0; i < steps; i++) {
      float t = (float)i / (float)steps;
      simd_float2 q = [shape evaluatePointAtIndex:c nextIndex:next atT:t];
      pts[n++] = CGPointMake(q.x, q.y);
    }
  }
  pts[n++] = pts[0]; // close the loop
  [_surface penDrawCurveObjPoints:pts count:n];
  for (NSUInteger c = 0; c < count; c++) {
    KKBezierPoint a = [shape pointAtIndex:c];
    [_surface penDrawDotAtObj:CGPointMake(a.x, a.y)
                        ghost:NO
                      hovered:NO
                       active:NO];
  }
}

@end
