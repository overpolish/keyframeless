/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>

#import <KeyframelessKit/KKTimeline.h>

NS_ASSUME_NONNULL_BEGIN

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

/// Wider join blend for boundaries where one side has hold-modulation. The
/// modulation envelope ramps its motion from zero at the keypose and an
/// ease-out arrives there at zero velocity too, so the join reads as a visible
/// "stop" before the wobble; a bigger fillet samples further into both sides
/// and carries motion through the join to hide it.
#define KK_JOIN_BLEND_MOD_FRAC 0.42

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

// 2D spatial (curved Position) path helpers live in KKSpatialCurve.h.

/// Returns YES when an OSC bound to `lane` should be visible at clip
/// fraction `frac`. Mirrors the Basic-view projection: an In-off lane's
/// Hold-start kp is visible at frac=0, an Out-off lane's Hold-end kp is
/// visible at the last-frame fraction (≈1.0). Snap tolerance is frame-
/// aware (≈one frame in fraction units) when the lane's
/// `lastKnownClipDuration` and `frameDurSec` are known, otherwise a
/// permissive default is used.
///
/// Constants - disabled lanes, or lanes with no keyposes - return YES
/// (always visible). Animated lanes with keyposes only return YES when
/// `frac` lands within `~1 frame` of a kp's *drawn* position.
///
/// `frameDurSec` is the project frame duration in seconds (e.g.
/// 1.0/60.0). Callers in plugin render context typically read it via
/// `FxTimingAPI`'s frame duration; OSC paths should keep a cached copy
/// (FxTimingAPI is nil from a drawOSC tick).
FOUNDATION_EXPORT BOOL KKLaneVisibleAtFraction(KKLane *lane, double frac,
                                               double frameDurSec);

/// Like KKLaneVisibleAtFraction, but the flat lead-in (before the first kp) and
/// lead-out (after the last kp) do NOT count - only a fraction sitting ON a
/// keypose returns YES for an animated lane (constants still always YES). Use
/// this where "the handle sits exactly on a keypose" is the question (e.g. an
/// OSC arc that should appear only at keyposes, and the anchor dot it covers),
/// so a lane parked past its final keypose still shows every anchor.
FOUNDATION_EXPORT BOOL KKLaneKeyedAtFraction(KKLane *lane, double frac,
                                             double frameDurSec);

/// Look-back window (seconds) used for the
/// rotate-with-motion velocity sample.
FOUNDATION_EXPORT const double KKRotateWithMotionWindowSeconds;

/// Z-rotation delta (radians) for rotate-with-motion: maps an X velocity
/// in normalised units/sec to the heading offset both plugins apply.
/// Adjustment is `-vx * 5° per unit/sec` - subtract from rotZ.
FOUNDATION_EXPORT double KKRotateWithMotionDeltaRadians(double vx);

NS_ASSUME_NONNULL_END
