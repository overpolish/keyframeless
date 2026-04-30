/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKEasing.h"
#import <math.h>

static double KKEaseIn(double t, double intensity) {
  double exponent = 1.0 + intensity * 7.0;
  double power = pow(t, exponent);
  if (intensity <= 0.5)
    return power;
  double overshoot = (intensity - 0.5) * 2.0 * 2.5;
  double back = t * t * ((overshoot + 1.0) * t - overshoot);
  double blend = (intensity - 0.5) * 2.0;
  return power * (1.0 - blend) + back * blend;
}

static double KKEaseOut(double t, double intensity) {
  double exponent = 1.0 + intensity * 7.0;
  double u = 1.0 - t;
  double power = 1.0 - pow(u, exponent);
  if (intensity <= 0.5)
    return power;
  double overshoot = (intensity - 0.5) * 2.0 * 2.5;
  double back = 1.0 - u * u * ((overshoot + 1.0) * u - overshoot);
  double blend = (intensity - 0.5) * 2.0;
  return power * (1.0 - blend) + back * blend;
}

static double KKEaseInOut(double t, double intensity) {
  double exponent = 1.0 + intensity * 7.0;
  double power;
  if (t < 0.5)
    power = pow(2.0, exponent - 1.0) * pow(t, exponent);
  else {
    double u = -2.0 * t + 2.0;
    power = 1.0 - pow(u, exponent) / 2.0;
  }
  if (intensity <= 0.5)
    return power;
  double overshoot = (intensity - 0.5) * 2.0 * 2.5 * 1.525;
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

static double KKEaseOutElastic(double t, double intensity, double frequency) {
  if (t <= 0.0)
    return 0.0;
  if (t >= 1.0)
    return 1.0;

  // Amplitude always 1 so the curve naturally starts at 0
  double period = 0.5 * (1.7 - frequency * 1.4);
  if (period < 0.05)
    period = 0.05;
  // Low intensity = fast decay (subtle), high intensity = slow decay (dramatic)
  double decay = 15.0 - intensity * 13.0;

  return pow(2.0, -decay * t) *
             sin((t - period / 4.0) * (2.0 * M_PI) / period) +
         1.0;
}

static double KKEaseOutBounce(double t, double intensity, double frequency) {
  if (t <= 0.0)
    return 0.0;
  if (t >= 1.0)
    return 1.0;

  // intensity: restitution (how much speed is retained per bounce)
  // frequency: number of bounces (2-7)
  double restitution = 0.15 + intensity * 0.75;
  int numBounces = 2 + (int)round(frequency * 5.0);

  // Compute segment durations proportional to air time per bounce
  double durations[9];
  durations[0] = 1.0;
  double total = 1.0;
  for (int i = 1; i <= numBounces; i++) {
    durations[i] = pow(restitution, i);
    total += durations[i];
  }
  for (int i = 0; i <= numBounces; i++)
    durations[i] /= total;

  // Find which segment t falls into
  double cumul = 0;
  for (int i = 0; i <= numBounces; i++) {
    double d = durations[i];
    if (t <= cumul + d || i == numBounces) {
      double local = (t - cumul) / d;
      if (i == 0) {
        // First arc: ease-out parabola from 0 to 1
        return 1.0 - (1.0 - local) * (1.0 - local);
      }
      // Bounce arc: starts at 1, dips to 1-depth, returns to 1
      double depth = pow(restitution, 2.0 * i);
      return 1.0 - depth * 4.0 * local * (1.0 - local);
    }
    cumul += d;
  }
  return 1.0;
}

double KKApplyEasing(double raw, KKEasingCurve curve, double intensity,
                     double frequency) {
  switch (curve) {
  case KKEasingCurveLinear:
    return raw;
  case KKEasingCurveEaseIn:
    return KKEaseIn(raw, intensity);
  case KKEasingCurveEaseOut:
    return KKEaseOut(raw, intensity);
  case KKEasingCurveEaseInOut:
    return KKEaseInOut(raw, intensity);
  case KKEasingCurveElastic:
    return KKEaseOutElastic(raw, intensity, frequency);
  case KKEasingCurveBounce:
    return KKEaseOutBounce(raw, intensity, frequency);
  default:
    return raw;
  }
}

// Derive a pseudo-random double from a seed and index.
static double KKSeedHash(int seed, int idx) {
  unsigned v = (unsigned)(seed * 2654435761u + idx * 2246822519u);
  v ^= v >> 16;
  v *= 0x45d9f3b;
  v ^= v >> 16;
  return (double)(v & 0xFFFF) / 65535.0;
}

double KKSeedSign(int seed, int index) {
  if (seed == 0)
    return 1.0;
  return (KKSeedHash(seed, index + 100) > 0.5) ? 1.0 : -1.0;
}

static double KKHoldBounce(double t, double frequency, int seed) {
  double freq = 1.0 + frequency * 11.0;
  double phase = (seed != 0) ? KKSeedHash(seed, 0) * M_PI * 2.0 : 0.0;
  return 1.0 + 0.15 * sin(t * M_PI * freq + phase) * sin(t * M_PI);
}

static double KKHoldWiggle(double t, double frequency, int seed) {
  double fScale = 0.25 + frequency * 2.75;
  double envelope = sin(t * M_PI);
  double f0 = 17.0, f1 = 31.0, f2 = 59.0, f3 = 97.0;
  double p0 = 0, p1 = 0, p2 = 0, p3 = 0;
  if (seed != 0) {
    f0 = 13.0 + KKSeedHash(seed, 0) * 10.0;
    f1 = 27.0 + KKSeedHash(seed, 1) * 12.0;
    f2 = 47.0 + KKSeedHash(seed, 2) * 24.0;
    f3 = 79.0 + KKSeedHash(seed, 3) * 36.0;
    p0 = KKSeedHash(seed, 4) * M_PI * 2.0;
    p1 = KKSeedHash(seed, 5) * M_PI * 2.0;
    p2 = KKSeedHash(seed, 6) * M_PI * 2.0;
    p3 = KKSeedHash(seed, 7) * M_PI * 2.0;
  }
  double noise =
      sin(t * f0 * fScale + p0) * 0.4 + sin(t * f1 * fScale + p1) * 0.3 +
      sin(t * f2 * fScale + p2) * 0.2 + sin(t * f3 * fScale + p3) * 0.1;
  return 1.0 + 0.08 * noise * envelope;
}

double KKApplyHoldEffect(double t, KKHoldEffect effect, double intensity,
                         double frequency, int seed) {
  double scale = 0.2 + intensity * 2.8; // 0.2 at min, 3.0 at max
  switch (effect) {
  case KKHoldEffectBounce: {
    double raw = KKHoldBounce(t, frequency, seed);
    return 1.0 + (raw - 1.0) * scale;
  }
  case KKHoldEffectWiggle: {
    double raw = KKHoldWiggle(t, frequency, seed);
    return 1.0 + (raw - 1.0) * scale;
  }
  case KKHoldEffectNone:
  default:
    return 1.0;
  }
}

double KKApplyHoldEffectForComponent(double t, KKHoldEffect effect,
                                     double intensity, double frequency,
                                     int seed, int component) {
  if (component == 0)
    return KKApplyHoldEffect(t, effect, intensity, frequency, seed);
  // Mix the component index into the seed with a large odd multiplier so
  // each component gets an independent phase/frequency set. A non-zero
  // seed is guaranteed so the per-component randomised path runs even
  // when the caller passes seed == 0.
  int mixed = seed ^ (int)((unsigned)component * 0x9E3779B9u);
  if (mixed == 0)
    mixed = component + 1;
  return KKApplyHoldEffect(t, effect, intensity, frequency, mixed);
}
