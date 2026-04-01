/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKEasing.h"
#import <math.h>

double KKEaseInQuart(double t) { return t * t * t * t; }

double KKEaseOutQuart(double t) {
  double u = 1.0 - t;
  return 1.0 - u * u * u * u;
}

double KKEaseInOutQuart(double t) {
  if (t < 0.5)
    return 8.0 * t * t * t * t;
  double u = -2.0 * t + 2.0;
  return 1.0 - u * u * u * u / 2.0;
}

double KKEaseOutElastic(double t) {
  if (t <= 0.0)
    return 0.0;
  if (t >= 1.0)
    return 1.0;
  return pow(2.0, -10.0 * t) * sin((t * 10.0 - 0.75) * (2.0 * M_PI / 3.0)) +
         1.0;
}

double KKEaseOutBounce(double t) {
  if (t < 1.0 / 2.75)
    return 7.5625 * t * t;
  if (t < 2.0 / 2.75) {
    t -= 1.5 / 2.75;
    return 7.5625 * t * t + 0.75;
  }
  if (t < 2.5 / 2.75) {
    t -= 2.25 / 2.75;
    return 7.5625 * t * t + 0.9375;
  }
  t -= 2.625 / 2.75;
  return 7.5625 * t * t + 0.984375;
}

double KKApplyEasing(double raw, KKEasingCurve curve) {
  switch (curve) {
  case KKEasingCurveEaseIn:
    return KKEaseInQuart(raw);
  case KKEasingCurveEaseOut:
    return KKEaseOutQuart(raw);
  case KKEasingCurveEaseInOut:
    return KKEaseInOutQuart(raw);
  case KKEasingCurveElastic:
    return KKEaseOutElastic(raw);
  case KKEasingCurveBounce:
    return KKEaseOutBounce(raw);
  default:
    return KKEaseOutQuart(raw);
  }
}
