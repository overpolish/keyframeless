/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageSurfaceCircleView_Internal.h"

// The cursor in this view's coordinates, taken from the CGEvent rather than the
// NSEvent's window-relative location, for the same reason the panel's own drag
// does: inside a plugin's ViewBridge the drag stream is addressed to other
// windows, so it arrives through monitors where `locationInWindow` means nothing
// to this view. Global display space is unambiguous.
NSPoint MirageSurfaceCursorInView(NSEvent *event, NSView *view) {
  NSPoint screen;
  CGEventRef cg = event.CGEvent;
  if (cg) {
    CGPoint global = CGEventGetLocation(cg);
    NSScreen *primary = NSScreen.screens.firstObject;
    screen = NSMakePoint(global.x, NSMaxY(primary.frame) - global.y);
  } else if (event.window) {
    screen = [event.window convertPointToScreen:event.locationInWindow];
  } else {
    screen = event.locationInWindow;
  }
  NSPoint inWindow = [view.window convertPointFromScreen:screen];
  return [view convertPoint:inWindow fromView:nil];
}

@implementation MirageSurfaceCircleView (Interaction)

/// The puck a press at `down` (in -1..1 space) means, and whether it was grabbed ON
/// rather than pointed at. The NEAREST puck within reach wins, so overlapping
/// handles stay separable; a press in open space belongs to the active puck, which
/// is what makes a multi-puck circle still feel like a single-puck one.
- (NSUInteger)_puckIndexForPress:(NSPoint)down grabbed:(BOOL *)outGrabbed {
  if (outGrabbed)
    *outGrabbed = NO;
  double grabRadius = (kPuckRadius * 2.0) /
                      MAX(1.0, [self _circleRect].size.width / 2.0 -
                                   kRingThickness - kPuckRadius);
  NSUInteger best = self.activePuck < self.pucks.count ? self.activePuck : 0;
  double bestDistance = grabRadius;
  BOOL found = NO;
  for (NSUInteger i = 0; i < self.pucks.count; i++) {
    NSPoint at = [self _drawnPositionForPuck:self.pucks[i] pinned:NULL];
    double d = hypot(down.x - at.x, down.y - at.y);
    if (d <= bestDistance) {
      bestDistance = d;
      best = i;
      found = YES;
    }
  }
  if (outGrabbed)
    *outGrabbed = found;
  return best;
}

- (void)mouseDown:(NSEvent *)event {
  if (!self.xAxisLive && !self.yAxisLive)
    return; // nothing to drag: no control responds to either direction
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  NSRect circle = [self _circleRect];
  if (hypot(p.x - NSMidX(circle), p.y - NSMidY(circle)) >
      circle.size.width / 2.0)
    return;
  NSPoint down = [self _normalisedFromViewPoint:p];
  BOOL grabbed = NO;
  NSUInteger index = [self _puckIndexForPress:down grabbed:&grabbed];
  // Double-click recentres. Checked before starting a drag so the second click
  // cannot also nudge the puck a pixel on its way to resetting it.
  if (event.clickCount >= 2) {
    self.pucks[index].position = NSZeroPoint;
    self.activePuck = index;
    [self setNeedsDisplay:YES];
    if (self.onResetToCentre)
      self.onResetToCentre(index);
    return;
  }
  _dragging = YES;
  _dragIndex = index;
  self.activePuck = index;
  NSPoint here = [self _drawnPositionForPuck:self.pucks[index] pinned:NULL];
  // Grabbing ON the puck drags it relative, so it stays under the finger. Clicking
  // away from it moves it there, which is what a click in open space means.
  _grabBearing = 0.0;
  _grabOffset = NSZeroPoint;
  if (grabbed) {
    if (self.pucks[index].trackRadius > 0.0)
      _grabBearing = atan2(down.y, down.x) - atan2(here.y, here.x);
    else
      _grabOffset = NSMakePoint(down.x - here.x, down.y - here.y);
  }
  [self _installDragMonitors];
  if (self.onDragBegan)
    self.onDragBegan(index);
}

- (void)_dragTickWithEvent:(NSEvent *)event {
  if (!_dragging)
    return;
  NSPoint cursor =
      [self _normalisedFromViewPoint:MirageSurfaceCursorInView(event, self)];
  // Target position, then clamp to the disc so the reported offset matches what is
  // drawn even at the rim: otherwise the controls would keep moving after the puck
  // visually stopped.
  if (_dragIndex >= self.pucks.count)
    return;
  double track = self.pucks[_dragIndex].trackRadius;
  double tx, ty;
  if (track > 0.0) {
    // Only the bearing survives the drag. The cursor's distance is discarded rather
    // than clamped, so the handle keeps turning with the pointer even when it
    // wanders far outside the circle - which is how a rotation should behave.
    double bearing = atan2(cursor.y, cursor.x) - _grabBearing;
    tx = cos(bearing) * track;
    ty = sin(bearing) * track;
  } else {
    tx = self.xAxisLive ? cursor.x - _grabOffset.x : 0.0;
    ty = self.yAxisLive ? cursor.y - _grabOffset.y : 0.0;
    double len = hypot(tx, ty);
    if (len > 1.0) {
      tx /= len;
      ty /= len;
    }
  }
  self.pucks[_dragIndex].position = NSMakePoint(tx, ty);
  [self setNeedsDisplay:YES];
  if (self.onPuckMovedTo)
    self.onPuckMovedTo(_dragIndex, NSMakePoint(tx, ty));
}

- (void)_endDrag {
  if (!_dragging)
    return;
  _dragging = NO;
  [self _removeDragMonitors];
  if (self.onDragEnded)
    self.onDragEnded(_dragIndex);
}

- (void)cancelDrag {
  if (!_dragging)
    return;
  _dragging = NO;
  [self _removeDragMonitors];
}

- (void)_installDragMonitors {
  __weak MirageSurfaceCircleView *weak = self;
  NSEventMask mask = NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp;
  if (!_dragGlobalMonitor)
    _dragGlobalMonitor = [NSEvent
        addGlobalMonitorForEventsMatchingMask:mask
                                      handler:^(NSEvent *e) {
                                        if (e.type == NSEventTypeLeftMouseUp)
                                          [weak _endDrag];
                                        else
                                          [weak _dragTickWithEvent:e];
                                      }];
  if (!_dragLocalMonitor)
    _dragLocalMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:mask
                                     handler:^NSEvent *(NSEvent *e) {
                                       __strong MirageSurfaceCircleView *s = weak;
                                       if (!s)
                                         return e;
                                       if (e.type == NSEventTypeLeftMouseUp)
                                         [s _endDrag];
                                       else
                                         [s _dragTickWithEvent:e];
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

@end
