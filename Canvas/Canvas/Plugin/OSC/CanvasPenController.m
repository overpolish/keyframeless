/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPenController.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <QuartzCore/QuartzCore.h> // CACurrentMediaTime (double-click timing)

// Surface-px radius within which a click on the first / last anchor ends the path.
static const double kPenCloseRadiusPx = 10.0;
// Double-click finish: max gap between the two clicks (s) + max surface drift.
static const CFTimeInterval kPenDoubleClickSecs = 0.4;
static const double kPenDoubleClickSlopPx = 6.0;
// The mouse must move at least this far (surface px) from where it pressed before
// a press becomes a handle drag, so a click - especially with grid snap, where
// the anchor jumps to the grid but the cursor doesn't - doesn't curve by accident.
static const double kPenHandleMinDragPx = 6.0;
static const NSUInteger kPenCurveSamples = 24;

@interface CanvasPenController ()
- (void)_endSession;
- (nullable KKBezierPath *)_layer;
- (void)_mutateInProgress:(void (^)(KKBezierPath *layer))mutate;
- (void)_drawHandleAtAnchor:(CGPoint)anchorObj offset:(CGPoint)offset;
- (CGPoint)_constrainHandle:(CGPoint)h modifiers:(CanvasPenModifiers)mods;
@end

// An anchor for drawing: position + the two handle offsets (Y-up object space).
typedef struct {
  CGPoint pos;
  CGPoint out;
  CGPoint in;
} PenAnchor;

static simd_float2 PenEvalCubic(simd_float2 p0, simd_float2 c0, simd_float2 c1,
                                simd_float2 p1, float t) {
  float u = 1.0f - t;
  return u * u * u * p0 + 3.0f * u * u * t * c0 + 3.0f * u * t * t * c1 +
         t * t * t * p1;
}

@implementation CanvasPenController {
  __weak id<CanvasPenSurface> _surface;
  NSString *_layerID;          // the in-progress vector layer (nil = idle)
  BOOL _pendingActive;         // a point is placed but not yet committed
  CGPoint _pendingPos;         // Y-up object
  CGPoint _dragOut, _dragIn;   // pending point's handle offsets (Y-up object)
  BOOL _handleDragging;        // pulling the pending point's handles
  CGPoint _cursorObj;          // Y-up object (snapped) - rubber-band + ghost
  BOOL _cursorValid;
  CGPoint _downSurface;        // mouseDown surface point (drag threshold)
  CFTimeInterval _lastClickTime;
  CGPoint _lastClickSurface;
  BOOL _selectionSeen;         // latched once our layer is the resolved selection
  // The FIRST point is held transiently until a SECOND is placed, then the layer
  // is created with both in one action - so a 1-point (degenerate, invisible)
  // layer never persists and undo can't land on a single orphan anchor.
  BOOL _hasFirst;
  CGPoint _firstPos, _firstOut, _firstIn; // Y-up object
  // Closing the path: mouseDown landed on the first anchor. The close commits on
  // mouseUp so a click-drag can smooth the first anchor (curved closing segment),
  // matching the pen tool's place-a-point drag. No drag = plain corner close.
  BOOL _closing;
  BOOL _closeDragging;
  CGPoint _closeOut, _closeIn; // first anchor's handles being dragged (Y-up object)
}

static void PenAddPoint(KKBezierPath *l, CGPoint pos, CGPoint o, CGPoint in) {
  NSUInteger idx = l.count;
  [l insertAtIndex:idx position:simd_make_float2((float)pos.x, (float)pos.y)];
  if (fabs(o.x) + fabs(o.y) + fabs(in.x) + fabs(in.y) > 1e-6) {
    [l setType:KKBezierPointBezier atIndex:idx];
    [l setOutHandle:simd_make_float2((float)o.x, (float)o.y) atIndex:idx];
    [l setInHandle:simd_make_float2((float)in.x, (float)in.y) atIndex:idx];
  }
}

static KKBezierPath *PenNewLayer(void) {
  KKBezierPath *layer = [[KKBezierPath alloc] init];
  layer.name = @"Pen Path";
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

- (instancetype)initWithSurface:(id<CanvasPenSurface>)surface {
  self = [super init];
  if (self)
    _surface = surface;
  return self;
}

- (BOOL)active {
  return _layerID != nil || _pendingActive || _hasFirst;
}

- (void)_endSession {
  _layerID = nil;
  _cursorValid = NO;
  _handleDragging = NO;
  _pendingActive = NO;
  _selectionSeen = NO;
  _hasFirst = NO;
  _closing = NO;
  _closeDragging = NO;
}

- (KKBezierPath *)_layer {
  return _layerID ? [_surface penLayerWithID:_layerID] : nil;
}

- (BOOL)mouseDownAtX:(double)x y:(double)y modifiers:(CanvasPenModifiers)mods {
  KKBezierPath *layer = [self _layer];
  _downSurface = CGPointMake(x, y);
  double r2 = kPenCloseRadiusPx * kPenCloseRadiusPx;

  // Click the FIRST anchor to close the path (>= 2 points - a 2-point close is
  // a degenerate-but-harmless loop, and clicking the first anchor always reads
  // as "close").
  if (layer && layer.count >= 2) {
    KKBezierPoint p0 = [layer pointAtIndex:0];
    CGPoint f = [_surface penSurfacePointFromObj:CGPointMake(p0.x, p0.y)];
    if ((f.x - x) * (f.x - x) + (f.y - y) * (f.y - y) <= r2) {
      // Defer the close to mouseUp so a click-drag can smooth the first anchor.
      _closing = YES;
      _closeDragging = NO;
      _closeOut = CGPointZero;
      _closeIn = CGPointZero;
      return YES;
    }
  }
  // Click the LAST anchor to finish the open path as-is (no extra point).
  if (layer && layer.count >= 2) {
    KKBezierPoint pl = [layer pointAtIndex:layer.count - 1];
    CGPoint l = [_surface penSurfacePointFromObj:CGPointMake(pl.x, pl.y)];
    if ((l.x - x) * (l.x - x) + (l.y - y) * (l.y - y) <= r2) {
      [self _endSession];
      return YES;
    }
  }
  // Double-click anywhere finishes an open path (no clickCount on the surfaces).
  CFTimeInterval now = CACurrentMediaTime();
  BOOL dbl = layer && (now - _lastClickTime) < kPenDoubleClickSecs &&
             fabs(x - _lastClickSurface.x) < kPenDoubleClickSlopPx &&
             fabs(y - _lastClickSurface.y) < kPenDoubleClickSlopPx;
  _lastClickTime = now;
  _lastClickSurface = CGPointMake(x, y);
  if (dbl) {
    [self _endSession];
    return YES;
  }

  // Start a PENDING point (commits on mouseUp -> place + bezier are one undo).
  CGPoint obj = [_surface penSnappedObjFromSurfaceX:x y:y];
  _cursorObj = obj;
  _cursorValid = YES;
  _pendingActive = YES;
  _pendingPos = obj;
  _dragOut = CGPointZero;
  _dragIn = CGPointZero;
  _handleDragging = NO;
  return YES;
}

- (void)mouseMovedAtX:(double)x y:(double)y {
  _cursorObj = [_surface penSnappedObjFromSurfaceX:x y:y];
  _cursorValid = YES;
}

- (void)mouseDraggedAtX:(double)x y:(double)y modifiers:(CanvasPenModifiers)mods {
  double dpx = x - _downSurface.x, dpy = y - _downSurface.y;
  // Closing drag: pull the first anchor's tangent so the closing segment curves.
  if (_closing) {
    if (!_closeDragging &&
        dpx * dpx + dpy * dpy < kPenHandleMinDragPx * kPenHandleMinDragPx)
      return; // not enough movement yet: keep it a plain corner close
    CGPoint down = [_surface penObjFromSurfaceX:_downSurface.x y:_downSurface.y];
    CGPoint cur = [_surface penObjFromSurfaceX:x y:y];
    CGPoint outH =
        [self _constrainHandle:CGPointMake(cur.x - down.x, cur.y - down.y)
                     modifiers:mods];
    _closeOut = outH;
    _closeIn = (mods & CanvasPenModCtrl) ? CGPointZero
                                         : CGPointMake(-outH.x, -outH.y);
    _closeDragging = YES;
    _cursorObj = cur;
    _cursorValid = YES;
    return;
  }
  if (!_pendingActive)
    return;
  if (!_handleDragging &&
      dpx * dpx + dpy * dpy < kPenHandleMinDragPx * kPenHandleMinDragPx)
    return; // not enough movement yet: keep it a corner
  // Handle = the drag delta from the press point (pure tangent direction, free
  // of any grid-snap offset on the anchor).
  CGPoint down = [_surface penObjFromSurfaceX:_downSurface.x y:_downSurface.y];
  CGPoint cur = [_surface penObjFromSurfaceX:x y:y];
  CGPoint outH = [self _constrainHandle:CGPointMake(cur.x - down.x, cur.y - down.y)
                              modifiers:mods];
  _dragOut = outH;
  _dragIn = (mods & CanvasPenModCtrl) ? CGPointZero
                                      : CGPointMake(-outH.x, -outH.y);
  _handleDragging = YES;
  _cursorObj = cur;
  _cursorValid = YES;
}

- (void)mouseUp {
  if (_closing) {
    CGPoint o = _closeOut, in = _closeIn;
    BOOL dragged = _closeDragging;
    [self _mutateInProgress:^(KKBezierPath *l) {
      if (dragged && l.count >= 1) {
        [l setType:KKBezierPointBezier atIndex:0];
        [l setOutHandle:simd_make_float2((float)o.x, (float)o.y) atIndex:0];
        [l setInHandle:simd_make_float2((float)in.x, (float)in.y) atIndex:0];
      }
      l.closed = YES;
    }];
    [self _endSession];
    return;
  }
  if (!_pendingActive)
    return;
  CGPoint pos = _pendingPos, o = _dragOut, in = _dragIn;
  _pendingActive = NO;
  _handleDragging = NO;

  if (_layerID) {
    // Extend the existing layer by one point (one undo entry).
    [self _mutateInProgress:^(KKBezierPath *l) {
      PenAddPoint(l, pos, o, in);
    }];
    return;
  }
  if (!_hasFirst) {
    // Hold the first point transiently - don't create a 1-point layer.
    _hasFirst = YES;
    _firstPos = pos;
    _firstOut = o;
    _firstIn = in;
    return;
  }
  // Second point: create the layer with BOTH points + select, in one action, so
  // a single undo removes the whole initial path (no orphan single anchor).
  CGPoint fpos = _firstPos, fo = _firstOut, fi = _firstIn;
  KKBezierPath *layer = PenNewLayer();
  PenAddPoint(layer, fpos, fo, fi);
  PenAddPoint(layer, pos, o, in);
  _layerID = layer.layerID;
  _hasFirst = NO;
  [_surface penMutateBlob:^(NSMutableArray<KKBezierPath *> *paths) {
    [paths insertObject:layer atIndex:0]; // index 0 = topmost
  }
            selectLayerID:layer.layerID];
}

- (BOOL)keyDown:(unsigned short)asciiKey {
  if (!self.active)
    return NO;
  if (asciiKey == 27) { // Esc: discard the in-progress path (incl. a held 1st pt)
    NSString *targetID = _layerID;
    if (targetID)
      [_surface penMutateBlob:^(NSMutableArray<KKBezierPath *> *paths) {
        for (NSUInteger i = 0; i < paths.count; i++)
          if ([paths[i].layerID isEqualToString:targetID]) {
            [paths removeObjectAtIndex:i];
            break;
          }
      }
                selectLayerID:nil];
    [self _endSession];
    return YES;
  }
  if (asciiKey == 13 || asciiKey == 3 || asciiKey == 10) { // Return / Enter
    [self _endSession];                                     // finish open
    return YES;
  }
  return NO;
}

- (void)confirmIfContextLost {
  if (![_surface penToolActive]) {
    if (self.active) // tool deselected -> confirm (drop any held first point too)
      [self _endSession];
    return;
  }
  if (!_layerID)
    return;
  // Selection moved away -> confirm, but only after we've SEEN our own layer
  // become the resolved selection (the resolved selection lags our write, so
  // checking before that latches would kill every freshly-created path).
  NSString *sel = [_surface penSelectedLayerID];
  if ([sel isEqualToString:_layerID])
    _selectionSeen = YES;
  else if (_selectionSeen && sel.length)
    [self _endSession];
}

- (CanvasPenCursorKind)cursorKindAtX:(double)x y:(double)y {
  KKBezierPath *layer = [self _layer];
  double r2 = kPenCloseRadiusPx * kPenCloseRadiusPx;
  if (layer && layer.count >= 2) {
    KKBezierPoint p0 = [layer pointAtIndex:0];
    CGPoint f = [_surface penSurfacePointFromObj:CGPointMake(p0.x, p0.y)];
    if ((f.x - x) * (f.x - x) + (f.y - y) * (f.y - y) <= r2)
      return CanvasPenCursorClose;
  }
  if (layer && layer.count >= 2) {
    KKBezierPoint pl = [layer pointAtIndex:layer.count - 1];
    CGPoint l = [_surface penSurfacePointFromObj:CGPointMake(pl.x, pl.y)];
    if ((l.x - x) * (l.x - x) + (l.y - y) * (l.y - y) <= r2)
      return CanvasPenCursorClose;
  }
  return CanvasPenCursorPen;
}

- (void)draw {
  if (![_surface penToolActive])
    return; // nothing to draw when the pen tool isn't active (no stale ghost)
  // Grid-snap ghost: where the next click will land (shown while hovering with
  // snap on, even before the first point).
  if ([_surface penGridSnapping] && _cursorValid && !_pendingActive && !_closing)
    [_surface penDrawDotAtObj:_cursorObj ghost:YES hovered:NO active:NO];

  KKBezierPath *layer = [self _layer];
  if (_layerID && !layer) { // the layer was undone away - end cleanly
    [self _endSession];
    return;
  }
  // Base anchors: the committed layer points, or the transient held first point
  // (before a 2nd point creates the layer).
  NSUInteger n = layer ? layer.count : (_hasFirst ? 1 : 0);
  if (n == 0 && !_pendingActive)
    return;
  PenAnchor *base = n ? malloc(n * sizeof(PenAnchor)) : NULL;
  if (layer) {
    for (NSUInteger i = 0; i < n; i++) {
      KKBezierPoint pt = [layer pointAtIndex:i];
      base[i] = (PenAnchor){CGPointMake(pt.x, pt.y), CGPointMake(pt.outX, pt.outY),
                            CGPointMake(pt.inX, pt.inY)};
    }
  } else if (_hasFirst) {
    base[0] = (PenAnchor){_firstPos, _firstOut, _firstIn};
  }

  // Closing-drag preview: the closing segment (last anchor -> first anchor) with
  // the first anchor's dragged IN handle, plus the first anchor's smoothed handles
  // (override the base so the handle-drawing loop shows them being pulled).
  if (_closing && _closeDragging && n >= 2) {
    PenAnchor last = base[n - 1], first = base[0];
    simd_float2 p0 = {(float)last.pos.x, (float)last.pos.y};
    simd_float2 c0 = {(float)(last.pos.x + last.out.x),
                      (float)(last.pos.y + last.out.y)};
    simd_float2 p1 = {(float)first.pos.x, (float)first.pos.y};
    simd_float2 c1 = {(float)(first.pos.x + _closeIn.x),
                      (float)(first.pos.y + _closeIn.y)};
    CGPoint curve[kPenCurveSamples + 1];
    for (NSUInteger s = 0; s <= kPenCurveSamples; s++) {
      simd_float2 pt = PenEvalCubic(p0, c0, c1, p1, (float)s / kPenCurveSamples);
      curve[s] = CGPointMake(pt.x, pt.y);
    }
    [_surface penDrawCurveObjPoints:curve count:kPenCurveSamples + 1];
    base[0].out = _closeOut;
    base[0].in = _closeIn;
  }

  // The segment being formed: from the last base anchor to the pending / cursor
  // point. Always a cubic so it honours the last anchor's OUT handle and the
  // pending point's live IN handle while dragging.
  if (n >= 1 && !_closing && (_pendingActive || _cursorValid)) {
    PenAnchor a = base[n - 1];
    CGPoint endObj = _pendingActive ? _pendingPos : _cursorObj;
    CGPoint inH = _handleDragging ? _dragIn : CGPointZero;
    simd_float2 p0 = {(float)a.pos.x, (float)a.pos.y};
    simd_float2 c0 = {(float)(a.pos.x + a.out.x), (float)(a.pos.y + a.out.y)};
    simd_float2 p1 = {(float)endObj.x, (float)endObj.y};
    simd_float2 c1 = {p1.x + (float)inH.x, p1.y + (float)inH.y};
    CGPoint curve[kPenCurveSamples + 1];
    for (NSUInteger s = 0; s <= kPenCurveSamples; s++) {
      simd_float2 pt = PenEvalCubic(p0, c0, c1, p1, (float)s / kPenCurveSamples);
      curve[s] = CGPointMake(pt.x, pt.y);
    }
    [_surface penDrawCurveObjPoints:curve count:kPenCurveSamples + 1];
  }

  // Tangent handles for every base anchor + the pending point's live ones.
  for (NSUInteger i = 0; i < n; i++) {
    [self _drawHandleAtAnchor:base[i].pos offset:base[i].out];
    [self _drawHandleAtAnchor:base[i].pos offset:base[i].in];
  }
  if (_pendingActive) {
    [self _drawHandleAtAnchor:_pendingPos offset:_dragOut];
    [self _drawHandleAtAnchor:_pendingPos offset:_dragIn];
  }

  // Anchor dots; the first / last highlight when hovered (close / finish zones).
  BOOL nearFirst = NO, nearLast = NO;
  if (_cursorValid && !_pendingActive) {
    CGPoint c = [_surface penSurfacePointFromObj:_cursorObj];
    double r2 = kPenCloseRadiusPx * kPenCloseRadiusPx;
    if (n >= 2) {
      CGPoint f = [_surface penSurfacePointFromObj:base[0].pos];
      nearFirst = ((f.x - c.x) * (f.x - c.x) + (f.y - c.y) * (f.y - c.y) <= r2);
    }
    if (n >= 2 && !nearFirst) {
      CGPoint l = [_surface penSurfacePointFromObj:base[n - 1].pos];
      nearLast = ((l.x - c.x) * (l.x - c.x) + (l.y - c.y) * (l.y - c.y) <= r2);
    }
  }
  for (NSUInteger i = 0; i < n; i++) {
    BOOL hovered = (i == 0 && nearFirst) || (i == n - 1 && nearLast);
    [_surface penDrawDotAtObj:base[i].pos ghost:NO hovered:hovered active:NO];
  }
  if (_pendingActive)
    [_surface penDrawDotAtObj:_pendingPos ghost:NO hovered:NO active:YES];
  free(base);
}

- (void)_drawHandleAtAnchor:(CGPoint)anchorObj offset:(CGPoint)offset {
  if (fabs(offset.x) + fabs(offset.y) < 1e-6)
    return;
  [_surface penDrawHandleFromObj:anchorObj
                           toObj:CGPointMake(anchorObj.x + offset.x,
                                             anchorObj.y + offset.y)];
}

// Mutate the in-progress layer in the blob (no selection change).
- (void)_mutateInProgress:(void (^)(KKBezierPath *layer))mutate {
  NSString *targetID = _layerID;
  if (!targetID)
    return;
  [_surface penMutateBlob:^(NSMutableArray<KKBezierPath *> *paths) {
    for (KKBezierPath *p in paths)
      if ([p.layerID isEqualToString:targetID]) {
        mutate(p);
        break;
      }
  }
            selectLayerID:nil];
}

// Shift = axis-lock, Cmd = 45deg snap, in pixel space (object X scaled by the
// canvas aspect) so the constraint is visual, not skewed.
- (CGPoint)_constrainHandle:(CGPoint)h modifiers:(CanvasPenModifiers)mods {
  double aspect = [_surface penCanvasAspect];
  if (aspect <= 0)
    aspect = 1.0;
  double px = h.x * aspect, py = h.y;
  if (mods & CanvasPenModShift) {
    if (fabs(px) >= fabs(py))
      py = 0;
    else
      px = 0;
  } else if (mods & CanvasPenModCmd) {
    double mag = hypot(px, py);
    double step = M_PI / 4.0;
    double ang = round(atan2(py, px) / step) * step;
    px = mag * cos(ang);
    py = mag * sin(ang);
  }
  return CGPointMake(px / aspect, py);
}

@end
