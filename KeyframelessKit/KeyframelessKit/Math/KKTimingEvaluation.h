/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>

#import <KeyframelessKit/KKTimingLane.h>
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

/// Evaluates `lane` at fraction `frac` (0–1 of clip duration) and returns
/// the per-component interpolated values.
///
/// - Adjacent keyposes with equal values evaluate as a hold (same values
///   returned across the span between them).
/// - Adjacent keyposes with different values interpolate using the outgoing
///   `KKInterval`'s curve and intensity.
/// - `frac` outside the keypose range clamps to the nearest endpoint.
///
/// Returns nil when `lane.keyposes` is empty. Disabled lanes are still
/// evaluated; call sites that want the kill-switch behaviour should check
/// `lane.enabled` themselves.
FOUNDATION_EXPORT
NSArray<NSNumber *> *_Nullable KKTimelineLaneValueAtFraction(KKLane *lane,
                                                             double frac);

/// Fraction of the smaller adjacent span used as the half-window for C1
/// join smoothing (see `KKTimelineLaneValueAtFractionSmoothed`). Shared so
/// the Basic graph preview and the render evaluator round joins identically.
/// Small on purpose: just a corner fillet at the joins, not a reshape of
/// the transition/hold.
#define KK_JOIN_BLEND_FRAC 0.08

/// Cubic-Hermite C1 join blend around a single boundary. When `frac` is
/// inside `[boundary - window, boundary + window]` the result is a Hermite
/// matching `sample`'s value *and* slope (central-difference) at both window
/// edges, so it splices back C1 into the surrounding curve while rounding
/// the velocity kink at `boundary`. Outside the window (or `window <= 0`)
/// it is exactly `sample(frac)`. Used by both the render evaluator and the
/// Basic timeline graph so they stay in lock-step.
FOUNDATION_EXPORT double KKHermiteJoinBlend(double frac, double boundary,
                                            double window,
                                            double (^sample)(double f));

/// Like `KKTimelineLaneValueAtFraction` but with C1 join smoothing applied
/// at every interior keypose, so transitions glide into/out of holds with
/// no detectable "stop" while long flats away from the joins are preserved.
/// The render / OSC / graph paths use this; authoring reads stay on the
/// exact (raw) `KKTimelineLaneValueAtFraction`.
FOUNDATION_EXPORT
NSArray<NSNumber *> *_Nullable KKTimelineLaneValueAtFractionSmoothed(
    KKLane *lane, double frac);

/// Same as `KKTimelineLaneValueAtFractionSmoothed` but with a Basic-view-
/// shape-aware fraction remap applied first. The Basic view stores Hold
/// keyposes at fixed tIn/tOut even when In/Out is off, but visually projects
/// the Hold-start to t=0 (In off) and Hold-end to t=1 (Out off). This call
/// applies that same projection on read, so a Hold-only drift evaluates
/// across the full clip rather than only between the stored kp times.
///
/// Inside an enabled In or Out transition region the remap is identity, so
/// In/Out easing is preserved unchanged.
FOUNDATION_EXPORT
NSArray<NSNumber *> *_Nullable KKTimelineLaneValueAtVisualFractionSmoothed(
    KKLane *lane, double visualFrac);

/// Returns YES when an OSC bound to `lane` should be visible at clip
/// fraction `frac`. Mirrors the Basic-view projection: an In-off lane's
/// Hold-start kp is visible at frac=0, an Out-off lane's Hold-end kp is
/// visible at the last-frame fraction (≈1.0). Snap tolerance is frame-
/// aware (≈one frame in fraction units) when the lane's
/// `lastKnownClipDuration` and `frameDurSec` are known, otherwise a
/// permissive default is used.
///
/// Constants — disabled lanes, or lanes with no keyposes — return YES
/// (always visible). Animated lanes with keyposes only return YES when
/// `frac` lands within `~1 frame` of a kp's *drawn* position.
///
/// `frameDurSec` is the project frame duration in seconds (e.g.
/// 1.0/60.0). Callers in plugin render context typically read it via
/// `FxTimingAPI`'s frame duration; OSC paths should keep a cached copy
/// (FxTimingAPI is nil from a drawOSC tick).
FOUNDATION_EXPORT BOOL KKLaneVisibleAtFraction(KKLane *lane, double frac,
                                               double frameDurSec);

/// Look-back window (seconds) used by both Canvas and MagicMove for the
/// rotate-with-motion velocity sample.
FOUNDATION_EXPORT const double KKRotateWithMotionWindowSeconds;

/// Z-rotation delta (radians) for rotate-with-motion: maps an X velocity
/// in normalised units/sec to the heading offset both plugins apply.
/// Adjustment is `-vx * 5° per unit/sec` — subtract from rotZ.
FOUNDATION_EXPORT double KKRotateWithMotionDeltaRadians(double vx);

NS_ASSUME_NONNULL_END
