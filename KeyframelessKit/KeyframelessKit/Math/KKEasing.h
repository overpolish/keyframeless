/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, KKEasingCurve) {
  KKEasingCurveLinear = 0,
  KKEasingCurveEaseIn = 1,
  KKEasingCurveEaseOut = 2,
  KKEasingCurveEaseInOut = 3,
  KKEasingCurveElastic = 4,
  KKEasingCurveBounce = 5,
};

static const NSInteger KKEasingCurveCount __attribute__((unused)) = 6;

typedef NS_ENUM(NSInteger, KKHoldEffect) {
  KKHoldEffectNone = 0,
  KKHoldEffectBounce = 1,
  KKHoldEffectWiggle = 2,
};

static const NSInteger KKHoldEffectCount __attribute__((unused)) = 3;

/// Apply the given curve to a raw 0→1 factor.
/// intensity: 0.0 (gentle) to 1.0 (pronounced), 0.5 = default.
/// frequency: 0.0 (few oscillations) to 1.0 (many), 0.5 = default.
///            Only affects Elastic and Bounce curves; ignored for others.
double KKApplyEasing(double raw, KKEasingCurve curve, double intensity,
                     double frequency);

/// Derive a sign (+1 or -1) from a seed and property index.
/// Useful for randomising per-property direction of hold effects.
double KKSeedSign(int seed, int index);

/// Apply a hold effect at time t (0→1 through the hold phase).
/// intensity: 0.0 (subtle) to 1.0 (pronounced), 0.5 = default.
/// frequency: 0.0 (slow) to 1.0 (fast), 0.5 = default.
/// seed: integer seed for variation (0 = deterministic default).
/// Returns a value centred around 1.0.
double KKApplyHoldEffect(double t, KKHoldEffect effect, double intensity,
                         double frequency, int seed);

/// Same as KKApplyHoldEffect but generates an independent factor per
/// component index. Used by multi-component lanes (e.g. Position) so X
/// and Y modulate independently instead of moving in lockstep along a
/// single vector. component == 0 matches KKApplyHoldEffect exactly.
double KKApplyHoldEffectForComponent(double t, KKHoldEffect effect,
                                     double intensity, double frequency,
                                     int seed, int component);
