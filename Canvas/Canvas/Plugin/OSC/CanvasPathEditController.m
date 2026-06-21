/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRender.h" // project / unproject
#import "CanvasAnchorSelectionSync.h" // cross-process selection sync
#import "CanvasPathEditController_Internal.h"
#import "CanvasPathMorph.h" // per-keypose geometry writes
#import <KeyframelessKit/KKBezierPath.h>
#import <QuartzCore/QuartzCore.h> // CACurrentMediaTime (double-click timing)

static const CFTimeInterval kDoubleClickSecs = 0.4; // anchor convert (viewer)

@implementation CanvasPathEditController

- (instancetype)initWithSurface:(id<CanvasPenSurface>)surface {
  self = [super init];
  if (self) {
    _surface = surface;
    _grabAnchor = -1;
    _grabCorner = -1;
    _lastClickAnchor = -1;
    _selectedAnchors = [NSMutableIndexSet indexSet];
  }
  return self;
}

- (BOOL)dragging {
  return _dragging;
}

- (NSIndexSet *)selectedAnchors {
  return _selectedAnchors;
}

- (void)clearSelection {
  [_selectedAnchors removeAllIndexes];
  [self _publishSelection];
}

- (void)setSelectedAnchorIndexes:(NSIndexSet *)indexes {
  // Applied from the other surface's published selection - set without
  // re-publishing so the two surfaces can't ping-pong.
  [_selectedAnchors removeAllIndexes];
  if (indexes)
    [_selectedAnchors addIndexes:indexes];
}

- (void)_publishSelection {
  CanvasPublishAnchorSelection([_surface penSurfaceTag],
                               [_surface penSelectedLayerID], _selectedAnchors);
}

- (BOOL)marqueeActive {
  return _marqueeActive;
}

- (CGRect)marqueeSurfaceRect {
  return CGRectMake(MIN(_marqueeStart.x, _marqueeEnd.x),
                    MIN(_marqueeStart.y, _marqueeEnd.y),
                    fabs(_marqueeEnd.x - _marqueeStart.x),
                    fabs(_marqueeEnd.y - _marqueeStart.y));
}

- (BOOL)mouseDownAtX:(double)x y:(double)y modifiers:(CanvasPenModifiers)mods {
  _didDrag = NO;
  _didEdit = NO;
  _dragMods = mods;
  NSInteger a = -1;
  BOOL ho = NO;
  CanvasPathEditHit hit = [self _hitAtX:x y:y outAnchor:&a outHandleOut:&ho];

  if (hit == CanvasPathEditHitHandle) {
    _lastClickAnchor = -1; // a handle click breaks a double-click-on-anchor run
    _grabAnchor = a;
    _grabIsHandle = YES;
    _grabHandleIsOut = ho;
    _dragStartGeom = [[self _workingPath] copy];
    _dragging = YES;
    return YES;
  }

  if (hit == CanvasPathEditHitAnchor) {
    // Double-click the same anchor (within the window) toggles corner<->smooth.
    // The mini diverts its 2nd click to its native doubleClickAtPoint, so this
    // timing path only fires for the viewer (which sends every click here).
    CFTimeInterval now = CACurrentMediaTime();
    if (a == _lastClickAnchor && (now - _lastClickTime) < kDoubleClickSecs) {
      _lastClickTime = 0;
      _lastClickAnchor = -1;
      _dragging = NO;
      [self _toggleSmoothAtIndex:(NSUInteger)a];
      return YES;
    }
    _lastClickTime = now;
    _lastClickAnchor = a;
    if (mods & CanvasPenModShift) {
      // Shift toggles this anchor in/out of the selection.
      if ([_selectedAnchors containsIndex:(NSUInteger)a])
        [_selectedAnchors removeIndex:(NSUInteger)a];
      else
        [_selectedAnchors addIndex:(NSUInteger)a];
    } else if (![_selectedAnchors containsIndex:(NSUInteger)a]) {
      // Plain click on an unselected anchor: it becomes the sole selection.
      // Clicking an already-selected anchor keeps the whole set (drag moves
      // all).
      [_selectedAnchors removeAllIndexes];
      [_selectedAnchors addIndex:(NSUInteger)a];
    }
    _grabAnchor = a;
    _grabIsHandle = NO;
    _dragStartGeom = [[self _workingPath] copy];
    // Only drag if the grabbed anchor ended up selected (a shift-deselect
    // won't).
    _dragging = [_selectedAnchors containsIndex:(NSUInteger)a];
    return YES;
  }

  // Corner-radius widget (just inside a corner, in the empty area): start a
  // radius drag. Checked before the marquee so the widget is grabbable.
  _lastClickAnchor = -1; // an empty click breaks a double-click-on-anchor run
  NSInteger cw = [self _cornerWidgetHitAtX:x y:y];
  if (cw >= 0) {
    _grabCorner = cw;
    _grabAnchor = -1;
    _dragStartGeom = [[self _workingPath] copy];
    _dragging = YES;
    return YES;
  }

  // Empty: start a marquee (only over an editable selected path).
  if (![self canMarqueeAtX:x y:y])
    return NO;
  if (!(mods & (CanvasPenModShift | CanvasPenModOpt)))
    [_selectedAnchors removeAllIndexes]; // plain marquee replaces the selection
  _marqueeStart = _marqueeEnd = CGPointMake(x, y);
  _marqueeActive = YES;
  _dragging = YES;
  _grabAnchor = -1;
  return YES;
}

- (void)mouseDraggedAtX:(double)x
                      y:(double)y
              modifiers:(CanvasPenModifiers)mods {
  if (!_dragging)
    return;
  _didDrag = YES;
  _dragMods = mods;
  if (_marqueeActive) {
    _marqueeEnd = CGPointMake(x, y);
    return; // the surface redraws on drag; selection commits on mouseUp
  }

  // Corner-radius drag (lives in the +Corners category).
  if (_grabCorner >= 0) {
    [self _dragCornerToX:x y:y modifiers:mods];
    return;
  }
  if (_grabAnchor < 0 || !_dragStartGeom ||
      _grabAnchor >= (NSInteger)_dragStartGeom.count)
    return;
  _didEdit = YES; // this gesture changes geometry -> commit on mouseUp
  KKBezierPath *base = [self _path];
  KKBezierPath *start = _dragStartGeom; // stable base so multi-move can't drift
  if (!base)
    return;
  NSArray<KKBezierPath *> *layers = [_surface penAllLayers];
  double frac = [_surface penEditFraction];
  float aspect = (float)[_surface penCanvasAspect];
  NSInteger idx = _grabAnchor;
  BOOL isHandle = _grabIsHandle, isOut = _grabHandleIsOut;
  NSString *targetID = base.layerID;

  // Handles drag free; anchors grid-snap (like the pen). Unproject through the
  // START geometry's transform so the cursor maps to a stable local space for
  // the whole drag.
  CGPoint so = isHandle ? [_surface penObjFromSurfaceX:x y:y]
                        : [_surface penSnappedObjFromSurfaceX:x y:y];
  simd_float2 local = CanvasUnprojectLayerPointObj(layers, start, frac, aspect,
                                                   (float)so.x, (float)so.y);
  KKBezierPath *edited = [start copy];
  if (isHandle) {
    KKBezierPoint pt = [start pointAtIndex:idx];
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
    // Move every selected anchor by the same delta (the grabbed one lands on
    // the grid-snapped cursor; the rest keep their relative offsets).
    KKBezierPoint g = [start pointAtIndex:idx];
    simd_float2 delta = simd_make_float2(local.x - g.x, local.y - g.y);
    NSIndexSet *sel = _selectedAnchors.count
                          ? _selectedAnchors
                          : [NSIndexSet indexSetWithIndex:idx];
    [sel enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
      if (i >= start.count)
        return;
      KKBezierPoint p = [start pointAtIndex:i];
      [edited moveAtIndex:i to:simd_make_float2(p.x + delta.x, p.y + delta.y)];
    }];
  }

  // Write to the active keypose's snapshot when animated + parked at one, else
  // the base geometry. Live (no undo) for a smooth drag; mouseUp commits once.
  KKBezierPath *result = CanvasPathByWritingWorkingGeometry(base, frac, edited);
  NSMutableArray<KKBezierPath *> *paths = [layers mutableCopy];
  for (NSUInteger i = 0; i < paths.count; i++)
    if ([paths[i].layerID isEqualToString:targetID]) {
      paths[i] = result;
      break;
    }
  [_surface penSetLiveLayers:paths];
}

- (void)mouseUp {
  if (_marqueeActive) {
    [self _finalizeMarquee];
    _marqueeActive = NO;
    _dragging = NO;
    _grabAnchor = -1;
    _grabCorner = -1;
    _dragStartGeom = nil;
    [self _publishSelection]; // selection changed - sync to the other surface
    return;                   // selection-only: no geometry change to commit
  }
  if (_dragging && _didEdit)
    [_surface penCommitLiveLayers]; // covers a pen-insert click with no drag
  _dragging = NO;
  _grabAnchor = -1;
  _grabCorner = -1;
  _dragStartGeom = nil;
  // Sync the (possibly changed) selection to the other surface.
  [self _publishSelection];
}

// Select every anchor whose projected position lands inside the marquee rect.
// Opt subtracts, Shift/plain add (a plain marquee already cleared the set on
// mouseDown). Selection only - no geometry write.
- (void)_finalizeMarquee {
  KKBezierPath *path = [self _workingPath];
  if (!path)
    return;
  CGRect r = [self marqueeSurfaceRect];
  BOOL subtract = (_dragMods & CanvasPenModOpt) != 0;
  for (NSUInteger i = 0; i < path.count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    CGPoint s = [self _surfaceForLocalX:pt.x y:pt.y path:path];
    if (!CGRectContainsPoint(r, s))
      continue;
    if (subtract)
      [_selectedAnchors removeIndex:i];
    else
      [_selectedAnchors addIndex:i];
  }
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
