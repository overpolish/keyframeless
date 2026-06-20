/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniViewerRenderer.h"
#import "KKMiniViewerView_Private.h"
#import "NSColor+KKColors.h"

@implementation _KKMiniViewerOverlay {
  BOOL _dragging;
  BOOL _toolbarDragging;
  NSTrackingArea *_optTrackingArea;
  BOOL _optReveal;
}

- (BOOL)isFlipped {
  return NO;
}

// Fill attributes for OSC size readouts: 9pt monospaced-medium, light-gray
// (0xC1) fill - the same color the viewer's KKOSCLabel uses. Used both for
// measuring the text and as the fill pass in -drawReadout:.
+ (NSDictionary *)readoutAttributes {
  return @{
    NSFontAttributeName :
        [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightMedium],
    NSForegroundColorAttributeName : [NSColor colorWithRed:0xC1 / 255.0
                                                     green:0xC1 / 255.0
                                                      blue:0xC1 / 255.0
                                                     alpha:1.0],
  };
}

// Draws a readout with the viewer's look: a black outline stroke underneath a
// light-gray fill. NSStrokeWidth is a percentage of the font's point size, so
// the same 15.0 (== KKOSCLabel's 3pt/20pt*100) gives a matched relative
// outline at the mini's 9pt font.
+ (void)drawReadout:(NSString *)txt
            atPoint:(NSPoint)at
     fillAttributes:(NSDictionary *)fillAttrs {
  NSMutableDictionary *strokeAttrs = [fillAttrs mutableCopy];
  strokeAttrs[NSForegroundColorAttributeName] = [NSColor colorWithWhite:0.0
                                                                  alpha:0.8];
  strokeAttrs[NSStrokeColorAttributeName] = [NSColor colorWithWhite:0.0
                                                              alpha:0.8];
  strokeAttrs[NSStrokeWidthAttributeName] = @(15.0);
  [txt drawAtPoint:at withAttributes:strokeAttrs];
  [txt drawAtPoint:at withAttributes:fillAttrs];
}

- (NSView *)hitTest:(NSPoint)pt {
  KKMiniViewerView *c = self.canvas;
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  NSPoint p = [self convertPoint:pt fromView:self.superview];
  // The toolbar (chrome) sits on top: claim its hits before the handles so the
  // click doesn't fall through to a layer drag / pan.
  if ([d respondsToSelector:@selector(miniViewer:toolbarTagAtPoint:)] &&
      [d miniViewer:c toolbarTagAtPoint:p] != 0)
    return self;
  if (![d respondsToSelector:@selector(
                                 miniViewer:handleHitAtPoint:contentRect:)])
    return nil;
  return [d miniViewer:c
             handleHitAtPoint:p
                  contentRect:[c contentRectInViewPoints]]
             ? self
             : nil;
}

// Handles are drawn by the canvas's Metal pass (shared KKPointOSC shader).
// The crop border is a thin stroke and is cheaper/sharper drawn here in
// Core Graphics than via a Metal line pipeline.
- (void)drawRect:(NSRect)dirtyRect {
  KKMiniViewerView *c = self.canvas;
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  CGRect cr = [c contentRectInViewPoints];
  if (_dragging &&
      [d respondsToSelector:@selector(miniViewer:snapGuideHasX:X:fromKeyposeX:
                                      hasY:Y:fromKeyposeY:)]) {
    BOOL hasX = NO, hasY = NO, kpX = NO, kpY = NO;
    CGFloat gx = 0, gy = 0;
    [d miniViewer:c
        snapGuideHasX:&hasX
                    X:&gx
         fromKeyposeX:&kpX
                 hasY:&hasY
                    Y:&gy
         fromKeyposeY:&kpY];
    NSColor *canvasColor = [NSColor colorWithRed:1.0
                                           green:1.0
                                            blue:0.0
                                           alpha:1.0];
    NSColor *keyposeColor = [NSColor accentMatchingHost];
    if (hasX) {
      [(kpX ? keyposeColor : canvasColor) setStroke];
      CGFloat x = CGRectGetMinX(cr) + gx * cr.size.width;
      NSBezierPath *p = [NSBezierPath bezierPath];
      [p setLineWidth:1.0];
      [p moveToPoint:NSMakePoint(x, CGRectGetMinY(cr))];
      [p lineToPoint:NSMakePoint(x, CGRectGetMaxY(cr))];
      [p stroke];
    }
    if (hasY) {
      [(kpY ? keyposeColor : canvasColor) setStroke];
      CGFloat y = CGRectGetMinY(cr) + gy * cr.size.height;
      NSBezierPath *p = [NSBezierPath bezierPath];
      [p setLineWidth:1.0];
      [p moveToPoint:NSMakePoint(CGRectGetMinX(cr), y)];
      [p lineToPoint:NSMakePoint(CGRectGetMaxX(cr), y)];
      [p stroke];
    }
  }
  // The border lines are drawn in the Metal pass (under the handle glyphs);
  // this overlay only adds the size readouts on top. Both the crop and the
  // scale box place their readout trailing-aligned to the box's right edge,
  // just below the bottom edge (same placement as the in-viewer OSCs). Gap is
  // proportional to the 9pt mini label, matching the viewer's 4pt-at-20pt gap.
  // Styling matches the viewer's KKOSCLabel: light-gray (0xC1) fill over a
  // black outline stroke, so the readout reads the same in both surfaces.
  NSDictionary *attrs = [_KKMiniViewerOverlay readoutAttributes];
  const CGFloat kLabelGap = 4.0 * 9.0 / 20.0;

  // Every box OSC (crop, scale, ...) draws its readout the same way: trailing-
  // aligned to the box's right edge, just below the bottom edge.
  if ([d respondsToSelector:@selector(miniViewer:boxesForContentRect:)]) {
    for (KKMiniBox *box in [d miniViewer:c boxesForContentRect:cr]) {
      if (!box.readout.length)
        continue;
      NSSize ts = [box.readout sizeWithAttributes:attrs];
      NSPoint at = NSMakePoint(CGRectGetMaxX(box.rect) - ts.width,
                               CGRectGetMinY(box.rect) - ts.height - kLabelGap);
      [_KKMiniViewerOverlay drawReadout:box.readout
                                atPoint:at
                         fillAttributes:attrs];
    }
  }
}

- (void)mouseDown:(NSEvent *)e {
  KKMiniViewerView *c = self.canvas;
  // A double-click is always "reset view", even when it lands on the crop
  // box / a handle (the overlay's hitTest swallows those clicks, so the
  // canvas's own -mouseDown: never sees them otherwise).
  if (e.clickCount == 2) {
    [self.window makeFirstResponder:nil];
    id<KKMiniViewerDelegate> dd = c.canvasDelegate;
    // A double-click on the toolbar (chrome) is the toolbar's - toggle once,
    // never reset the view's zoom/pan.
    if ([dd respondsToSelector:@selector(miniViewer:toolbarTagAtPoint:)]) {
      NSPoint tp = [self convertPoint:e.locationInWindow fromView:nil];
      if ([dd miniViewer:c toolbarTagAtPoint:tp] != 0) {
        if ([dd respondsToSelector:@selector(miniViewer:toolbarMouseDownAtPoint:)])
          [dd miniViewer:c toolbarMouseDownAtPoint:tp];
        [self setNeedsDisplay:YES];
        return;
      }
    }
    if ([dd respondsToSelector:
                @selector(miniViewer:doubleClickAtPoint:contentRect:)] &&
        [dd miniViewer:c
            doubleClickAtPoint:[self convertPoint:e.locationInWindow
                                         fromView:nil]
                   contentRect:[c contentRectInViewPoints]]) {
      if (c.onDelegateHandledDoubleClick)
        c.onDelegateHandledDoubleClick();
      return;
    }
    [c resetView];
    return;
  }
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  // Toolbar (chrome) first: a body / item press is handled by the toolbar and
  // never touches the gizmo or a layer pick.
  if ([d respondsToSelector:@selector(miniViewer:toolbarTagAtPoint:)]) {
    NSPoint tp = [self convertPoint:e.locationInWindow fromView:nil];
    if ([d miniViewer:c toolbarTagAtPoint:tp] != 0) {
      [self.window makeFirstResponder:nil];
      _toolbarDragging =
          [d respondsToSelector:@selector(miniViewer:toolbarMouseDownAtPoint:)] &&
          [d miniViewer:c toolbarMouseDownAtPoint:tp];
      [self setNeedsDisplay:YES];
      return;
    }
  }
  if (![d respondsToSelector:
              @selector(miniViewer:beginHandleDragAtPoint:contentRect:)])
    return;
  // Interacting with the canvas commits/ends any focused value field so its
  // stale text can't clobber the drag's value on focus loss.
  [self.window makeFirstResponder:nil];
  // Opt-click toggles a handle's visibility (hide / re-show a ghost) instead of
  // dragging it - mirrors the viewer OSC.
  //
  // EXCEPTION: when the master "all OSCs off" is active (handlesHidden), Opt is
  // a transient "peek and use" modifier instead. Opt-hold already reveals every
  // OSC as a ghost (the `_revealActive` OR in the renderer's hit/draw gates),
  // so here we let the Opt-press fall through to a normal drag - the ghost is
  // manipulated live and releasing Opt returns to all-off. Toggling an
  // element's own hidden bit while the master gate is off would have no visible
  // effect anyway, so suppressing the toggle here costs nothing.
  BOOL masterOff = [d isKindOfClass:[KKMiniViewerRenderer class]] &&
                   ((KKMiniViewerRenderer *)d).handlesHidden;
  if (!masterOff && (e.modifierFlags & NSEventModifierFlagOption) &&
      [d respondsToSelector:
              @selector(miniViewer:optClickHandleAtPoint:contentRect:)] &&
      [d miniViewer:c
          optClickHandleAtPoint:[self convertPoint:e.locationInWindow
                                          fromView:nil]
                    contentRect:[c contentRectInViewPoints]]) {
    if (c.onOptHideHandle)
      c.onOptHideHandle(@"");
    return;
  }
  _dragging = YES;
  if (c.onHandleDragBegin)
    c.onHandleDragBegin();
  [d miniViewer:c
      beginHandleDragAtPoint:[self convertPoint:e.locationInWindow fromView:nil]
                 contentRect:[c contentRectInViewPoints]];
}

- (void)mouseDragged:(NSEvent *)e {
  KKMiniViewerView *c = self.canvas;
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  if (_toolbarDragging) {
    if ([d respondsToSelector:@selector(miniViewer:toolbarDraggedToPoint:)])
      [d miniViewer:c
          toolbarDraggedToPoint:[self convertPoint:e.locationInWindow
                                          fromView:nil]];
    [self setNeedsDisplay:YES];
    return;
  }
  if (!_dragging)
    return;
  CGPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  CGRect cr = [c contentRectInViewPoints];
  if ([d respondsToSelector:
              @selector(miniViewer:dragHandleToPoint:contentRect:modifiers:)]) {
    [d miniViewer:c
        dragHandleToPoint:p
              contentRect:cr
                modifiers:e.modifierFlags];
  } else {
    [d miniViewer:c dragHandleToPoint:p contentRect:cr];
  }
  [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)e {
  KKMiniViewerView *c = self.canvas;
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  if (_toolbarDragging) {
    _toolbarDragging = NO;
    if ([d respondsToSelector:@selector(miniViewerToolbarMouseUp:)])
      [d miniViewerToolbarMouseUp:c];
    [self setNeedsDisplay:YES];
    return;
  }
  if (!_dragging)
    return;
  _dragging = NO;
  if ([d respondsToSelector:@selector(miniViewerEndHandleDrag:)])
    [d miniViewerEndHandleDrag:c];
  if (c.onHandleDragEnd)
    c.onHandleDragEnd();
  [self setNeedsDisplay:YES];
}

// Opt-hold over the mini-viewer reveals hidden handles/rings as ghosts. A
// tracking area feeds us mouseMoved/Exited regardless of which subview the
// pointer is over; we mirror the Option state onto the renderer.
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_optTrackingArea)
    [self removeTrackingArea:_optTrackingArea];
  _optTrackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                   NSTrackingActiveInActiveApp
             owner:self
          userInfo:nil];
  [self addTrackingArea:_optTrackingArea];
}

- (void)_setOptReveal:(BOOL)reveal {
  if (reveal == _optReveal)
    return;
  _optReveal = reveal;
  KKMiniViewerView *c = self.canvas;
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  if ([d isKindOfClass:[KKMiniViewerRenderer class]]) {
    ((KKMiniViewerRenderer *)d).revealHidden = reveal;
    // Handles/rings are the Metal pass, so we must invalidate the MTKView
    // itself - setHandlesNeedDisplay only redraws the CG overlay.
    [c setNeedsDisplay:YES];
  }
}

// Mirror the viewer's resize/move cursors over the mini-canvas handles. The
// delegate returns the cursor for the hovered point (or nil for the arrow);
// during a drag mouseMoved doesn't fire, so the cursor set on the last hover
// persists through the drag, then a fresh move re-evaluates it.
- (void)_updateHoverCursorAtWindowPoint:(NSPoint)windowPoint {
  KKMiniViewerView *c = self.canvas;
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  NSCursor *cursor = nil;
  if ([d respondsToSelector:@selector(miniViewer:cursorAtPoint:contentRect:)]) {
    NSPoint p = [self convertPoint:windowPoint fromView:nil];
    cursor = [d miniViewer:c
             cursorAtPoint:p
               contentRect:[c contentRectInViewPoints]];
  }
  [(cursor ?: [NSCursor arrowCursor]) set];
}

- (void)mouseMoved:(NSEvent *)e {
  [self _setOptReveal:(e.modifierFlags & NSEventModifierFlagOption) != 0];
  KKMiniViewerView *c = self.canvas;
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  if ([d respondsToSelector:@selector(miniViewer:toolbarHoverTag:)] &&
      [d respondsToSelector:@selector(miniViewer:toolbarTagAtPoint:)]) {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger tag = [d miniViewer:c toolbarTagAtPoint:p];
    [d miniViewer:c toolbarHoverTag:tag];
    if (tag != 0) {
      // Over the toolbar: it owns the cursor (move over the handle, arrow
      // elsewhere); skip the handle-resize cursor logic below.
      NSCursor *cur = nil;
      if ([d respondsToSelector:@selector(miniViewer:toolbarCursorForTag:)])
        cur = [d miniViewer:c toolbarCursorForTag:tag];
      [(cur ?: [NSCursor arrowCursor]) set];
      return;
    }
  }
  [self _updateHoverCursorAtWindowPoint:e.locationInWindow];
}

- (void)flagsChanged:(NSEvent *)e {
  [self _setOptReveal:(e.modifierFlags & NSEventModifierFlagOption) != 0];
}

- (void)mouseExited:(NSEvent *)e {
  [self _setOptReveal:NO];
  KKMiniViewerView *c = self.canvas;
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  if ([d respondsToSelector:@selector(miniViewer:toolbarHoverTag:)])
    [d miniViewer:c toolbarHoverTag:0];
  [[NSCursor arrowCursor] set];
}

@end
