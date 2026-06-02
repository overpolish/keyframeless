/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "ShaderTypes.h"
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Fills `outParams` from the persisted timeline at clip fraction `frac`.
/// Used by the FCP render path (`Plugin+Render.m`); the mini-canvas takes
/// its own path so it can layer live drag values on top of the timeline.
///
/// `effectDurSec` is the clip duration in seconds; pass 0 to disable the
/// rotate-with-motion velocity sample (it has no meaning without a real
/// time base).
FOUNDATION_EXPORT void
KKMagicMoveFillParamsFromTimeline(MagicMoveParams *outParams,
                                  KKTimeline *_Nullable timeline, double frac,
                                  double effectDurSec);

/// Rotate-with-motion auto-orient angle (degrees, to ADD to rotZ) for one frame
/// on the Position lane: the 2D heading of the path's velocity, so the clip
/// points along its direction of travel. Returns 0 when the current interval
/// has the flag off, the lane has fewer than two keyposes, the clip duration is
/// zero, or the path isn't moving. Hermite-fades to 0 at the boundaries of a
/// rotate-with-motion region. The velocity is sampled from the timeline (the
/// persisted history), not a drag's in-flight value.
FOUNDATION_EXPORT double
KKMagicMoveRotateWithMotionAdjustmentDegrees(KKLane *_Nullable positionLane,
                                             double frac, double effectDurSec);

NS_ASSUME_NONNULL_END
