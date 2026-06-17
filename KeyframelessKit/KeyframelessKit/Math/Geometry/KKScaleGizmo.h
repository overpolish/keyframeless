/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Scale-box extent fractions (of the surface's reference dimension - the
/// viewer's frame min, the mini-viewer's content-rect min): `e0` and `span` for
/// KKScaleGizmoExtentForPercent. Shared so the viewer and mini-viewer boxes
/// have identical proportions.
static const double KKScaleGizmoE0Frac = 0.12;
static const double KKScaleGizmoSpanFrac = 0.057;

/// Scale-box handle indices, canonical order (matches KKBoxOSC): 0-3 corners
/// (BL, BR, TR, TL), 4-7 edge midpoints (bottom, right, top, left). Corners
/// drive both axes; bottom/top (4/6) drive Y; right/left (5/7) drive X.
static inline BOOL KKScaleHandleIsCorner(NSInteger h) {
  return h >= 0 && h <= 3;
}
static inline BOOL KKScaleHandleControlsX(NSInteger h) {
  return KKScaleHandleIsCorner(h) || h == 5 || h == 7;
}
static inline BOOL KKScaleHandleControlsY(NSInteger h) {
  return KKScaleHandleIsCorner(h) || h == 4 || h == 6;
}

/// Sizing curve for a Scale on-screen gizmo (the transform bounding box).
///
/// A scale OSC must stay grabbable at every value: tied to the clip's real
/// pixel bounds it would be off-screen on a big clip and collapse to a point at
/// 0% (the dead-end where the handles vanish and you can't scale back up). So
/// the box is a compact screen-space gizmo whose half-extent maps the scale
/// PERCENT through a fixed curve instead, anchored just outside the rotation
/// rings. The live readout carries the true value, so the box never needing to
/// be tiny at 0% reads as intentional.
///
/// The curve is parametrised by two lengths (in the surface's own OSC units, so
/// the viewer and mini-viewer share the shape at their own scales):
///   * `e0` - half-extent at 0% (the minimum; just outside the rotation rings)
///   * `span` - growth from 0% to 100% (so 100% = `e0 + span`)
/// Below 100% it is linear; above 100% it continues as a slope-matched sqrt so
/// the handles keep moving (always draggable, fine-grain control retained) yet
/// the box never flies off-screen.

/// Half-extent (one axis) for a scale `percent` (>= 0), given the 0% minimum
/// `e0` and the 0->100% `span`. Monotonic increasing, C1-continuous at 100%.
FOUNDATION_EXPORT double KKScaleGizmoExtentForPercent(double percent, double e0,
                                                      double span);

/// Inverse of KKScaleGizmoExtentForPercent: the scale percent that puts the
/// handle at half-extent `extent`. Clamps to 0 at/below `e0`. Used by a drag to
/// turn the cursor's distance from centre back into a percentage.
FOUNDATION_EXPORT double KKScaleGizmoPercentForExtent(double extent, double e0,
                                                      double span);

/// Canvas/overlay positions of the 8 scale-box handles for a box centred on
/// `center` with the given X/Y scale percents, sized through the gizmo curve
/// (`e0`, `span`). Fills `out[0..7]` in the canonical KKBoxOSC order (0-3
/// corners BL/BR/TR/TL, 4-7 edges bottom/right/top/left). Shared by the viewer
/// and mini-viewer so draw + hit-test always agree.
FOUNDATION_EXPORT void KKScaleHandlePositions(CGPoint center, double sclX,
                                              double sclY, double e0,
                                              double span,
                                              CGPoint out[_Nonnull 8]);

/// The scale-box drag coupling. Given the grabbed `handle` (0-7), the press
/// scale (`pressX`, `pressY`) and the candidate per-axis percents
/// (`candX`, `candY`) the cursor's distance maps to, compute the new X/Y scale:
///   * corner handles drive both axes - a single geometric-mean factor when
///     `linked` (continuous, no dominant-axis flip), else each axis free;
///   * edge handles drive one axis - the other follows by ratio when `linked`,
///     else holds at its press value.
/// Output is rounded to whole percents and floored at 0 (no negative/flipped
/// scale). Shared by the viewer (KKScaleOSC) and mini (KKScaleMiniController)
/// so the rule lives in one place.
FOUNDATION_EXPORT void
KKScaleValuesForHandleDrag(NSInteger handle, double pressX, double pressY,
                           double candX, double candY, BOOL linked,
                           double *_Nullable outX, double *_Nullable outY);

NS_ASSUME_NONNULL_END
