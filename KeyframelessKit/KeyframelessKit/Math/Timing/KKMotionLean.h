/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKTimingStage.h>

NS_ASSUME_NONNULL_BEGIN

/// Tuning for the "lean into motion" tilt (rotate-with-motion). Times are in
/// seconds, angles in degrees. The defaults are exposed so callers can nudge a
/// single knob without re-deriving the whole set.
typedef struct {
  /// Larger -> subtler lean. A tuning constant, not 9.8: position is in
  /// normalised canvas units, so this scales atan(acceleration / gravity).
  double gravity;
  /// Velocity low-pass time constant - cleans the noisy finite-difference
  /// velocity before it is differentiated into acceleration.
  double tauVel;
  /// Angle low-pass time constant - the lean's inertia. Also blends the
  /// acceleration jump (C2 discontinuity) at a keypose join so the tilt does
  /// not visibly shift there.
  double tauAngle;
  /// How far before the playhead the integration starts. The low-passes forget
  /// their past exponentially, so a window of a few `tauAngle` reproduces the
  /// full-run result at constant cost (motion blur evaluates this N times per
  /// frame, so run-length-independent cost matters).
  double warmupSec;
  /// Safety clamp on the output magnitude (atan already bounds it).
  double maxLeanDeg;
  /// How long (seconds) the lean keeps decaying by its own inertia AFTER the
  /// active run of rotate-with-motion gaps ends, spilling into the following
  /// (toggle-off) gap so the tilt settles to rest instead of snapping to 0 at
  /// the gap boundary. 0 restores the old hard cut-off. A few `tauAngle` is
  /// enough for the tilt to visually reach rest.
  double settleSec;
} KKMotionLeanConfig;

/// The tuned defaults.
FOUNDATION_EXPORT KKMotionLeanConfig KKMotionLeanConfigDefault(void);

/// Predicate deciding whether the gap leaving a keypose contributes lean (e.g.
/// a per-interval "rotate with motion" flag). Returns YES to include the gap.
typedef BOOL (^KKMotionLeanIntervalActive)(KKInterval *_Nullable outgoing);

/// Z-rotation tilt (degrees) for a 2D position `lane` at clip fraction `frac`.
///
/// Models the physical equilibrium tilt theta = atan(a / g) of the clip's
/// horizontal acceleration, smoothed by two cascaded first-order low-passes so
/// the lean has natural inertia (it carries through the acceleration sign-flip
/// at peak speed instead of snapping). The lean is bound directly to the motion
/// - there is no spring with its own oscillation to read as a separate spin.
///
/// Returns 0 when `durationSec <= 0`, the lane has fewer than two keyposes, or
/// the gap at `frac` is not active per `active` (pass nil to treat every gap as
/// active). Deterministic: depends only on the lane and `frac`, so scrubbing to
/// any frame reproduces the same value.
FOUNDATION_EXPORT double
KKMotionLeanDegrees(KKLane *_Nullable lane, double frac, double durationSec,
                    KKMotionLeanConfig config,
                    KKMotionLeanIntervalActive _Nullable active);

NS_ASSUME_NONNULL_END
