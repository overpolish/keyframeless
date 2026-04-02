/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKEasing.h"
#import <math.h>

static double KKEaseIn(double t, double intensity) {
  double exponent = 2.0 + intensity * 4.0;
  double power = pow(t, exponent);
  if (intensity <= 0.5)
    return power;
  double overshoot = (intensity - 0.5) * 2.0 * 1.7;
  double back = t * t * ((overshoot + 1.0) * t - overshoot);
  double blend = (intensity - 0.5) * 2.0;
  return power * (1.0 - blend) + back * blend;
}

static double KKEaseOut(double t, double intensity) {
  double exponent = 2.0 + intensity * 4.0;
  double u = 1.0 - t;
  double power = 1.0 - pow(u, exponent);
  if (intensity <= 0.5)
    return power;
  double overshoot = (intensity - 0.5) * 2.0 * 1.7;
  double back = 1.0 - u * u * ((overshoot + 1.0) * u - overshoot);
  double blend = (intensity - 0.5) * 2.0;
  return power * (1.0 - blend) + back * blend;
}

static double KKEaseInOut(double t, double intensity) {
  double exponent = 2.0 + intensity * 4.0;
  double power;
  if (t < 0.5)
    power = pow(2.0, exponent - 1.0) * pow(t, exponent);
  else {
    double u = -2.0 * t + 2.0;
    power = 1.0 - pow(u, exponent) / 2.0;
  }
  if (intensity <= 0.5)
    return power;
  double overshoot = (intensity - 0.5) * 2.0 * 1.7 * 1.525;
  double back;
  if (t < 0.5)
    back = (4.0 * t * t * ((overshoot + 1.0) * 2.0 * t - overshoot)) / 2.0;
  else {
    double u = 2.0 * t - 2.0;
    back = (u * u * ((overshoot + 1.0) * u + overshoot) + 2.0) / 2.0;
  }
  double blend = (intensity - 0.5) * 2.0;
  return power * (1.0 - blend) + back * blend;
}

static double KKEaseOutElastic(double t, double intensity) {
  if (t <= 0.0)
    return 0.0;
  if (t >= 1.0)
    return 1.0;
  double amplitude = 0.5 + intensity * 0.5;
  double period = 0.45 - intensity * 0.15;
  return amplitude * pow(2.0, -10.0 * t) *
             sin((t - period / 4.0) * (2.0 * M_PI) / period) +
         1.0;
}

static double KKEaseOutBounce(double t, double intensity) {
  double n = 2.0 + intensity * 1.5;
  double n2 = n * n;
  double offset4 = (2.5 + n) / (2.0 * n);
  double h4 = 1.0 - (n - 2.5) * (n - 2.5) / 4.0;
  if (t < 1.0 / n)
    return n2 * t * t;
  if (t < 2.0 / n) {
    t -= 1.5 / n;
    return n2 * t * t + 0.75;
  }
  if (t < 2.5 / n) {
    t -= 2.25 / n;
    return n2 * t * t + 0.9375;
  }
  t -= offset4;
  return n2 * t * t + h4;
}

double KKApplyEasing(double raw, KKEasingCurve curve, double intensity) {
  switch (curve) {
  case KKEasingCurveEaseIn:
    return KKEaseIn(raw, intensity);
  case KKEasingCurveEaseOut:
    return KKEaseOut(raw, intensity);
  case KKEasingCurveEaseInOut:
    return KKEaseInOut(raw, intensity);
  case KKEasingCurveElastic:
    return KKEaseOutElastic(raw, intensity);
  case KKEasingCurveBounce:
    return KKEaseOutBounce(raw, intensity);
  default:
    return KKEaseOut(raw, intensity);
  }
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
