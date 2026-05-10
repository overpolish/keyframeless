/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>

#import <KeyframelessKit/KKTimingStage.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the segment of `segments` covering the fraction `frac`, clamping
/// to the first segment when `frac < firstStart` and to the last when
/// `frac >= lastEnd`. Returns nil only when `segments` is empty.
FOUNDATION_EXPORT KKTimingSegment *_Nullable KKTimingSegmentForFraction(
    NSArray<KKTimingSegment *> *segments, double frac);

/// Evaluates `lane` at fraction `frac` (0–1 of clip duration) and returns
/// the per-component values appropriate for the lane's `valueComponentKinds`.
///
/// - **Float lanes** return a flat scalar array, one per component.
/// - **Color lanes** return `[R, G, B]`.
/// - **Point lanes** return `[X, Y]`.
/// - **Gradient lanes** return a flat LUT (`KK_GRADIENT_LUT_SIZE × [r,g,b]`)
///   computed from the active segment's stops, optionally modulated when
///   the segment carries a hold effect.
/// - **Bool components** are stepped — they use the active segment's own
///   value verbatim across transitions rather than easing-interpolated.
///
/// Returns nil when `lane.segments` is empty. Disabled lanes are still
/// evaluated by this function — call sites that want the kill-switch
/// behaviour should check `lane.enabled` themselves.
FOUNDATION_EXPORT NSArray<NSNumber *> *_Nullable KKTimingLaneValueAtFraction(
    KKTimingLane *lane, double frac);

/// Evaluates a position along the bezier curve stored on a Position-lane
/// transition segment, applying the segment's easing.
///
/// Caller computes `localT` (0–1 within the segment) and `isAnimateOut`
/// (true when the segment is the last in its lane — easing is flipped to
/// preserve the standard ease-in/out semantics for animate-out tails).
/// `fromPos` / `toPos` are the segment's start/end anchor positions, used
/// both as scaling input to `positionAtT:` and as fallback when the path
/// data fails to decode.
///
/// Returns NO when the segment is not a transition, has no `pathData`, or
/// the data fails to decode. On success writes the eased position to
/// `outPos` and returns YES.
FOUNDATION_EXPORT BOOL KKEvaluateBezierPathPosition(
    KKTimingSegment *active, BOOL isAnimateOut, double localT,
    simd_float2 fromPos, simd_float2 toPos, simd_float2 *outPos);

/// Look-back window (seconds) used by both Canvas and MagicMove for the
/// rotate-with-motion velocity sample.
FOUNDATION_EXPORT const double KKRotateWithMotionWindowSeconds;

/// Z-rotation delta (radians) for rotate-with-motion: maps an X velocity
/// in normalised units/sec to the heading offset both plugins apply.
/// Adjustment is `-vx * 5° per unit/sec` — subtract from rotZ.
FOUNDATION_EXPORT double KKRotateWithMotionDeltaRadians(double vx);

NS_ASSUME_NONNULL_END
