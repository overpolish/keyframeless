/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniViewerRenderer.h"
#import "KKMiniViewerView_Private.h"
#import "KKTokens.h"
#import <KeyframelessKit/KKLog.h>
#import <QuartzCore/QuartzCore.h> // CACurrentMediaTime (gesture-active timing)

// View transform (zoom / pan), pointer-handle dragging, and screen-rect
// geometry. The canvas's interactive surface, kept apart from the render path.
@implementation KKMiniViewerView (Interaction)

- (CGFloat)_backingScale {
  CGFloat s = self.window.backingScaleFactor;
  return s > 0 ? s : 2.0;
}

// A two-finger scroll runs the main thread in NSEventTrackingRunLoopMode, and
// the MTKView's draw (display-link callback AND on-demand setNeedsDisplay) is
// only serviced in the default mode - so during a pan the view starved to
// ~3-4fps even though each frame is ~7ms and setNeedsDisplay fired every event.
// (Magnify/zoom gestures don't trip this, which is why zoom was always smooth.)
// Rendering synchronously here forces the frame immediately, in whatever mode
// the runloop is in, so a pan repaints once per scroll event regardless.
- (void)_drawNowForInteraction {
  // Reuse the already-rendered effect texture for this frame - a pan/zoom only
  // moves the view over unchanged content, so re-running the plugin effect is
  // wasted work, and that waste throttles how fast macOS delivers scroll events
  // (a cheaper frame -> more events/sec -> smoother). Scoped to just this draw.
  _reuseProcessedTexture = YES;
  [self draw]; // MTKView: render one frame synchronously, now
  _reuseProcessedTexture = NO;
}

// Cursor-anchored zoom: keep the image point under `viewPt` (view points,
// y-up) fixed while scaling to `newZoom`.
- (BOOL)_isPanZoomGestureActive {
  // Scroll/pinch events arrive ~every 40ms or faster; 120ms covers the gap
  // between events (and a brief tail) without lingering once the gesture stops.
  return (CACurrentMediaTime() - _lastPanZoomTime) < 0.12;
}

- (void)_zoomTo:(CGFloat)newZoom aboutViewPoint:(NSPoint)viewPt {
  _lastPanZoomTime = CACurrentMediaTime();
  // Generous upper bound so you can inspect down to the pixel even on a small
  // source; the cap only exists to keep the pan math + float precision sane (an
  // unbounded zoom from a fast pinch could blow up the content rect). Lower
  // bound stays at fit-ish so zoom-out still frames the whole clip.
  newZoom = MAX(0.2, MIN(64.0, newZoom));
  CGFloat s = [self _backingScale];
  CGPoint c = CGPointMake(viewPt.x * s, viewPt.y * s);
  CGRect r0 = [self _contentRectInDrawable];
  if (r0.size.width <= 0 || r0.size.height <= 0 || _zoom <= 0) {
    _zoom = newZoom;
    [self setNeedsDisplay:YES];
    [self _didChangeViewTransformOfKind:KKMiniViewerTransformKindZoom];
    return;
  }
  CGFloat fx = (c.x - r0.origin.x) / r0.size.width;
  CGFloat fy = (c.y - r0.origin.y) / r0.size.height;
  CGFloat k = newZoom / _zoom;
  CGFloat newW = r0.size.width * k, newH = r0.size.height * k;
  CGSize d = self.drawableSize;
  // origin = (d/2 + pan) - newSize/2  ⇒  pan = origin - d/2 + newSize/2
  CGFloat originX = c.x - fx * newW, originY = c.y - fy * newH;
  _panPixels.x = originX - d.width / 2.0 + newW / 2.0;
  _panPixels.y = originY - d.height / 2.0 + newH / 2.0;
  _zoom = newZoom;
  [self setNeedsDisplay:YES];
  [self _didChangeViewTransformOfKind:KKMiniViewerTransformKindZoom];
}

// Pinch-to-zoom is routed through a LOCAL magnify monitor
// (-_installKeyMonitor), NOT a magnifyWithEvent: responder: AppKit delivers
// magnify gestures only to the key window, so the responder never fires while
// the companion layer list holds key (popover non-key). The monitor works in
// both states. Pan keeps the scrollWheel: responder below - AppKit delivers
// scroll to inactive windows, so it already works non-key.
- (void)scrollWheel:(NSEvent *)event {
  [super scrollWheel:event];
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  if (event.hasPreciseScrollingDeltas) {
    // Trackpad two-finger → pan.
    _lastPanZoomTime = CACurrentMediaTime();
    CGFloat s = [self _backingScale];
    _panPixels.x += event.scrollingDeltaX * s;
    _panPixels.y -= event.scrollingDeltaY * s; // drawable y is up; delta y-down
    [self _drawNowForInteraction]; // sync draw - setNeedsDisplay starves in
                                   // scroll tracking mode (see above)
    [self _didChangeViewTransformOfKind:KKMiniViewerTransformKindPan];
  } else {
    // Mouse wheel → zoom toward cursor.
    CGFloat factor = 1.0 - event.scrollingDeltaY * 0.05;
    [self _zoomTo:_zoom * factor aboutViewPoint:p];
  }
}

- (void)mouseDown:(NSEvent *)event {
  // End any focused value field (see _KKMiniViewerOverlay -mouseDown:).
  [self endFieldEditingGrabbingFocusIfNeeded];
  if (event.clickCount == 2) {
    [self resetView];
    return;
  }
  // Filmstrip: a click in an INACTIVE cell asks the host to swap the popover
  // to that KP. Single-slot mode (or click in the active cell) falls through.
  // Onion stacks every cell on the active rect - there's no spatial way to
  // pick a specific KP, so we suppress here and let the header's prev/next
  // buttons drive navigation instead.
  //
  // The swap is DEFERRED to mouseUp (recorded here as a pending tag) so a
  // click-and-drag pan over the strip doesn't instantly jump to whatever cell
  // the drag happened to start on. mouseDragged cancels the pending swap once
  // the gesture moves past the click threshold.
  _hasPendingFilmstripActivation = NO;
  _filmstripDragDistance = 0.0;
  NSUInteger n = _filmstripSlots.count;
  if (n > 1 && self.onFilmstripCellActivated && self.renderMode != 2) {
    NSPoint vp = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat s = self.window.backingScaleFactor;
    if (s <= 0)
      s = 2.0;
    NSUInteger active = [self _activeSlotIndex];
    for (NSUInteger i = 0; i < n; i++) {
      if (i == active)
        continue;
      CGRect cellDrawable = [self _filmstripCellRectInDrawable:i ofTotal:n];
      // Convert drawable px → view points so it lines up with `vp` (which is
      // in view points). The MTKView itself isn't flipped, so the Y origin
      // already matches; we just rescale.
      CGRect cell =
          CGRectMake(cellDrawable.origin.x / s, cellDrawable.origin.y / s,
                     cellDrawable.size.width / s, cellDrawable.size.height / s);
      if (CGRectContainsPoint(cell, vp)) {
        _hasPendingFilmstripActivation = YES;
        _pendingFilmstripTag = _filmstripSlots[i].tag;
        return;
      }
    }
  }
  // No handle (the overlay swallows those) and no filmstrip cell: offer the
  // click to the delegate as a background pick (e.g. click-to-select a layer).
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if ([d respondsToSelector:
              @selector(miniViewer:backgroundClickAtPoint:contentRect:)]) {
    [d miniViewer:self
        backgroundClickAtPoint:[self convertPoint:event.locationInWindow
                                         fromView:nil]
                   contentRect:[self contentRectInViewPoints]];
  }
}

- (void)mouseUp:(NSEvent *)event {
  if (!_hasPendingFilmstripActivation)
    return;
  _hasPendingFilmstripActivation = NO;
  // Reset pan so the newly-activated cell lands centred - otherwise the
  // existing pan stays applied to the new layout and the strip visually jumps
  // even further off-centre. (Any sub-threshold pan from a near-still click is
  // discarded here too.)
  _panPixels = CGPointZero;
  if (self.onFilmstripCellActivated)
    self.onFilmstripCellActivated(_pendingFilmstripTag);
}

- (void)resetView {
  _zoom = kKKMiniInitialZoom;
  _panPixels = CGPointZero;
  [self setNeedsDisplay:YES];
  if (self.onViewReset)
    self.onViewReset();
}

- (void)_didChangeViewTransformOfKind:(KKMiniViewerTransformKind)kind {
  if (self.onViewTransformChanged)
    self.onViewTransformChanged(kind);
}

- (NSPoint)_viewPointForScreenPoint:(NSPoint)screenPoint {
  NSWindow *w = self.window;
  if (!w)
    return NSZeroPoint;
  return [self convertPoint:[w convertPointFromScreen:screenPoint]
                   fromView:nil];
}

- (NSRect)guideToolbarButtonScreenRectForTag:(NSInteger)tag {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:@selector(
                                 miniViewer:toolbarButtonViewRectForTag:)])
    return NSZeroRect;
  NSRect vr = [d miniViewer:self toolbarButtonViewRectForTag:tag];
  if (NSIsEmptyRect(vr))
    return NSZeroRect;
  return [self.window convertRectToScreen:[self convertRect:vr toView:nil]];
}

- (BOOL)guidePressToolbarAtScreenPoint:(NSPoint)screenPoint {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (![d respondsToSelector:@selector(miniViewer:toolbarTagAtPoint:)])
    return NO;
  CGPoint vp = [self _viewPointForScreenPoint:screenPoint];
  if ([d miniViewer:self toolbarTagAtPoint:vp] == 0)
    return NO; // not over a toolbar item
  if ([d respondsToSelector:@selector(miniViewer:toolbarMouseDownAtPoint:)])
    [d miniViewer:self toolbarMouseDownAtPoint:vp];
  if ([d respondsToSelector:@selector(miniViewerToolbarMouseUp:)])
    [d miniViewerToolbarMouseUp:self];
  return YES;
}

// The XPC overlay swallows raw clicks/moves, so a guide drives the drawing
// tool from the spotlight handlers. Mirror the overlay's move: feed the hover
// point (rubber-band + snap ghost) and redraw, then the guide presents the tool
// cursor via -cursorAtScreenPoint:.
- (void)guideToolMoveToScreenPoint:(NSPoint)screenPoint {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (![d respondsToSelector:@selector(
                                 miniViewer:toolMovedToPoint:contentRect:)])
    return;
  [d miniViewer:self
      toolMovedToPoint:[self _viewPointForScreenPoint:screenPoint]
           contentRect:[self contentRectInViewPoints]];
  [self setNeedsDisplay:YES];
}

// One synthesized tap of the active drawing tool (down + up at the same point,
// no modifiers) - the mini's pen places / finishes a point per click.
- (void)guideToolClickAtScreenPoint:(NSPoint)screenPoint {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  CGPoint vp = [self _viewPointForScreenPoint:screenPoint];
  CGRect cr = [self contentRectInViewPoints];
  if ([d respondsToSelector:
              @selector(miniViewer:toolDownAtPoint:contentRect:modifiers:)])
    [d miniViewer:self toolDownAtPoint:vp contentRect:cr modifiers:0];
  if ([d respondsToSelector:@selector(miniViewer:toolUpAtPoint:contentRect:)])
    [d miniViewer:self toolUpAtPoint:vp contentRect:cr];
  [self setNeedsDisplay:YES];
}

// In-progress pen point count (held first point counts as 1), 0 when idle or
// finished - lets a guide advance per placed point.
- (NSInteger)guidePenPointCount {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (![d respondsToSelector:@selector(miniViewerGuidePenPointCount:)])
    return 0;
  return [d miniViewerGuidePenPointCount:self];
}

// A screen point at the given fraction of the canvas content rect (0..1, view
// space), so a guide can place draw targets that track the popover's size.
- (NSPoint)guideScreenPointForContentFractionX:(CGFloat)fx y:(CGFloat)fy {
  if (!self.window)
    return NSZeroPoint;
  CGRect cr = [self contentRectInViewPoints];
  if (CGRectIsEmpty(cr))
    return NSZeroPoint;
  NSPoint vp = NSMakePoint(CGRectGetMinX(cr) + fx * cr.size.width,
                           CGRectGetMinY(cr) + fy * cr.size.height);
  return [self.window convertPointToScreen:[self convertPoint:vp toView:nil]];
}

// The last placed in-progress pen point in screen space (NSZeroPoint when the
// pen is idle). A guide targets the finish click here so it lands on the anchor
// regardless of grid snap (clicking the last anchor finishes the open path).
- (NSPoint)guideLastPenPointScreen {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:@selector(miniViewerGuideLastPenPointView:)])
    return NSZeroPoint;
  NSPoint vp = [d miniViewerGuideLastPenPointView:self];
  if (NSEqualPoints(vp, NSZeroPoint))
    return NSZeroPoint;
  return [self.window convertPointToScreen:[self convertPoint:vp toView:nil]];
}

- (NSCursor *)cursorAtScreenPoint:(NSPoint)screenPoint {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (!self.window)
    return nil;
  CGPoint vp = [self _viewPointForScreenPoint:screenPoint];
  CGRect cr = [self contentRectInViewPoints];
  // A drawing tool owns the cursor over the canvas (the pen's place / close
  // glyph, the shape crosshair) - mirror the overlay's mouseMoved precedence so
  // a guide presents the SAME cursor the user would see hovering with the tool.
  // The toolbar still owns its own buttons (the toolbar step spotlights those).
  if ([d respondsToSelector:@selector(miniViewerToolDrawingActive:)] &&
      [d miniViewerToolDrawingActive:self] &&
      [d respondsToSelector:@selector(
                                miniViewer:toolCursorAtPoint:contentRect:)]) {
    BOOL overToolbar =
        [d respondsToSelector:@selector(miniViewer:toolbarTagAtPoint:)] &&
        [d miniViewer:self toolbarTagAtPoint:vp] != 0;
    if (!overToolbar)
      return [d miniViewer:self toolCursorAtPoint:vp contentRect:cr];
  }
  if (![d respondsToSelector:@selector(miniViewer:cursorAtPoint:contentRect:)])
    return nil;
  return [d miniViewer:self cursorAtPoint:vp contentRect:cr];
}

- (void)beginPointHandleDragAtScreenPoint:(NSPoint)screenPoint {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (![d respondsToSelector:
              @selector(miniViewer:beginHandleDragAtPoint:contentRect:)])
    return;
  [self endFieldEditingGrabbingFocusIfNeeded];
  if (self.onHandleDragBegin)
    self.onHandleDragBegin();
  [d miniViewer:self
      beginHandleDragAtPoint:[self _viewPointForScreenPoint:screenPoint]
                 contentRect:[self contentRectInViewPoints]];
}

- (void)dragPointHandleToScreenPoint:(NSPoint)screenPoint {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (![d respondsToSelector:@selector(
                                 miniViewer:dragHandleToPoint:contentRect:)])
    return;
  [d miniViewer:self
      dragHandleToPoint:[self _viewPointForScreenPoint:screenPoint]
            contentRect:[self contentRectInViewPoints]];
}

- (void)endPointHandleDrag {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if ([d respondsToSelector:@selector(miniViewerEndHandleDrag:)])
    [d miniViewerEndHandleDrag:self];
  if (self.onHandleDragEnd)
    self.onHandleDragEnd();
}

- (BOOL)optHideHandleAtScreenPoint:(NSPoint)screenPoint {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (!
      [d respondsToSelector:@selector(
                                miniViewer:optClickHandleAtPoint:contentRect:)])
    return NO;
  BOOL hit = [d miniViewer:self
      optClickHandleAtPoint:[self _viewPointForScreenPoint:screenPoint]
                contentRect:[self contentRectInViewPoints]];
  if (hit && self.onOptHideHandle)
    self.onOptHideHandle(@"");
  return hit;
}

- (void)setGuidePeekActive:(BOOL)active {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if ([d isKindOfClass:[KKMiniViewerRenderer class]]) {
    ((KKMiniViewerRenderer *)d).revealHidden = active;
    [self setNeedsDisplay:YES];
  }
}

// `ctr` is overlay points, y-up, in the canvas's own coordinate space (the
// overlay fills the canvas bounds 1:1) → glyph rect in screen space.
// The point handle's visual radius in view points. Arc-style handles (e.g.
// a Position handle) draw a ring ~2x the point dot that scales with the
// popover, so a guide spotlight must match it (mirrors +Rendering's arc glyph:
// outer 9pt at the 230pt baseline canvas height).
- (CGFloat)_pointHandleRadiusPt {
  id del = self.canvasDelegate;
  if ([del isKindOfClass:[KKMiniViewerRenderer class]] &&
      [(KKMiniViewerRenderer *)del pointHandleStyle] == KKMiniHandleStyleArc) {
    CGFloat canvasScale = self.oscSizingHeight / 230.0;
    if (canvasScale <= 0)
      canvasScale = 1.0;
    return 9.0 * canvasScale;
  }
  return kKKMiniHandleOuterPt;
}

- (NSRect)_screenRectForHandleCenter:(CGPoint)ctr radius:(CGFloat)r {
  NSWindow *w = self.window;
  if (!w)
    return NSZeroRect;
  NSRect inView = NSMakeRect(ctr.x - r, ctr.y - r, 2 * r, 2 * r);
  return [w convertRectToScreen:[self convertRect:inView toView:nil]];
}

- (NSRect)_screenRectForHandleCenter:(CGPoint)ctr {
  return [self _screenRectForHandleCenter:ctr radius:kKKMiniHandleOuterPt];
}

- (NSRect)pointHandleScreenRect {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (!self.window)
    return NSZeroRect;
  CGRect cr = [self contentRectInViewPoints];
  CGPoint ctr;
  if ([d respondsToSelector:@selector(
                                miniViewer:pointHandleCenter:contentRect:)] &&
      [d miniViewer:self pointHandleCenter:&ctr contentRect:cr])
    return [self _screenRectForHandleCenter:ctr
                                     radius:[self _pointHandleRadiusPt]];
  // Multi-point renderer (no single primary): resolve the active handle.
  if ([d respondsToSelector:
              @selector(miniViewer:activePointHandleCenter:contentRect:)] &&
      [d miniViewer:self activePointHandleCenter:&ctr contentRect:cr])
    return [self _screenRectForHandleCenter:ctr
                                     radius:[self _pointHandleRadiusPt]];
  return NSZeroRect;
}

- (NSRect)pointHandleScreenRectForValue:(double)value {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:
              @selector(miniViewer:pointHandleCenter:forValue:contentRect:)])
    return NSZeroRect;
  CGPoint ctr;
  if (![d miniViewer:self
          pointHandleCenter:&ctr
                   forValue:value
                contentRect:[self contentRectInViewPoints]])
    return NSZeroRect;
  return [self _screenRectForHandleCenter:ctr
                                   radius:[self _pointHandleRadiusPt]];
}

- (NSRect)pointHandleScreenRectForValues:(NSArray<NSNumber *> *)values {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (!self.window)
    return NSZeroRect;
  CGRect cr = [self contentRectInViewPoints];
  CGPoint ctr;
  if ([d respondsToSelector:
              @selector(miniViewer:pointHandleCenter:forValues:contentRect:)] &&
      [d miniViewer:self
          pointHandleCenter:&ctr
                  forValues:values
                contentRect:cr])
    return [self _screenRectForHandleCenter:ctr
                                     radius:[self _pointHandleRadiusPt]];
  // Multi-point renderer (no single primary): resolve the active handle.
  if ([d respondsToSelector:@selector(miniViewer:activePointHandleCenter:
                                      forValues:contentRect:)] &&
      [d miniViewer:self
          activePointHandleCenter:&ctr
                        forValues:values
                      contentRect:cr])
    return [self _screenRectForHandleCenter:ctr
                                     radius:[self _pointHandleRadiusPt]];
  return NSZeroRect;
}

- (NSRect)_screenRectForHandleCenters:(NSArray<NSValue *> *)centers
                              atIndex:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)centers.count)
    return NSZeroRect;
  return [self _screenRectForHandleCenter:centers[index].pointValue];
}

- (NSRect)cropHandleScreenRectAtIndex:(NSInteger)index {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:@selector(
                                 miniViewer:extraHandleCentersForContentRect:)])
    return NSZeroRect;
  return [self
      _screenRectForHandleCenters:
          [d miniViewer:self
              extraHandleCentersForContentRect:[self contentRectInViewPoints]]
                          atIndex:index];
}

- (NSRect)cropHandleScreenRectAtIndex:(NSInteger)index
                        forCropValues:(NSArray<NSNumber *> *)values {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:
              @selector(miniViewer:cropHandleCentersForValues:contentRect:)])
    return NSZeroRect;
  return
      [self _screenRectForHandleCenters:
                [d miniViewer:self
                    cropHandleCentersForValues:values
                                   contentRect:[self contentRectInViewPoints]]
                                atIndex:index];
}

- (NSRect)scaleHandleScreenRectAtIndex:(NSInteger)index {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:@selector(
                                 miniViewer:scaleHandleCentersForContentRect:)])
    return NSZeroRect;
  return [self
      _screenRectForHandleCenters:
          [d miniViewer:self
              scaleHandleCentersForContentRect:[self contentRectInViewPoints]]
                          atIndex:index];
}

- (NSRect)scaleHandleScreenRectAtIndex:(NSInteger)index
                        forScaleValues:(NSArray<NSNumber *> *)values {
  id<KKMiniViewerDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:
              @selector(miniViewer:scaleHandleCentersForValues:contentRect:)])
    return NSZeroRect;
  return
      [self _screenRectForHandleCenters:
                [d miniViewer:self
                    scaleHandleCentersForValues:values
                                    contentRect:[self contentRectInViewPoints]]
                                atIndex:index];
}

- (void)mouseDragged:(NSEvent *)event {
  CGFloat s = [self _backingScale];
  _panPixels.x += event.deltaX * s;
  _panPixels.y -= event.deltaY * s; // deltaY is y-down
  // Once the gesture clearly pans (moves past a small click threshold), it is
  // no longer a cell-selecting click - drop any pending filmstrip swap so the
  // active cell stays put while the user pans. deltaX/Y are in view points.
  if (_hasPendingFilmstripActivation) {
    _filmstripDragDistance += fabs(event.deltaX) + fabs(event.deltaY);
    if (_filmstripDragDistance > kKKMiniFilmstripClickSlopPt)
      _hasPendingFilmstripActivation = NO;
  }
  [self _drawNowForInteraction]; // mouse-drag also runs in tracking mode
  [self _didChangeViewTransformOfKind:KKMiniViewerTransformKindPan];
}

- (BOOL)_pointFromGlobalEvent:(NSPoint *)outViewPt {
  NSWindow *w = self.window;
  if (!w)
    return NO;
  // The magnify/scroll monitors are app-wide LOCAL monitors, and the inspector
  // ViewBridge process is shared across plugin instances - so a pinch fires
  // every mini-view's monitor in this process, including stale ones kept alive
  // after their popover closed and other instances' hidden minis. A hidden
  // window still reports a frame at its old screen location, so its bounds can
  // contain the cursor and it would claim (and swallow) the gesture before the
  // visible mini sees it. Only the on-screen mini may handle the event.
  if (!w.isVisible)
    return NO;
  NSPoint winPt = [w convertPointFromScreen:NSEvent.mouseLocation];
  NSPoint p = [self convertPoint:winPt fromView:nil];
  if (!NSPointInRect(p, self.bounds))
    return NO;
  *outViewPt = p;
  return YES;
}

- (BOOL)pointerOverCanvas {
  NSPoint p;
  return [self _pointFromGlobalEvent:&p];
}

- (BOOL)applyScrollEvent:(NSEvent *)event {
  NSPoint p;
  if (![self _pointFromGlobalEvent:&p])
    return NO;
  if (event.hasPreciseScrollingDeltas) {
    _lastPanZoomTime = CACurrentMediaTime();
    CGFloat s = [self _backingScale];
    _panPixels.x += event.scrollingDeltaX * s;
    _panPixels.y -= event.scrollingDeltaY * s;
    [self
        _drawNowForInteraction]; // sync draw - starves in scroll tracking mode
    [self _didChangeViewTransformOfKind:KKMiniViewerTransformKindPan];
  } else {
    [self _zoomTo:_zoom * (1.0 - event.scrollingDeltaY * 0.05)
        aboutViewPoint:p];
  }
  return YES;
}

- (BOOL)applyMagnifyEvent:(NSEvent *)event {
  NSPoint p;
  if (![self _pointFromGlobalEvent:&p])
    return NO;
  _lastPanZoomTime = CACurrentMediaTime();
  [self _zoomTo:_zoom * (1.0 + event.magnification) aboutViewPoint:p];
  // A pinch runs in a tracking run-loop mode where setNeedsDisplay (what
  // _zoomTo requests) starves the MTKView's on-demand draw - so the zoom is
  // applied but never rendered until the gesture ends. Force the synchronous
  // draw the pan path already uses for the same reason.
  [self _drawNowForInteraction];
  return YES;
}

@end

// Before/after compare: divider geometry and its drag. Interaction rather than
// draw, so the overlay's hit-test and the canvas's composite read the divider's
// position from ONE place and can't disagree by a pixel.
@implementation KKMiniViewerView (Compare)

- (BOOL)_compareBypassActive {
  return self.compareBypassing && self.compareAvailable;
}

// Bypass wins: holding "before" with a split armed shows a whole ungraded frame
// rather than a split of two identical halves.
- (BOOL)_compareSplitActive {
  return self.compareSplitEnabled && self.compareAvailable &&
         !self.compareBypassing;
}

/// Device pixels per view point, or 0 when the drawable has no size yet.
- (CGFloat)_compareBackingScale {
  CGSize drawable = self.drawableSize;
  CGFloat width = self.bounds.size.width;
  if (drawable.width <= 0.0 || width <= 0.0)
    return 0.0;
  return drawable.width / width;
}

// SNAPPED to a whole device pixel, and the composite's seam is snapped the same
// way from the same number. A divider at a fractional pixel puts the boundary
// between the two halves mid-texel: the edge samples both images at once and
// the seam bleeds and shimmers as it moves. Rounding the line without rounding
// the seam would be worse still - the stroke would sit a half pixel off the
// join it is supposed to mark.
- (CGFloat)_compareDividerXInViewPoints {
  if (![self _compareSplitActive] || self.livePlaybackActive)
    return -1.0;
  CGRect cr = [self contentRectInViewPoints];
  if (cr.size.width <= 0.5)
    return -1.0;
  CGFloat x = CGRectGetMinX(cr) + self.compareSplitFraction * cr.size.width;
  CGFloat scale = [self _compareBackingScale];
  return scale > 0.0 ? round(x * scale) / scale : x;
}

- (BOOL)_compareDividerGrabbableAtPoint:(CGPoint)point {
  CGFloat x = [self _compareDividerXInViewPoints];
  if (x < 0.0)
    return NO;
  CGRect cr = [self contentRectInViewPoints];
  if (point.y < CGRectGetMinY(cr) || point.y > CGRectGetMaxY(cr))
    return NO;
  return fabs(point.x - x) <= kKKMiniCompareGrabPt;
}

- (void)_dragCompareDividerToPoint:(CGPoint)point {
  CGRect cr = [self contentRectInViewPoints];
  if (cr.size.width <= 0.5)
    return;
  self.compareSplitFraction = (point.x - CGRectGetMinX(cr)) / cr.size.width;
  if (self.onCompareSplitFractionChanged)
    self.onCompareSplitFractionChanged(self.compareSplitFraction);
}

- (void)_compareStateChanged {
  if (self.onCompareStateChanged)
    self.onCompareStateChanged();
}

@end
