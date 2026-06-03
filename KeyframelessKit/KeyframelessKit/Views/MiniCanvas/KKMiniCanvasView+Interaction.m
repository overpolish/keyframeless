/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniCanvasRenderer.h"
#import "KKMiniCanvasView_Private.h"
#import "KKTokens.h"
#import <KeyframelessKit/KKLog.h>

// View transform (zoom / pan), pointer-handle dragging, and screen-rect
// geometry. The canvas's interactive surface, kept apart from the render path.
@implementation KKMiniCanvasView (Interaction)

- (CGFloat)_backingScale {
  CGFloat s = self.window.backingScaleFactor;
  return s > 0 ? s : 2.0;
}

// Cursor-anchored zoom: keep the image point under `viewPt` (view points,
// y-up) fixed while scaling to `newZoom`.
- (void)_zoomTo:(CGFloat)newZoom aboutViewPoint:(NSPoint)viewPt {
  newZoom = MAX(0.2, MIN(8.0, newZoom));
  CGFloat s = [self _backingScale];
  CGPoint c = CGPointMake(viewPt.x * s, viewPt.y * s);
  CGRect r0 = [self _contentRectInDrawable];
  if (r0.size.width <= 0 || r0.size.height <= 0 || _zoom <= 0) {
    _zoom = newZoom;
    [self setNeedsDisplay:YES];
    [self _didChangeViewTransform];
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
  [self _didChangeViewTransform];
}

// Exact mechanism copied from the old KKStageSequencerView+InteractionZoomPan
// (which had working pinch/pan): plain responder overrides, scrollWheel:
// forwards to super first for a coherent NSScrollView event stream.
- (void)magnifyWithEvent:(NSEvent *)event {
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  [self _zoomTo:_zoom * (1.0 + event.magnification) aboutViewPoint:p];
}

- (void)scrollWheel:(NSEvent *)event {
  [super scrollWheel:event];
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  if (event.hasPreciseScrollingDeltas) {
    // Trackpad two-finger → pan.
    CGFloat s = [self _backingScale];
    _panPixels.x += event.scrollingDeltaX * s;
    _panPixels.y -= event.scrollingDeltaY * s; // drawable y is up; delta y-down
    [self setNeedsDisplay:YES];
    [self _didChangeViewTransform];
  } else {
    // Mouse wheel → zoom toward cursor.
    CGFloat factor = 1.0 - event.scrollingDeltaY * 0.05;
    [self _zoomTo:_zoom * factor aboutViewPoint:p];
  }
}

- (void)mouseDown:(NSEvent *)event {
  // End any focused value field (see _KKMiniCanvasOverlay -mouseDown:).
  [self.window makeFirstResponder:nil];
  if (event.clickCount == 2) {
    [self resetView];
    return;
  }
  // Filmstrip: a click in an INACTIVE cell asks the host to swap the popover
  // to that KP. Single-slot mode (or click in the active cell) falls through.
  // Onion stacks every cell on the active rect - there's no spatial way to
  // pick a specific KP, so we suppress here and let the header's prev/next
  // buttons drive navigation instead.
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
        // Reset pan so the newly-activated cell lands centred - otherwise
        // the existing pan stays applied to the new layout and the strip
        // visually jumps even further off-centre.
        _panPixels = CGPointZero;
        self.onFilmstripCellActivated(_filmstripSlots[i].tag);
        return;
      }
    }
  }
}

- (void)resetView {
  _zoom = kKKMiniInitialZoom;
  _panPixels = CGPointZero;
  [self setNeedsDisplay:YES];
  if (self.onViewReset)
    self.onViewReset();
}

- (void)_didChangeViewTransform {
  if (self.onViewTransformChanged)
    self.onViewTransformChanged();
}

- (NSPoint)_viewPointForScreenPoint:(NSPoint)screenPoint {
  NSWindow *w = self.window;
  if (!w)
    return NSZeroPoint;
  return [self convertPoint:[w convertPointFromScreen:screenPoint]
                   fromView:nil];
}

- (void)beginPointHandleDragAtScreenPoint:(NSPoint)screenPoint {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if (![d respondsToSelector:
              @selector(miniCanvas:beginHandleDragAtPoint:contentRect:)])
    return;
  [self.window makeFirstResponder:nil];
  if (self.onHandleDragBegin)
    self.onHandleDragBegin();
  [d miniCanvas:self
      beginHandleDragAtPoint:[self _viewPointForScreenPoint:screenPoint]
                 contentRect:[self contentRectInViewPoints]];
}

- (void)dragPointHandleToScreenPoint:(NSPoint)screenPoint {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if (![d respondsToSelector:@selector(
                                 miniCanvas:dragHandleToPoint:contentRect:)])
    return;
  [d miniCanvas:self
      dragHandleToPoint:[self _viewPointForScreenPoint:screenPoint]
            contentRect:[self contentRectInViewPoints]];
}

- (void)endPointHandleDrag {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if ([d respondsToSelector:@selector(miniCanvasEndHandleDrag:)])
    [d miniCanvasEndHandleDrag:self];
  if (self.onHandleDragEnd)
    self.onHandleDragEnd();
}

// `ctr` is overlay points, y-up, in the canvas's own coordinate space (the
// overlay fills the canvas bounds 1:1) → glyph rect in screen space.
- (NSRect)_screenRectForHandleCenter:(CGPoint)ctr {
  NSWindow *w = self.window;
  if (!w)
    return NSZeroRect;
  CGFloat r = kKKMiniHandleOuterPt;
  NSRect inView = NSMakeRect(ctr.x - r, ctr.y - r, 2 * r, 2 * r);
  return [w convertRectToScreen:[self convertRect:inView toView:nil]];
}

- (NSRect)pointHandleScreenRect {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:@selector(
                                 miniCanvas:pointHandleCenter:contentRect:)])
    return NSZeroRect;
  CGPoint ctr;
  if (![d miniCanvas:self
          pointHandleCenter:&ctr
                contentRect:[self contentRectInViewPoints]])
    return NSZeroRect;
  return [self _screenRectForHandleCenter:ctr];
}

- (NSRect)pointHandleScreenRectForValue:(double)value {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:
              @selector(miniCanvas:pointHandleCenter:forValue:contentRect:)])
    return NSZeroRect;
  CGPoint ctr;
  if (![d miniCanvas:self
          pointHandleCenter:&ctr
                   forValue:value
                contentRect:[self contentRectInViewPoints]])
    return NSZeroRect;
  return [self _screenRectForHandleCenter:ctr];
}

- (NSRect)_screenRectForHandleCenters:(NSArray<NSValue *> *)centers
                              atIndex:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)centers.count)
    return NSZeroRect;
  return [self _screenRectForHandleCenter:centers[index].pointValue];
}

- (NSRect)cropHandleScreenRectAtIndex:(NSInteger)index {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:@selector(
                                 miniCanvas:extraHandleCentersForContentRect:)])
    return NSZeroRect;
  return [self
      _screenRectForHandleCenters:
          [d miniCanvas:self
              extraHandleCentersForContentRect:[self contentRectInViewPoints]]
                          atIndex:index];
}

- (NSRect)cropHandleScreenRectAtIndex:(NSInteger)index
                        forCropValues:(NSArray<NSNumber *> *)values {
  id<KKMiniCanvasDelegate> d = self.canvasDelegate;
  if (!self.window ||
      ![d respondsToSelector:
              @selector(miniCanvas:cropHandleCentersForValues:contentRect:)])
    return NSZeroRect;
  return
      [self _screenRectForHandleCenters:
                [d miniCanvas:self
                    cropHandleCentersForValues:values
                                   contentRect:[self contentRectInViewPoints]]
                                atIndex:index];
}

- (void)mouseDragged:(NSEvent *)event {
  CGFloat s = [self _backingScale];
  _panPixels.x += event.deltaX * s;
  _panPixels.y -= event.deltaY * s; // deltaY is y-down
  [self setNeedsDisplay:YES];
  [self _didChangeViewTransform];
}

- (BOOL)_pointFromGlobalEvent:(NSPoint *)outViewPt {
  NSWindow *w = self.window;
  if (!w)
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
    CGFloat s = [self _backingScale];
    _panPixels.x += event.scrollingDeltaX * s;
    _panPixels.y -= event.scrollingDeltaY * s;
    [self setNeedsDisplay:YES];
    [self _didChangeViewTransform];
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
  [self _zoomTo:_zoom * (1.0 + event.magnification) aboutViewPoint:p];
  return YES;
}

@end
