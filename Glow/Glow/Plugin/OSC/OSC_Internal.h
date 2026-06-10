/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "OSC.h"
#import <FxPlug/FxPlugSDK.h>

NS_ASSUME_NONNULL_BEGIN

@interface GlowOSC () {
@protected
  BOOL _ringDragging;
  // Cursor offset from the ring centre at mouse-down (signed dx/dy and the
  // radial distance), plus the per-axis radius values then. A linked drag
  // scales both axes by the radial-distance ratio (circle); an unlinked drag
  // (lane unlinked, or Shift inverting it) scales each axis by its own
  // component ratio (ellipse), mirroring the bounding-box OSC.
  double _ringDragStartDx;
  double _ringDragStartDy;
  double _ringDragStartDist;
  double _ringDragStartValX;
  double _ringDragStartValY;
}

// Geometry/time helpers implemented in the primary @implementation (OSC.m);
// called by the MouseHandlers category.
- (double)fractionAtTime:(CMTime)time;
- (CGPoint)canvasCenter;
- (double)canvasMinDimension;
- (void)updateRingForFraction:(double)frac;

@end

/// Pointer event handlers (mouseMoved/Down/Dragged/Up). Split out of OSC.m for
/// file size; implemented in GlowOSC+MouseHandlers.m. The drag writes the
/// timeline blob inside an FxCustomParameterAction scope (the only API that
/// resolves outside a host callback).
@interface GlowOSC (MouseHandlers)
@end

NS_ASSUME_NONNULL_END
