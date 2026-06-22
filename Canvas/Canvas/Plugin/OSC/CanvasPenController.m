/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLocalized.h"  // CLoc (default layer name)
#import "CanvasPathMorph.h" // morphed-at-frac geometry + per-keypose write
#import "CanvasPenController_Internal.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <QuartzCore/QuartzCore.h> // CACurrentMediaTime (double-click timing)

// Double-click finish: max gap between the two clicks (s) + max surface drift.
static const CFTimeInterval kPenDoubleClickSecs = 0.4;
static const double kPenDoubleClickSlopPx = 6.0;
// The mouse must move at least this far (surface px) from where it pressed
// before a press becomes a handle drag, so a click - especially with grid snap,
// where the anchor jumps to the grid but the cursor doesn't - doesn't curve by
// accident.
static const double kPenHandleMinDragPx = 6.0;

// The public -draw is implemented in the +Draw category (the intentional split),
// not here, so the primary @implementation is deliberately "incomplete".
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"

@implementation CanvasPenController

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
  layer.name = CLoc(@"Pen Path", @"Default name for a new pen-drawn path layer");
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
  _resumedExisting = NO;
}

- (KKBezierPath *)_layer {
  return _layerID ? [_surface penLayerWithID:_layerID] : nil;
}

// The in-progress / resumed layer's geometry AS SHOWN at the current fraction
// (the parked keypose's snapshot for an animated path, else the base). All the
// drawing + endpoint hit-tests read this so a resumed animated path behaves at
// the keypose, not the base.
- (KKBezierPath *)_workingLayer {
  KKBezierPath *l = [self _layer];
  return l ? CanvasPathMorphedAtFraction(l, [_surface penEditFraction]) : nil;
}

// The selected path the pen can RESUME drawing: an OPEN editable vector path
// whose geometry is editable at the current fraction (constant or parked on a
// keypose). Returns the BASE path (its layerID + write target); the endpoints
// to click come from its working geometry. nil while already drawing.
- (KKBezierPath *)_resumableBase {
  if (_layerID || _hasFirst || _pendingActive)
    return nil;
  NSString *selID = [_surface penSelectedLayerID];
  KKBezierPath *p = selID.length ? [_surface penLayerWithID:selID] : nil;
  if (!p || p.isImage || p.isGroup || !p.strokeEnabled || p.closed ||
      p.count < 1)
    return nil;
  if (!CanvasPathGeometryEditableAtFraction(p, [_surface penEditFraction]))
    return nil;
  return p;
}

// Append one anchor to the resumed / in-progress layer, written PER-KEYPOSE:
// the point lands in the parked keypose's geometry (morph bridges the others),
// or the base for a constant path. One undo per added point.
- (void)_appendPointToLayer:(CGPoint)pos out:(CGPoint)o in:(CGPoint)in {
  NSString *targetID = _layerID;
  if (!targetID)
    return;
  double frac = [_surface penEditFraction];
  [_surface
      penMutateBlob:^(NSMutableArray<KKBezierPath *> *paths) {
        for (NSUInteger i = 0; i < paths.count; i++) {
          if (![paths[i].layerID isEqualToString:targetID])
            continue;
          KKBezierPath *base = paths[i];
          KKBezierPath *edited = [CanvasPathMorphedAtFraction(base, frac) copy];
          PenAddPoint(edited, pos, o,
                      in); // append at the end (the last anchor)
          paths[i] = CanvasPathByWritingWorkingGeometry(base, frac, edited);
          break;
        }
      }
      selectLayerID:nil];
}

- (BOOL)mouseDownAtX:(double)x y:(double)y modifiers:(CanvasPenModifiers)mods {
  KKBezierPath *layer = [self _layer];
  KKBezierPath *geo =
      [self _workingLayer]; // displayed geometry (keypose snapshot)
  _downSurface = CGPointMake(x, y);
  double r2 = kPenCloseRadiusPx * kPenCloseRadiusPx;

  // RESUME: idle + click near the SELECTED open path's end anchor -> continue
  // drawing from that tip. The LAST anchor appends directly; the FIRST anchor
  // reverses the path (so the old first becomes the last) then appends - both
  // per-keypose. Esc must not delete the existing path.
  if (!layer) {
    KKBezierPath *rb = [self _resumableBase];
    KKBezierPath *rw =
        rb ? CanvasPathMorphedAtFraction(rb, [_surface penEditFraction]) : nil;
    if (rw.count >= 1) {
      KKBezierPoint lp = [rw pointAtIndex:rw.count - 1];
      CGPoint ls = [_surface penSurfacePointFromObj:CGPointMake(lp.x, lp.y)];
      if ((ls.x - x) * (ls.x - x) + (ls.y - y) * (ls.y - y) <= r2) {
        _layerID = rb.layerID;
        _resumedExisting = YES;
        _selectionSeen = YES;
        return YES; // resumed at the last anchor; the next click appends
      }
    }
    if (rw.count >= 2) {
      KKBezierPoint fp = [rw pointAtIndex:0];
      CGPoint fs = [_surface penSurfacePointFromObj:CGPointMake(fp.x, fp.y)];
      if ((fs.x - x) * (fs.x - x) + (fs.y - y) * (fs.y - y) <= r2) {
        NSString *tid = rb.layerID;
        [_surface
            penMutateBlob:^(NSMutableArray<KKBezierPath *> *paths) {
              for (NSUInteger i = 0; i < paths.count; i++)
                if ([paths[i].layerID isEqualToString:tid]) {
                  paths[i] = CanvasPathByReversingGeometry(paths[i]);
                  break;
                }
            }
            selectLayerID:nil];
        _layerID = tid;
        _resumedExisting = YES;
        _selectionSeen = YES;
        return YES; // reversed; the old first anchor is now the last - append
      }
    }
  }

  // Click the FIRST anchor to close the path (>= 2 points - a 2-point close is
  // a degenerate-but-harmless loop, and clicking the first anchor always reads
  // as "close").
  if (geo && geo.count >= 2) {
    KKBezierPoint p0 = [geo pointAtIndex:0];
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
  if (geo && geo.count >= 2) {
    KKBezierPoint pl = [geo pointAtIndex:geo.count - 1];
    CGPoint l = [_surface penSurfacePointFromObj:CGPointMake(pl.x, pl.y)];
    if ((l.x - x) * (l.x - x) + (l.y - y) * (l.y - y) <= r2) {
      [self _endSession];
      return YES;
    }
  }
  // Double-click anywhere finishes an open path (no clickCount on the
  // surfaces).
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

- (void)mouseDraggedAtX:(double)x
                      y:(double)y
              modifiers:(CanvasPenModifiers)mods {
  double dpx = x - _downSurface.x, dpy = y - _downSurface.y;
  // Closing drag: pull the first anchor's tangent so the closing segment
  // curves.
  if (_closing) {
    if (!_closeDragging &&
        dpx * dpx + dpy * dpy < kPenHandleMinDragPx * kPenHandleMinDragPx)
      return; // not enough movement yet: keep it a plain corner close
    CGPoint down = [_surface penObjFromSurfaceX:_downSurface.x
                                              y:_downSurface.y];
    CGPoint cur = [_surface penObjFromSurfaceX:x y:y];
    CGPoint outH =
        [self _constrainHandle:CGPointMake(cur.x - down.x, cur.y - down.y)
                     modifiers:mods];
    _closeOut = outH;
    _closeIn =
        (mods & CanvasPenModCtrl) ? CGPointZero : CGPointMake(-outH.x, -outH.y);
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
  CGPoint outH =
      [self _constrainHandle:CGPointMake(cur.x - down.x, cur.y - down.y)
                   modifiers:mods];
  _dragOut = outH;
  _dragIn =
      (mods & CanvasPenModCtrl) ? CGPointZero : CGPointMake(-outH.x, -outH.y);
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
    // Extend the existing / resumed layer by one point, PER-KEYPOSE (one undo).
    [self _appendPointToLayer:pos out:o in:in];
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
  [_surface
      penMutateBlob:^(NSMutableArray<KKBezierPath *> *paths) {
        [paths insertObject:layer atIndex:0]; // index 0 = topmost
      }
      selectLayerID:layer.layerID];
}

- (BOOL)keyDown:(unsigned short)asciiKey {
  if (!self.active)
    return NO;
  if (asciiKey ==
      27) { // Esc: discard the in-progress path (incl. a held 1st pt)
    NSString *targetID = _layerID;
    // Only delete a path WE created this session. A resumed existing path keeps
    // its committed points (Esc just stops continuing; cmd-Z undoes appends).
    if (targetID && !_resumedExisting)
      [_surface
          penMutateBlob:^(NSMutableArray<KKBezierPath *> *paths) {
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
    [self _endSession];                                    // finish open
    return YES;
  }
  return NO;
}

- (void)confirmIfContextLost {
  if (![_surface penToolActive]) {
    if (self.active) // tool deselected -> confirm (drop any held first point
                     // too)
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
  KKBezierPath *geo = [self _workingLayer];
  double r2 = kPenCloseRadiusPx * kPenCloseRadiusPx;
  if (geo && geo.count >= 2) {
    KKBezierPoint p0 = [geo pointAtIndex:0];
    CGPoint f = [_surface penSurfacePointFromObj:CGPointMake(p0.x, p0.y)];
    if ((f.x - x) * (f.x - x) + (f.y - y) * (f.y - y) <= r2)
      return CanvasPenCursorClose;
  }
  if (geo && geo.count >= 2) {
    KKBezierPoint pl = [geo pointAtIndex:geo.count - 1];
    CGPoint l = [_surface penSurfacePointFromObj:CGPointMake(pl.x, pl.y)];
    if ((l.x - x) * (l.x - x) + (l.y - y) * (l.y - y) <= r2)
      return CanvasPenCursorClose;
  }
  return CanvasPenCursorPen;
}

// Mutate the in-progress layer in the blob (no selection change).
- (void)_mutateInProgress:(void (^)(KKBezierPath *layer))mutate {
  NSString *targetID = _layerID;
  if (!targetID)
    return;
  [_surface
      penMutateBlob:^(NSMutableArray<KKBezierPath *> *paths) {
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

#pragma clang diagnostic pop
