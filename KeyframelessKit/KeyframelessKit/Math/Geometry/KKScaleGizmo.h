/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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

NS_ASSUME_NONNULL_END
