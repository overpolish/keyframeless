/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

/// Animation curve presets matching KKEasingCurve in KKPlugin.h.
typedef NS_ENUM(NSInteger, KKEasingCurve) {
  KKEasingCurveLinear = 0,
  KKEasingCurveSmooth = 1,
  KKEasingCurveCubic = 2,
  KKEasingCurveSpring = 3,
};

/// Hermite smoothstep: symmetric ease in/out.
double KKEaseSmoothstep(double t);

/// Ease-out cubic: fast start, decelerates to rest.
double KKEaseOutCubic(double t);

/// Ease-out spring (back): overshoots target once, settles back.
double KKEaseOutSpring(double t);

/// Apply the given animation curve for an animate-in factor.
/// Default (Cubic) uses ease-out cubic.
double KKApplyCurveIn(double raw, KKEasingCurve curve);

/// Apply the given animation curve for an animate-out factor.
/// Default (Cubic) uses smoothstep.
double KKApplyCurveOut(double raw, KKEasingCurve curve);
