/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "ShaderTypes.h"
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Fills `outParams` from the persisted timeline at clip fraction `frac`.
/// Used by the FCP render path (`Plugin+Render.m`); the mini-viewer takes
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

/// MPS Gaussian blur of `src` into a fresh intermediate, sized in the source's
/// own pixel space (resolution-independent) with `blurFrac` in 0..1 (the Blur
/// lane's 0-100% as a fraction). Encodes on the caller-owned command buffer and
/// returns the blurred texture, or `src` unchanged when the blur is negligible
/// or the device/textures are missing. Shared by the FCP render path and the
/// mini-viewer so both show the same blur.
FOUNDATION_EXPORT id<MTLTexture> _Nullable KKMagicMoveBlurredTexture(
    id<MTLTexture> _Nullable src, float blurFrac, id<MTLDevice> _Nullable device,
    id<MTLCommandBuffer> _Nullable cb);

NS_ASSUME_NONNULL_END
