/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniCanvasRenderer.h"
#import "KKMiniCanvasView_Private.h"
#import "NSColor+KKColors.h"

@implementation _KKMiniCanvasOverlay {
  BOOL _dragging;
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
  KKMiniCanvasView *c = self.canvas;
  id<KKMiniCanvasDelegate> d = c.canvasDelegate;
  if (![d respondsToSelector:@selector(
                                 miniCanvas:handleHitAtPoint:contentRect:)])
    return nil;
  NSPoint p = [self convertPoint:pt fromView:self.superview];
  return [d miniCanvas:c
             handleHitAtPoint:p
                  contentRect:[c contentRectInViewPoints]]
             ? self
             : nil;
}

// Handles are drawn by the canvas's Metal pass (shared KKPointOSC shader).
// The crop border is a thin stroke and is cheaper/sharper drawn here in
// Core Graphics than via a Metal line pipeline.
- (void)drawRect:(NSRect)dirtyRect {
  KKMiniCanvasView *c = self.canvas;
  id<KKMiniCanvasDelegate> d = c.canvasDelegate;
  CGRect cr = [c contentRectInViewPoints];
  if (_dragging &&
      [d respondsToSelector:@selector(miniCanvas:snapGuideHasX:X:fromKeyposeX:
                                      hasY:Y:fromKeyposeY:)]) {
    BOOL hasX = NO, hasY = NO, kpX = NO, kpY = NO;
    CGFloat gx = 0, gy = 0;
    [d miniCanvas:c
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
  NSDictionary *attrs = [_KKMiniCanvasOverlay readoutAttributes];
  const CGFloat kLabelGap = 4.0 * 9.0 / 20.0;

  // Every box OSC (crop, scale, ...) draws its readout the same way: trailing-
  // aligned to the box's right edge, just below the bottom edge.
  if ([d respondsToSelector:@selector(miniCanvas:boxesForContentRect:)]) {
    for (KKMiniBox *box in [d miniCanvas:c boxesForContentRect:cr]) {
      if (!box.readout.length)
        continue;
      NSSize ts = [box.readout sizeWithAttributes:attrs];
      NSPoint at = NSMakePoint(CGRectGetMaxX(box.rect) - ts.width,
                               CGRectGetMinY(box.rect) - ts.height - kLabelGap);
      [_KKMiniCanvasOverlay drawReadout:box.readout
                                atPoint:at
                         fillAttributes:attrs];
    }
  }
}

- (void)mouseDown:(NSEvent *)e {
  KKMiniCanvasView *c = self.canvas;
  // A double-click is always "reset view", even when it lands on the crop
  // box / a handle (the overlay's hitTest swallows those clicks, so the
  // canvas's own -mouseDown: never sees them otherwise).
  if (e.clickCount == 2) {
    [self.window makeFirstResponder:nil];
    id<KKMiniCanvasDelegate> dd = c.canvasDelegate;
    if ([dd respondsToSelector:
                @selector(miniCanvas:doubleClickAtPoint:contentRect:)] &&
        [dd miniCanvas:c
            doubleClickAtPoint:[self convertPoint:e.locationInWindow
                                         fromView:nil]
                   contentRect:[c contentRectInViewPoints]]) {
      return;
    }
    [c resetView];
    return;
  }
  id<KKMiniCanvasDelegate> d = c.canvasDelegate;
  if (![d respondsToSelector:
              @selector(miniCanvas:beginHandleDragAtPoint:contentRect:)])
    return;
  // Interacting with the canvas commits/ends any focused value field so its
  // stale text can't clobber the drag's value on focus loss.
  [self.window makeFirstResponder:nil];
  // Opt-click toggles a handle's visibility (hide / re-show a ghost) instead of
  // dragging it - mirrors the viewer OSC.
  if ((e.modifierFlags & NSEventModifierFlagOption) &&
      [d respondsToSelector:
              @selector(miniCanvas:optClickHandleAtPoint:contentRect:)] &&
      [d miniCanvas:c
          optClickHandleAtPoint:[self convertPoint:e.locationInWindow
                                          fromView:nil]
                    contentRect:[c contentRectInViewPoints]]) {
    return;
  }
  _dragging = YES;
  if (c.onHandleDragBegin)
    c.onHandleDragBegin();
  [d miniCanvas:c
      beginHandleDragAtPoint:[self convertPoint:e.locationInWindow fromView:nil]
                 contentRect:[c contentRectInViewPoints]];
}

- (void)mouseDragged:(NSEvent *)e {
  if (!_dragging)
    return;
  KKMiniCanvasView *c = self.canvas;
  id<KKMiniCanvasDelegate> d = c.canvasDelegate;
  CGPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  CGRect cr = [c contentRectInViewPoints];
  if ([d respondsToSelector:
              @selector(miniCanvas:dragHandleToPoint:contentRect:modifiers:)]) {
    [d miniCanvas:c
        dragHandleToPoint:p
              contentRect:cr
                modifiers:e.modifierFlags];
  } else {
    [d miniCanvas:c dragHandleToPoint:p contentRect:cr];
  }
  [self setNeedsDisplay:YES];
}

- (void)mouseUp:(NSEvent *)e {
  if (!_dragging)
    return;
  _dragging = NO;
  KKMiniCanvasView *c = self.canvas;
  id<KKMiniCanvasDelegate> d = c.canvasDelegate;
  if ([d respondsToSelector:@selector(miniCanvasEndHandleDrag:)])
    [d miniCanvasEndHandleDrag:c];
  if (c.onHandleDragEnd)
    c.onHandleDragEnd();
  [self setNeedsDisplay:YES];
}

// Opt-hold over the mini-canvas reveals hidden handles/rings as ghosts. A
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
  KKMiniCanvasView *c = self.canvas;
  id<KKMiniCanvasDelegate> d = c.canvasDelegate;
  if ([d isKindOfClass:[KKMiniCanvasRenderer class]]) {
    ((KKMiniCanvasRenderer *)d).revealHidden = reveal;
    // Handles/rings are the Metal pass, so we must invalidate the MTKView
    // itself - setHandlesNeedDisplay only redraws the CG overlay.
    [c setNeedsDisplay:YES];
  }
}

- (void)mouseMoved:(NSEvent *)e {
  [self _setOptReveal:(e.modifierFlags & NSEventModifierFlagOption) != 0];
}

- (void)flagsChanged:(NSEvent *)e {
  [self _setOptReveal:(e.modifierFlags & NSEventModifierFlagOption) != 0];
}

- (void)mouseExited:(NSEvent *)e {
  [self _setOptReveal:NO];
}

@end
