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

static double KKHoldBounce(double t) {
  return 1.0 + 0.15 * sin(t * M_PI * 4.0) * sin(t * M_PI);
}

static double KKHoldWiggle(double t) {
  double envelope = sin(t * M_PI);
  double noise = sin(t * 17.0) * 0.4 + sin(t * 31.0) * 0.3 +
                 sin(t * 59.0) * 0.2 + sin(t * 97.0) * 0.1;
  return 1.0 + 0.08 * noise * envelope;
}

double KKApplyHoldEffect(double t, KKHoldEffect effect) {
  switch (effect) {
  case KKHoldEffectBounce:
    return KKHoldBounce(t);
  case KKHoldEffectWiggle:
    return KKHoldWiggle(t);
  case KKHoldEffectNone:
  default:
    return 1.0;
  }
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
