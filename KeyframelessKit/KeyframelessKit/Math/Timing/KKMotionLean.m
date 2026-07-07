/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMotionLean.h"
#import "KKTimingEvaluation.h"
#import <math.h>

KKMotionLeanConfig KKMotionLeanConfigDefault(void) {
  return (KKMotionLeanConfig){
      .gravity = 80.0,
      .tauVel = 0.09,
      .tauAngle = 0.14,
      .warmupSec = 0.8,
      .maxLeanDeg = 30.0,
      .settleSec = 0.4, // ~3x tauAngle: the tilt reaches rest within this
  };
}

// Index of the keypose that *owns* the gap containing `frac` (so
// keyposes[idx].outgoing is that gap), or -1 if `frac` is outside every gap.
static NSInteger KKMotionLeanGapIndexAtFraction(NSArray<KKKeyPose *> *kps,
                                                double frac) {
  for (NSInteger i = 0; i + 1 < (NSInteger)kps.count; i++)
    if (frac >= kps[i].time && frac < kps[i + 1].time)
      return i;
  if (kps.count >= 2 && frac >= kps.lastObject.time)
    return (NSInteger)kps.count - 2;
  return -1;
}

// Fraction at which the contiguous run of active gaps containing gap `idx`
// begins (walk back while the preceding gap is also active). Before this point
// there is no lean to remember.
static double KKMotionLeanRunStartFraction(NSArray<KKKeyPose *> *kps,
                                           NSInteger idx,
                                           KKMotionLeanIntervalActive active) {
  NSInteger start = idx;
  while (start > 0 && (!active || active(kps[start - 1].outgoing)))
    start--;
  return kps[start].time;
}

// Horizontal position (component 0) of the lane at clip fraction `frac`, using
// the same smoothed evaluation the clip renders with so the lean matches the
// visible motion. Falls back to `fallback` if the lane has no value there.
static double KKMotionLeanSampleX(KKLane *lane, double frac, double fallback) {
  NSArray<NSNumber *> *v =
      KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  return v.count > 0 ? v[0].doubleValue : fallback;
}

// Integrate the lean angle over [t0, t1] (seconds) from a zero initial state.
// Two cascaded first-order low-passes: the first cleans the velocity, the
// second gives the angle its inertia. Neither can overshoot or oscillate, so
// they add weight without a spring's independent ringing.
// `holdAfterSec` freezes the sampled position at that time for the rest of the
// window: past the active run the clip is no longer contributing motion, so the
// low-passes relax the tilt to rest by inertia alone (no new acceleration). Pass
// t1 for a fully live window (the normal in-run case).
static double KKMotionLeanIntegrate(KKLane *lane, double t0, double t1,
                                    double holdAfterSec, double durationSec,
                                    KKMotionLeanConfig cfg) {
  double dtTarget = 1.0 / 120.0;
  NSInteger steps = (NSInteger)ceil((t1 - t0) / dtTarget);
  if (steps < 1)
    steps = 1;
  double dt = (t1 - t0) / (double)steps;
  double aVel = 1.0 - exp(-dt / cfg.tauVel);
  double aAng = 1.0 - exp(-dt / cfg.tauAngle);

  double prevX =
      KKMotionLeanSampleX(lane, MIN(t0, holdAfterSec) / durationSec, 0.5);
  double vSmooth = 0.0, prevVSmooth = 0.0, angle = 0.0;
  for (NSInteger s = 1; s <= steps; s++) {
    double ts = MIN(t0 + dt * s, holdAfterSec); // freeze position past the run
    double x = KKMotionLeanSampleX(lane, MIN(1.0, ts / durationSec), prevX);
    double v = (x - prevX) / dt; // raw horizontal velocity
    prevX = x;
    vSmooth += (v - vSmooth) * aVel;         // low-pass 1: clean velocity
    double a = (vSmooth - prevVSmooth) / dt; // acceleration of clean velocity
    prevVSmooth = vSmooth;
    double target = atan(-a / cfg.gravity) * (180.0 / M_PI); // equilibrium tilt
    angle += (target - angle) * aAng; // low-pass 2: inertia on the angle
  }
  return angle;
}

double KKMotionLeanDegrees(KKLane *lane, double frac, double durationSec,
                           KKMotionLeanConfig config,
                           KKMotionLeanIntervalActive active) {
  if (durationSec <= 0 || lane.keyposes.count < 2)
    return 0.0;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  NSInteger idx = KKMotionLeanGapIndexAtFraction(kps, frac);
  if (idx < 0)
    return 0.0;

  BOOL gapActive = (!active || active(kps[idx].outgoing));

  // Which gap anchors the active run, and up to which fraction the clip is still
  // feeding motion in. Inside an active gap that is the current gap and `frac`;
  // once the run ends we keep leaning through the following toggle-off gap(s),
  // freezing the position at the run's end so the tilt relaxes to rest by
  // inertia (the low-passes' natural decay) instead of snapping to 0.
  NSInteger runAnchorIdx = idx;
  double holdEndFrac = frac;
  if (!gapActive) {
    if (config.settleSec <= 0.0)
      return 0.0;
    NSInteger k = idx;
    while (k >= 0 && active && !active(kps[k].outgoing))
      k--; // walk back over toggle-off gaps to the last active gap
    if (k < 0)
      return 0.0; // no active run precedes this gap
    runAnchorIdx = k;
    double runEndFrac = kps[k + 1].time; // the run ends at this keypose
    if ((frac - runEndFrac) * durationSec > config.settleSec)
      return 0.0; // settle window elapsed; the tilt has reached rest
    holdEndFrac = runEndFrac;
  }

  double runStartFrac =
      KKMotionLeanRunStartFraction(kps, runAnchorIdx, active);
  if (frac <= runStartFrac)
    return 0.0;

  double t1 = frac * durationSec;
  double t0 = MAX(runStartFrac * durationSec, t1 - config.warmupSec);
  double angle = KKMotionLeanIntegrate(lane, t0, t1, holdEndFrac * durationSec,
                                       durationSec, config);

  // Settle tail: the low-pass decay alone still leaves a small residual at the
  // settleSec cut-off. Multiply by a smoothstep envelope (flat slope at both
  // ends) so the tilt joins the in-run value at u=0 and reaches exactly rest at
  // u=1 - no snap on either side. No-op inside the active run (u == 0).
  if (!gapActive) {
    double u = (frac - holdEndFrac) * durationSec / config.settleSec;
    u = MAX(0.0, MIN(1.0, u));
    angle *= 1.0 - u * u * (3.0 - 2.0 * u);
  }

  if (angle > config.maxLeanDeg)
    return config.maxLeanDeg;
  if (angle < -config.maxLeanDeg)
    return -config.maxLeanDeg;
  return angle;
}
