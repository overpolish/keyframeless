/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "OSC.h"
#import <FxPlug/FxPlugSDK.h>

NS_ASSUME_NONNULL_BEGIN

@class KKPositionOSC;

@interface GlowOSC () {
@protected
  BOOL _ringDragging;
  // YES while the Position handle / a motion-path tangent is being dragged
  // (mirrored into the Position controller's `dragging` so it keeps drawing).
  BOOL _positionDragging;
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

// Reusable Position handle + motion path (offsets the glow), composed alongside
// the radius ring. guideProvider is nil (Glow has no Position guide).
@property(nonatomic, strong) KKPositionOSC *positionController;

// Geometry/time helpers implemented in the primary @implementation (OSC.m);
// called by the MouseHandlers category.
- (double)fractionAtTime:(CMTime)time;
- (CGPoint)canvasCenter;
- (double)canvasMinDimension;
- (void)updateRingForFraction:(double)frac;

// OSC-guide bridge helpers (OSC.m): the clip frame's object-corners in canvas
// space, the [X, Y] radius the ring draws at a fraction (guide-scoped value
// while a guide step runs, else the snapshot), and the ring "handle" / target
// points (a point on the ellipse at 45 degrees) the bridge spotlights.
- (BOOL)getCanvasTopRight:(CGPoint *)outTopRight
               bottomLeft:(CGPoint *)outBottomLeft;
- (NSArray<NSNumber *> *)guideRadiusValuesForFraction:(double)frac;
- (CGPoint)ringHandleCanvasPositionForFraction:(double)frac;
- (CGPoint)guideTargetCanvasPosition;

@end

/// Pointer event handlers (mouseMoved/Down/Dragged/Up). Split out of OSC.m for
/// file size; implemented in GlowOSC+MouseHandlers.m. The drag writes the
/// timeline blob inside an FxCustomParameterAction scope (the only API that
/// resolves outside a host callback).
@interface GlowOSC (MouseHandlers)
@end

NS_ASSUME_NONNULL_END
