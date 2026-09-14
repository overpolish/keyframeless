/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The one copy of the sRGB transfer function and the Oklab matrices.
//
// The grading ring, the vectorscope cloud and the puck's own pick/apply maths
// each used to carry their own transcription of these constants. They agreed, but
// nothing MADE them agree: one drifted digit in 0.4122214708 and the ring would
// paint one hue while the cloud binned another, which reads as pucks that land
// beside their clusters rather than on them. So they live here, once.
//
// Header-only, pure C, math.h and nothing else, because the callers span two
// processes: the render side (MirageSurfaceResponse.h) and the inspector side
// (the circle view, the scope sampler).
//
// The shader templates keep their OWN copies in GLSL on purpose - a template has
// to be self-contained - so this file is not their source and does not try to be.
#pragma once

#ifndef __METAL_VERSION__

#include <math.h>

/// One display-encoded sRGB channel to light-linear Rec.709.
static inline double MirageSRGBDecode(double v) {
  return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

/// One light-linear Rec.709 channel to display-encoded sRGB, with no clamping and
/// no special case at the ends. Callers that need a clamp pick one below.
///
/// Worth knowing before picking: the curve does NOT return exactly 1.0 for an
/// input of exactly 1.0. It returns one ULP under, because 1.055 * 1 - 0.055 is
/// not 1.0 in binary. Whether that ULP matters depends on what the caller does
/// next with the number, which is why this file does not decide for them.
static inline double MirageSRGBEncodeUnclamped(double v) {
  return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
}

/// One light-linear Rec.709 channel to display-encoded sRGB, with black and white
/// short-circuited to exactly 0.0 and 1.0.
static inline double MirageSRGBEncode(double v) {
  if (v <= 0.0)
    return 0.0;
  if (v >= 1.0)
    return 1.0;
  return MirageSRGBEncodeUnclamped(v);
}

/// Linear Rec.709 to the three cone responses Oklab is built on.
static inline void MirageLinearToLMS(double r, double g, double b, double *outL,
                                     double *outM, double *outS) {
  *outL = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
  *outM = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
  *outS = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;
}

/// The cube-rooted cone responses to Oklab L, a, b.
static inline void MirageCubeRootLMSToOklab(double l_, double m_, double s_,
                                            double *outL, double *outA,
                                            double *outB) {
  *outL = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
  *outA = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
  *outB = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;
}

/// Linear Rec.709 to Oklab, with negative cone responses clamped to zero.
///
/// The clamp is what a colour INSIDE the display gamut wants: a channel that came
/// out slightly negative from a bisection step is zero light, not light of the
/// opposite sign.
static inline void MirageLinearToOklab(double r, double g, double b, double *outL,
                                       double *outA, double *outB) {
  double l = 0.0, m = 0.0, s = 0.0;
  MirageLinearToLMS(r, g, b, &l, &m, &s);
  MirageCubeRootLMSToOklab(cbrt(fmax(l, 0.0)), cbrt(fmax(m, 0.0)),
                           cbrt(fmax(s, 0.0)), outL, outA, outB);
}

/// The same transform with the cone responses left SIGNED - `cbrt` is odd, so a
/// negative response comes through as a negative cube root rather than as zero.
///
/// This is what a measurement of arbitrary footage wants. Clamping there would
/// fold every wide-gamut pixel that sits outside Rec.709 onto the same wall and
/// pile a false cluster up against it, which is a lie about the frame rather than
/// a rounding of it. Identical to `MirageLinearToOklab` for any input already
/// inside the display gamut.
static inline void MirageLinearToOklabSigned(double r, double g, double b,
                                             double *outL, double *outA,
                                             double *outB) {
  double l = 0.0, m = 0.0, s = 0.0;
  MirageLinearToLMS(r, g, b, &l, &m, &s);
  MirageCubeRootLMSToOklab(cbrt(l), cbrt(m), cbrt(s), outL, outA, outB);
}

/// Oklab back to linear Rec.709. Unclamped: the caller is usually asking whether
/// the colour fits at all, and a clamped answer cannot be asked that question.
static inline void MirageOklabToLinear(double L, double A, double B, double *outR,
                                       double *outG, double *outB) {
  double l_ = L + 0.3963377774 * A + 0.2158037573 * B;
  double m_ = L - 0.1055613458 * A - 0.0638541728 * B;
  double s_ = L - 0.0894841775 * A - 1.2914855480 * B;
  double l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
  *outR = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
  *outG = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
  *outB = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s;
}

/// Colourfulness of an Oklab a/b pair.
static inline double MirageOklabChroma(double A, double B) { return hypot(A, B); }

/// Hue of an Oklab a/b pair in degrees, 0..360. Callers that treat a neutral as
/// having NO hue test the chroma themselves - this always returns an angle,
/// because at chroma zero the angle is arbitrary rather than wrong.
static inline double MirageOklabHueDegrees(double A, double B) {
  double h = atan2(B, A) * 180.0 / M_PI;
  return h < 0.0 ? h + 360.0 : h;
}

/// Oklab lightness, chroma and hue-degrees of a DISPLAY-ENCODED sRGB triple.
/// The decode is done here rather than by the callers, so no site can forget it:
/// decoding is the difference between the right hue and a plausible wrong one.
static inline void MirageOklabLChOfEncoded(double r, double g, double b,
                                           double *outL, double *outC,
                                           double *outHDeg) {
  double L = 0.0, A = 0.0, B = 0.0;
  MirageLinearToOklab(MirageSRGBDecode(r), MirageSRGBDecode(g),
                      MirageSRGBDecode(b), &L, &A, &B);
  if (outL)
    *outL = L;
  if (outC)
    *outC = MirageOklabChroma(A, B);
  if (outHDeg)
    *outHDeg = MirageOklabHueDegrees(A, B);
}

#endif // __METAL_VERSION__
