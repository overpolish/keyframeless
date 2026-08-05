/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLog.h"
#import "KKMiniViewerRenderer.h"
#import "KKMiniViewerView_Private.h"
#import "KKViewHelpers.h" // KKTrackingAreaMatches
#import "NSColor+KKColors.h"

@implementation _KKMiniViewerOverlay {
  BOOL _dragging;
  BOOL _toolbarDragging;
  BOOL _toolDrawing;
  // The compare divider drag. Deliberately NOT routed through `_dragging`: that
  // path opens the host's undo group around the delegate's value writes, and
  // the divider writes no value at all - it is view state.
  BOOL _compareDragging;
  NSTrackingArea *_optTrackingArea;
  BOOL _optReveal;
  // Live only while _dragging: catch the drag ticks and the mouseUp when they
  // land in a DIFFERENT window from the press (a keypose popover opened over
  // the constants popover - both nonactivating). Without this the drag latches
  // with no further ticks and no end, which also leaves the plugin's undo group
  // open and aborts FCP's next undo.
  id _dragGlobalMonitor;
  id _dragLocalMonitor;
}

- (BOOL)isFlipped {
  return NO;
}

// Act on the FIRST click even when the popover window isn't key yet (same
// reason KKMiniViewerView does). This overlay sits on top and receives the
// toolbar / OSC-handle presses, so without this a click coming in from the
// layer list - which has stolen first responder, leaving the nonactivating
// popover non-key - is swallowed just to make the window key, needing a second
// click to actually trigger the path-op button or grab a handle.
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
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
  // Live playback draws NO on-screen controls (-drawRect: here and the whole
  // overlay span in -drawInMTKView:), so nothing this overlay owns may be
  // grabbed either - otherwise the pointer catches handles, the toolbar and the
  // compare divider that are not on screen. This is the ONE place a pointer
  // resolves to a mini control, so declining the point here disables every
  // set's hit-test at once. Falling through to the canvas keeps the surface
  // behaving like empty preview: click-drag pan, scroll/pinch zoom,
  // double-click reset and the background pick all live on KKMiniViewerView.
  if (c.livePlaybackActive)
    return nil;
  // The toolbar (chrome) sits on top: claim its hits before the handles so the
  // click doesn't fall through to a layer drag / pan.
  if ([d respondsToSelector:@selector(miniViewer:toolbarTagAtPoint:)] &&
      [d miniViewer:c toolbarTagAtPoint:p] != 0)
    return self;
  // A drawing tool (pen) claims the whole canvas, so a click places a point
  // instead of click-drag panning the view. Two-finger / scroll pan still works
  // (scrollWheel bubbles to the canvas regardless of this hit-test).
  if ([d respondsToSelector:@selector(miniViewerToolDrawingActive:)] &&
      [d miniViewerToolDrawingActive:c])
    return self;
  // The compare divider is grabbable, but it only ever wins where no parameter
  // handle wants the point (the tie-break below and in mouseDown).
  BOOL onDivider = [c _compareDividerGrabbableAtPoint:p];
  if (![d respondsToSelector:@selector(
                                 miniViewer:handleHitAtPoint:contentRect:)])
    return onDivider ? self : nil;
  // While a pan/zoom gesture is live, skip the per-anchor handle hit-test - a
  // two-finger scroll / pinch never targets a handle, and on a dense path this
  // call costs ~35ms, which AppKit invokes once per scroll event and was the
  // real throttle that dropped panning to ~24fps. Let the point fall through to
  // the canvas (which drives the pan) for the duration of the gesture.
  if ([c _isPanZoomGestureActive])
    return nil;
  if ([d miniViewer:c
          handleHitAtPoint:p
               contentRect:[c contentRectInViewPoints]])
    return self;
  return onDivider ? self : nil;
}

// Handles are drawn by the canvas's Metal pass (shared KKPointOSC shader).
// The crop border is a thin stroke and is cheaper/sharper drawn here in
// Core Graphics than via a Metal line pipeline.
- (void)drawRect:(NSRect)dirtyRect {
  KKMiniViewerView *c = self.canvas;
  // Live playback suppresses every on-screen control for a clean frame; this
  // AppKit overlay draws the box size readouts (and drag snap guides) on top of
  // the Metal pass, so it has to honour the same gate - the Metal overlay is
  // already skipped in -drawInMTKView:.
  if (c.livePlaybackActive)
    return;
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
  // The drawing tool's overlay is drawn in the Metal pass (matching the motion
  // path's glyph/line look), not here.
}

- (void)mouseDown:(NSEvent *)e {
  KKMiniViewerView *c = self.canvas;
  // A press means any earlier divider drag is over, even if its mouseUp was
  // lost to another window (the cross-popover case the handle drag installs
  // monitors for). Nothing is left open by a dropped divider drag, so clearing
  // the flag is the whole recovery.
  _compareDragging = NO;
  // Free-drawing tool (pen): route every press here (the delegate's controller
  // does its own double-click detection). The toolbar (chrome) still wins; no
  // handle-drag / auto-select / reset-view path runs.
  {
    id<KKMiniViewerDelegate> td = c.canvasDelegate;
    if ([td respondsToSelector:@selector(miniViewerToolDrawingActive:)] &&
        [td miniViewerToolDrawingActive:c]) {
      NSPoint tp = [self convertPoint:e.locationInWindow fromView:nil];
      if ([td respondsToSelector:@selector(miniViewer:toolbarTagAtPoint:)] &&
          [td miniViewer:c toolbarTagAtPoint:tp] != 0) {
        [c endFieldEditingGrabbingFocusIfNeeded];
        _toolbarDragging =
            [td respondsToSelector:@selector(
                                       miniViewer:toolbarMouseDownAtPoint:)] &&
            [td miniViewer:c toolbarMouseDownAtPoint:tp];
        [self setNeedsDisplay:YES];
        return;
      }
      [c endFieldEditingGrabbingFocusIfNeeded];
      _toolDrawing = YES;
      if ([td respondsToSelector:
                  @selector(miniViewer:toolDownAtPoint:contentRect:modifiers:)])
        [td miniViewer:c
            toolDownAtPoint:tp
                contentRect:[c contentRectInViewPoints]
                  modifiers:e.modifierFlags];
      [c setNeedsDisplay:YES]; // tool overlay draws in the Metal pass
      return;
    }
  }
  // A double-click is always "reset view", even when it lands on the crop
  // box / a handle (the overlay's hitTest swallows those clicks, so the
  // canvas's own -mouseDown: never sees them otherwise).
  if (e.clickCount == 2) {
    [c endFieldEditingGrabbingFocusIfNeeded];
    id<KKMiniViewerDelegate> dd = c.canvasDelegate;
    // A double-click on the toolbar (chrome) is the toolbar's - toggle once,
    // never reset the view's zoom/pan.
    if ([dd respondsToSelector:@selector(miniViewer:toolbarTagAtPoint:)]) {
      NSPoint tp = [self convertPoint:e.locationInWindow fromView:nil];
      if ([dd miniViewer:c toolbarTagAtPoint:tp] != 0) {
        if ([dd respondsToSelector:@selector(
                                       miniViewer:toolbarMouseDownAtPoint:)])
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
      [c endFieldEditingGrabbingFocusIfNeeded];
      _toolbarDragging =
          [d respondsToSelector:@selector(
                                    miniViewer:toolbarMouseDownAtPoint:)] &&
          [d miniViewer:c toolbarMouseDownAtPoint:tp];
      [self setNeedsDisplay:YES];
      return;
    }
  }
  // Compare divider. Checked AFTER asking the delegate whether it wants the
  // same point, so the divider loses every tie: with a narrow grab band and the
  // delegate given first refusal, a point OSC parked at frame centre stays
  // grabbable with the split on - the same nearest-within-reach arbitration the
  // colour pucks use, with the divider's reach deliberately the smaller one.
  //
  // Outside the onHandleDragBegin/End pair on purpose: the divider is session
  // view state, so it must not open an undo group or write a parameter.
  {
    NSPoint dp = [self convertPoint:e.locationInWindow fromView:nil];
    BOOL delegateWants =
        [d respondsToSelector:@selector(
                                  miniViewer:handleHitAtPoint:contentRect:)] &&
        [d miniViewer:c
            handleHitAtPoint:dp
                 contentRect:[c contentRectInViewPoints]];
    if (!delegateWants && [c _compareDividerGrabbableAtPoint:dp]) {
      [c endFieldEditingGrabbingFocusIfNeeded];
      [self.window makeKeyWindow];
      _compareDragging = YES;
      // The SAME monitors a handle drag installs. Inside a popover this
      // overlay's -mouseDragged: is not reliably delivered, so without them the
      // press positioned the divider once and every subsequent movement was
      // dropped - it looked like the line jumped a pixel and then refused to
      // move however far you dragged.
      [self _installDragMonitors];
      [c _dragCompareDividerToPoint:dp];
      return;
    }
  }
  if (![d respondsToSelector:
              @selector(miniViewer:beginHandleDragAtPoint:contentRect:)])
    return;
  // Interacting with the canvas commits/ends any focused value field so its
  // stale text can't clobber the drag's value on focus loss.
  [c endFieldEditingGrabbingFocusIfNeeded];
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
  // A press while a drag is still active means the prior mouseUp was lost - a
  // keypose popover open over the constants popover splits the down/up between
  // two nonactivating windows, so this overlay sees repeated mouseDowns and no
  // mouseUp. End the stale drag first so onHandleDragBegin/End stay balanced;
  // an unbalanced begin leaks the plugin's drag undo group and aborts FCP.
  if (_dragging)
    [self _endActiveHandleDragReason:@"lost mouseUp - new mouseDown"];
  // A reused popover window can come back NON-KEY after a close+reopen (the
  // boundary popover reopens into the recycled ViewBridge window). A
  // synthesized mousedown still lands here, but the natural drag session
  // (mouseDragged / mouseUp) is only tracked for the key window - so without
  // this the OSC drag freezes after a keypose switch. It's a nonactivating
  // panel, so keying it doesn't steal FCP's foreground (same makeKeyWindow the
  // popovers already use for keyboard).
  [self.window makeKeyWindow];
  _dragging = YES;
  [self _installDragMonitors];
  if (c.onHandleDragBegin)
    c.onHandleDragBegin();
  [d miniViewer:c
      beginHandleDragAtPoint:[self convertPoint:e.locationInWindow fromView:nil]
                 contentRect:[c contentRectInViewPoints]];
}

- (void)mouseDragged:(NSEvent *)e {
  KKMiniViewerView *c = self.canvas;
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  if (_toolDrawing) {
    if ([d respondsToSelector:@selector(miniViewer:toolDraggedToPoint:
                                        contentRect:modifiers:)])
      [d miniViewer:c
          toolDraggedToPoint:[self convertPoint:e.locationInWindow fromView:nil]
                 contentRect:[c contentRectInViewPoints]
                   modifiers:e.modifierFlags];
    [c setNeedsDisplay:YES];
    return;
  }
  if (_toolbarDragging) {
    if ([d respondsToSelector:@selector(miniViewer:toolbarDraggedToPoint:)])
      [d miniViewer:c
          toolbarDraggedToPoint:[self convertPoint:e.locationInWindow
                                          fromView:nil]];
    [self setNeedsDisplay:YES];
    return;
  }
  if (_compareDragging) {
    [c _dragCompareDividerToPoint:[self convertPoint:e.locationInWindow
                                            fromView:nil]];
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
  if (_toolDrawing) {
    _toolDrawing = NO;
    if ([d respondsToSelector:@selector(miniViewer:toolUpAtPoint:contentRect:)])
      [d miniViewer:c
          toolUpAtPoint:[self convertPoint:e.locationInWindow fromView:nil]
            contentRect:[c contentRectInViewPoints]];
    [c setNeedsDisplay:YES];
    return;
  }
  if (_toolbarDragging) {
    _toolbarDragging = NO;
    if ([d respondsToSelector:@selector(miniViewerToolbarMouseUp:)])
      [d miniViewerToolbarMouseUp:c];
    [self setNeedsDisplay:YES];
    return;
  }
  if (_compareDragging) {
    _compareDragging = NO;
    [self _removeDragMonitors];
    return;
  }
  [self _endActiveHandleDragReason:@"mouseUp"];
}

// End an in-progress handle drag exactly once, firing the same end path mouseUp
// would. Called from mouseUp, from a new mouseDown that arrives while still
// dragging (lost mouseUp), and from teardown - so onHandleDragBegin always has
// a matching onHandleDragEnd and the plugin's drag undo group never leaks.
- (void)_endActiveHandleDragReason:(NSString *)reason {
  [self _removeDragMonitors];
  if (!_dragging)
    return;
  _dragging = NO;
  KKMiniViewerView *c = self.canvas;
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  if ([d respondsToSelector:@selector(miniViewerEndHandleDrag:)])
    [d miniViewerEndHandleDrag:c];
  if (c.onHandleDragEnd)
    c.onHandleDragEnd();
  [self setNeedsDisplay:YES];
}

// Space pressed mid-drag. The drag is FINISHED where it stands rather than
// reverted: the handle has been writing its value live the whole time, so the
// user has already seen (and heard the render of) the value they are on, and
// there is no restore-original path in this surface to revert to. Finishing
// keeps onHandleDragBegin/End balanced - the same reason -mouseDown: ends a
// stale drag - so the plugin's undo group closes and the move lands as ONE undo
// entry. The alternative, letting the drag continue against invisible handles,
// is exactly the bug this gate exists to stop.
- (void)endInteractionForLivePlayback {
  if (_compareDragging) {
    _compareDragging = NO;
    [self _removeDragMonitors];
  }
  KKMiniViewerView *c = self.canvas;
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  if (_toolDrawing) {
    _toolDrawing = NO;
    if (self.window &&
        [d respondsToSelector:@selector(miniViewer:toolUpAtPoint:contentRect:)])
      [d miniViewer:c
          toolUpAtPoint:[self
                            convertPoint:[self.window convertPointFromScreen:
                                                          NSEvent.mouseLocation]
                                fromView:nil]
            contentRect:[c contentRectInViewPoints]];
  }
  if (_toolbarDragging) {
    _toolbarDragging = NO;
    if ([d respondsToSelector:@selector(miniViewerToolbarMouseUp:)])
      [d miniViewerToolbarMouseUp:c];
  }
  [self _setOptReveal:NO];
  [self _endActiveHandleDragReason:@"live playback started"];
}

// Feed a drag tick from a SCREEN-space location: a monitored event belongs to
// another window (or to no window at all), so its locationInWindow can't be
// converted against this overlay directly.
- (void)_dragTickAtScreenPoint:(NSPoint)screenPoint
                     modifiers:(NSEventModifierFlags)mods {
  if (!self.window)
    return;
  KKMiniViewerView *c = self.canvas;
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  CGPoint p =
      [self convertPoint:[self.window convertPointFromScreen:screenPoint]
                fromView:nil];
  // The divider shares the monitors but not the handle-drag path: it talks to
  // the view directly and opens no undo group, so it is answered here and the
  // delegate never hears about it.
  if (_compareDragging) {
    [c _dragCompareDividerToPoint:p];
    [self setNeedsDisplay:YES];
    return;
  }
  if (!_dragging)
    return;
  CGRect cr = [c contentRectInViewPoints];
  if ([d respondsToSelector:
              @selector(miniViewer:dragHandleToPoint:contentRect:modifiers:)])
    [d miniViewer:c dragHandleToPoint:p contentRect:cr modifiers:mods];
  else
    [d miniViewer:c dragHandleToPoint:p contentRect:cr];
  [self setNeedsDisplay:YES];
}

// Watch drag/up for the duration of a drag whose events may not come back to
// this overlay. The local monitor ignores anything in THIS window - natural
// delivery already handles that and a second tick would double-apply the move.
- (void)_installDragMonitors {
  __weak _KKMiniViewerOverlay *weak = self;
  NSEventMask mask = NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged;
  if (!_dragGlobalMonitor)
    _dragGlobalMonitor = [NSEvent
        addGlobalMonitorForEventsMatchingMask:mask
                                      handler:^(NSEvent *e) {
                                        // A global event has no window: its
                                        // location is already screen space.
                                        if (e.type == NSEventTypeLeftMouseUp)
                                          [weak _endActiveHandleDragReason:
                                                    @"mouseUp outside the app"];
                                        else
                                          [weak
                                              _dragTickAtScreenPoint:
                                                  e.locationInWindow
                                                           modifiers:
                                                               e.modifierFlags];
                                      }];
  if (!_dragLocalMonitor)
    _dragLocalMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:mask
                                     handler:^NSEvent *(NSEvent *e) {
                                       __strong _KKMiniViewerOverlay *s = weak;
                                       if (!s || e.window == s.window)
                                         return e;
                                       if (e.type == NSEventTypeLeftMouseUp) {
                                         [s _endActiveHandleDragReason:
                                                 @"mouseUp in another window"];
                                         return e;
                                       }
                                       NSPoint sp =
                                           e.window
                                               ? [e.window
                                                     convertPointToScreen:
                                                         e.locationInWindow]
                                               : e.locationInWindow;
                                       [s _dragTickAtScreenPoint:sp
                                                       modifiers:
                                                           e.modifierFlags];
                                       return e;
                                     }];
}

- (void)_removeDragMonitors {
  if (_dragGlobalMonitor) {
    [NSEvent removeMonitor:_dragGlobalMonitor];
    _dragGlobalMonitor = nil;
  }
  if (_dragLocalMonitor) {
    [NSEvent removeMonitor:_dragLocalMonitor];
    _dragLocalMonitor = nil;
  }
}

// If this overlay is pulled from its window (popover dismissed or mini-viewer
// rebuilt) while a handle drag is live, its mouseUp never arrives. End the drag
// here so onHandleDragEnd fires and the plugin's undo group closes - a dropped
// end leaks the group and aborts FCP's next undo ("Adjust <effect>" crash).
- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
  [super viewWillMoveToWindow:newWindow];
  if (_dragging && !newWindow)
    [self _endActiveHandleDragReason:@"torn down (window->nil)"];
}

- (void)dealloc {
  [self _removeDragMonitors];
  if (_dragging)
    KKLogWarn(@"[dragundo] overlay=%p dealloc'd mid-drag - onHandleDragEnd "
              @"was DROPPED",
              self);
}

// Opt-hold over the mini-viewer reveals hidden handles/rings as ghosts. A
// tracking area feeds us mouseMoved/Exited regardless of which subview the
// pointer is over; we mirror the Option state onto the renderer.
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (KKTrackingAreaMatches(_optTrackingArea, self.bounds))
    return; // see KKTrackingAreaMatches: rebuilding every cycle never settles
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
  // Only where the delegate wants nothing: the divider loses the cursor for the
  // same reason it loses the press.
  if (!cursor &&
      [c _compareDividerGrabbableAtPoint:[self convertPoint:windowPoint
                                                   fromView:nil]])
    cursor = [NSCursor resizeLeftRightCursor];
  [(cursor ?: [NSCursor arrowCursor]) set];
}

- (void)mouseMoved:(NSEvent *)e {
  KKMiniViewerView *c = self.canvas;
  // Tracking-area moves are delivered to the owner whether or not -hitTest:
  // claimed the point, so the playback gate is repeated here: no resize/move
  // cursor over an invisible handle, and no Opt-peek reveal of hidden ones.
  if (c.livePlaybackActive) {
    [self _setOptReveal:NO];
    [[NSCursor arrowCursor] set];
    return;
  }
  [self _setOptReveal:(e.modifierFlags & NSEventModifierFlagOption) != 0];
  id<KKMiniViewerDelegate> d = c.canvasDelegate;
  // Drawing tool active: feed the cursor (rubber-band + snap ghost) + redraw,
  // but still let the toolbar own the cursor when hovering it (below).
  if ([d respondsToSelector:@selector(miniViewerToolDrawingActive:)] &&
      [d miniViewerToolDrawingActive:c]) {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    BOOL overToolbar =
        [d respondsToSelector:@selector(miniViewer:toolbarTagAtPoint:)] &&
        [d miniViewer:c toolbarTagAtPoint:p] != 0;
    if (!overToolbar) {
      CGRect cr = [c contentRectInViewPoints];
      if ([d respondsToSelector:
                  @selector(miniViewer:toolMovedToPoint:contentRect:)]) {
        [d miniViewer:c toolMovedToPoint:p contentRect:cr];
        [c setNeedsDisplay:YES];
      }
      // The tool owns the cursor (pen / close glyph) over the canvas; skip the
      // handle-resize hover logic below.
      NSCursor *cur = nil;
      if ([d respondsToSelector:@selector(
                                    miniViewer:toolCursorAtPoint:contentRect:)])
        cur = [d miniViewer:c toolCursorAtPoint:p contentRect:cr];
      [(cur ?: [NSCursor arrowCursor]) set];
      return;
    }
  }
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
  [self _setOptReveal:self.canvas.livePlaybackActive
                          ? NO
                          : (e.modifierFlags & NSEventModifierFlagOption) != 0];
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
