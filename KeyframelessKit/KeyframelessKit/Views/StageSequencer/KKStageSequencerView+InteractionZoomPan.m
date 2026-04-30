/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKStageSequencerView (InteractionZoomPan)

- (void)magnifyWithEvent:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:NSWidth(self.bounds)
                        trackX:&trackX
                    trackWidth:&trackWidth];

  double fracUnderCursor = [self _fracForX:loc.x
                                    trackX:trackX
                                trackWidth:trackWidth];

  _zoom = MAX(1.0, MIN(20.0, _zoom * (1.0 + event.magnification)));

  // Adjust pan so the fraction under the cursor stays put.
  _panOffset = fracUnderCursor - (loc.x - trackX) / (_zoom * trackWidth);
  [self _clampPanOffset];
  [self mouseMoved:event];
  [self renderLanes];
  if (self.onZoomPanChanged)
    self.onZoomPanChanged(_zoom, _panOffset);
}

- (void)scrollWheel:(NSEvent *)event {
  // Always forward to super so the enclosing NSScrollView gets a coherent
  // event stream (including zero-delta phase markers) — necessary for native
  // momentum to fire correctly on lift-off.
  [super scrollWheel:event];

  CGFloat dx = event.scrollingDeltaX;
  CGFloat dy = event.scrollingDeltaY;
  // Apply horizontal pan only when dx clearly dominates and we have a real
  // delta frame (not a phase marker).
  if (fabs(dx) <= fabs(dy) * 1.2 || (dx == 0 && dy == 0))
    return;

  CGFloat trackX, trackWidth;
  [self _trackGeometryForWidth:NSWidth(self.bounds)
                        trackX:&trackX
                    trackWidth:&trackWidth];
  if (event.hasPreciseScrollingDeltas)
    _panOffset -= dx / (_zoom * trackWidth);
  else
    _panOffset -= dx * 0.01 / _zoom;
  [self _clampPanOffset];

  NSPoint loc = [self.window mouseLocationOutsideOfEventStream];
  loc = [self convertPoint:loc fromView:nil];
  if (NSPointInRect(loc, self.bounds)) {
    [self mouseMoved:event];
  } else {
    _hoveringEdge = NO;
    _hoverLaneIdx = -1;
    _hoverSegIdx = -1;
    _hoverSegLaneIdx = -1;
    _hoverSegSegIdx = -1;
  }

  [self renderLanes];
  if (self.onZoomPanChanged)
    self.onZoomPanChanged(_zoom, _panOffset);
}

@end
#pragma clang diagnostic pop
