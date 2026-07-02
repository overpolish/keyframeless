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

/// Per-axis edge sign of a handle: -1 = left/bottom, +1 = right/top, 0 = the
/// centred (edge-midpoint) axis. Used to scale a handle drag about the anchor.
static inline double KKScaleHandleSignX(NSInteger h) {
  if (h == 0 || h == 3 || h == 7)
    return -1.0;
  if (h == 1 || h == 2 || h == 5)
    return 1.0;
  return 0.0; // 4, 6
}
static inline double KKScaleHandleSignY(NSInteger h) {
  if (h == 0 || h == 1 || h == 4)
    return -1.0;
  if (h == 2 || h == 3 || h == 6)
    return 1.0;
  return 0.0; // 5, 7
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

/// Canvas/overlay positions of the 8 scale-box handles, sized through the gizmo
/// curve (`e0`, `span`). `center` is the ANCHOR (the scale fixed point);
/// `anchorFrac` is the anchor's normalised position within the content box per
/// axis ([-1,1]; 0 = content centre, +-1 = an edge/corner). The box is offset by
/// -half*anchorFrac so the anchor stays put as the scale changes: a centred
/// anchor (0,0) is symmetric, a corner anchor keeps that corner fixed and grows
/// the opposite one. Fills `out[0..7]` in canonical KKBoxOSC order (0-3 corners
/// BL/BR/TR/TL, 4-7 edges bottom/right/top/left). Shared by viewer + mini.
FOUNDATION_EXPORT void KKScaleHandlePositions(CGPoint center, double sclX,
                                              double sclY, double e0,
                                              double span, CGPoint anchorFrac,
                                              CGPoint out[_Nonnull 8]);

/// Per-axis scale percent from a dragged handle, with the anchor as the fixed
/// point. The handle sits at `center + half*(sign - frac)`, so the cursor's
/// distance from the anchor gives `half = |eff - center| / |sign - frac|` and
/// this returns `curve^-1(half)`. `sign` is the handle's edge sign on this axis
/// (see KKScaleHandleSignX/Y). Returns -1 when the handle coincides with the
/// anchor on this axis (|sign - frac| ~ 0), i.e. that axis cannot scale from
/// here - the caller should hold the press value.
FOUNDATION_EXPORT double KKScaleGizmoPercentForHandle(double effCoord,
                                                      double centerCoord,
                                                      double sign, double frac,
                                                      double e0, double span);

/// The anchor's normalised position within the content box, per axis ([-1,1]; 0 =
/// centre, +-1 = an edge/corner): `(anchor - reference) / half`, clamped. The
/// scale box keeps the anchor fixed by offsetting `center - half*frac`. No Y flip
/// (the box offset is applied in the lane-aligned space the pivot maps through).
/// A degenerate (zero) half yields 0 on that axis. Shared by the viewer
/// (KKScaleOSC) and the mini (host `scaleAnchorFrac`).
FOUNDATION_EXPORT CGPoint KKScaleGizmoAnchorFrac(double ax, double ay,
                                                 double refX, double refY,
                                                 double halfX, double halfY);

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
