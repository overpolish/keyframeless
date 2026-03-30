/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKEasing.h"
#import <math.h>

double KKEaseSmoothstep(double t) { return t * t * (3.0 - 2.0 * t); }

double KKEaseOutCubic(double t) { return 1.0 - pow(1.0 - t, 3.0); }

double KKEaseOutSpring(double t) {
  const double c1 = 1.0, c3 = c1 + 1.0;
  return 1.0 + c3 * pow(t - 1.0, 3.0) + c1 * pow(t - 1.0, 2.0);
}

double KKApplyCurveIn(double raw, KKEasingCurve curve) {
  switch (curve) {
  case KKEasingCurveLinear:
    return raw;
  case KKEasingCurveSmooth:
    return KKEaseSmoothstep(raw);
  case KKEasingCurveSpring:
    return KKEaseOutSpring(raw);
  default:
    return KKEaseOutCubic(raw);
  }
}

double KKApplyCurveOut(double raw, KKEasingCurve curve) {
  switch (curve) {
  case KKEasingCurveLinear:
    return raw;
  case KKEasingCurveSmooth:
    return KKEaseSmoothstep(raw);
  case KKEasingCurveSpring:
    return KKEaseOutSpring(raw);
  default:
    return KKEaseSmoothstep(raw);
  }
}
