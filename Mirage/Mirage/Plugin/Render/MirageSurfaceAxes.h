/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The MATHS of the Grading surface: the response curve, the control-basis stretch
// of the unit disc, the polar and least-squares fits that derive a puck position
// back out of where the controls currently sit. What the shader is allowed to
// declare, and how it is read, is MirageSurfaceGrammar.h.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <math.h>

#import "MirageSurfaceGrammar.h" // MirageSurfaceResponse, the parsed mapping

// --- Puck response curve -------------------------------------------------
//
// A linear response wastes most of the control. `surface="y:+30"` on a 0-150 control
// means full deflection reaches 30, and the remaining 120 is simply unreachable from
// the puck - so the author has to choose between a usable feel near the centre and
// being able to reach the extremes.
//
// So the response is a cubic: the author's magnitude sets the SLOPE AT THE CENTRE,
// where small adjustments live and predictability matters, and the rim reaches the
// control's actual limit. Deflection therefore accelerates outward, which is also how
// it feels to use - fine control in the middle, full range at the edge.
//
//     delta(u) = u * magnitude + (limit - magnitude) * u^3
//
// At u=0 the slope is the author's magnitude. At |u|=1 the value is exactly the limit.
// Monotonic whenever limit >= magnitude, so it always inverts.

/// Distance from `base` to the limit the control is TRAVELLING toward. `travel` is
/// the signed movement, not the deflection: a control mapped `y:-12` moves down as
/// the puck goes up, so it is `max` that bounds the downward puck and `min` the
/// upward one. Reading the limit off the deflection instead let an inverted control
/// aim past its own range and pin before the rim.
static inline double MirageSurfaceLimitDistance(MirageSurfaceResponse r,
                                                double base, double travel) {
  if (!r.hasLimits)
    return 0.0;
  return travel >= 0.0 ? fmax(0.0, r.maxValue - base)
                       : fmax(0.0, base - r.minValue);
}

/// The control's offset from `base` for a deflection `u` in -1..1.
static inline double MirageSurfaceCurveDelta(MirageSurfaceResponse r, double base,
                                             double u, double magnitude) {
  double mag = fabs(magnitude);
  double limit =
      MirageSurfaceLimitDistance(r, base, magnitude < 0.0 ? -u : u);
  // No declared range, or a range tighter than the author's own magnitude: stay
  // linear rather than producing a curve that doubles back.
  if (limit <= mag)
    return u * magnitude;
  double sign = magnitude < 0.0 ? -1.0 : 1.0;
  return sign * (u * mag + (limit - mag) * u * u * u);
}

/// The deflection that produced `delta`. Bisected rather than solved in closed form:
/// the cubic is monotonic over -1..1 so bisection always converges, and it stays
/// correct if the curve is ever reshaped.
static inline double MirageSurfaceCurveDeflection(MirageSurfaceResponse r,
                                                  double base, double delta,
                                                  double magnitude) {
  double mag = fabs(magnitude);
  if (mag < 1e-12)
    return 0.0;
  double sign = magnitude < 0.0 ? -1.0 : 1.0;
  double target = delta * sign; // work in the response's own direction
  double lo = target >= 0.0 ? 0.0 : -1.0, hi = target >= 0.0 ? 1.0 : 0.0;
  for (int i = 0; i < 28; i++) {
    double mid = (lo + hi) * 0.5;
    double at = sign * MirageSurfaceCurveDelta(r, base, mid, magnitude);
    if (at < target)
      lo = mid;
    else
      hi = mid;
  }
  return (lo + hi) * 0.5;
}

// --- The disc and the controls' own axes ---------------------------------
//
// The puck is clamped to a unit DISC, and a cartesian control takes the puck's
// projection onto its own response direction. So at 45 degrees to a pair of
// perpendicular controls each of them only ever sees 0.707: a shader mapping Red to
// `x:-100` and Green to `y:-100` could not reach Red -100 with Green -100 from the
// puck at all, even though both sliders go there. Maximum correction depended on
// which way you dragged, which is not something a round control can communicate.
//
// So a position is STRETCHED before anything projects onto it, by exactly the
// amount that brings the STRONGEST-affected control to full deflection and no
// further:
//
//     stretch(theta) = 1 / max_i |cos(theta - theta_i)|
//
// over the response directions theta_i of the puck's OWN controls. The rim then
// means full strength in every direction, and in no direction does any control
// overshoot the range its slider has. The disc stays the thing that is drawn - the
// position handed back for display is squeezed the other way - so the handle still
// lives in the circle the user is dragging in.
//
// The stretch is in the CONTROLS' basis, not the screen's. It was first written as
// `|p| / max(|px|, |py|)`, which is this same formula for axes at exactly 0 and 90
// degrees, and it stopped being right the moment the Grade and Ranges templates
// pointed their controls at their real perceptual hue directions - 29 degrees for
// Red/Cyan, 142 for Green/Magenta. A drag to the screen diagonal reached square
// (1,1), whose projection onto the 29-degree axis is cos29 + sin29 = 1.360: 36
// percent past full deflection. The write clamped at the lane's limit, the derive
// read that clamp back as deflection 1.0, and the puck sprang visibly inward on
// release. Assuming the screen's basis is what made a rotated axis lie.
//
// Cartesian only. A polar surface's radius is a real parameter - `r:` IS the
// control's deflection - so stretching it by bearing would make the same puck
// distance read as a different saturation depending on hue.

/// The response directions of one puck's controls, as unit vectors.
///
/// Fixed capacity rather than an allocation: this is rebuilt on every drag tick and
/// every puck refresh. Parallel directions are folded together on the way in - a
/// control and its inverse constrain the same axis, and the max below cannot tell
/// them apart - so the cap is on DISTINCT axes, which no real surface approaches.
enum { kMirageSurfaceMaxAxes = 32 };

typedef struct {
  double x[kMirageSurfaceMaxAxes];
  double y[kMirageSurfaceMaxAxes];
  int count;
} MirageSurfaceAxisSet;

/// Add a control's `x:`/`y:` response as a direction. A control that does not
/// respond, and one whose direction the set already holds in either sign, are both
/// dropped.
static inline void MirageSurfaceAxisSetAdd(MirageSurfaceAxisSet *set, double rx,
                                           double ry) {
  if (!set || set->count >= kMirageSurfaceMaxAxes)
    return;
  double length = hypot(rx, ry);
  if (length < 1e-12)
    return;
  double ux = rx / length, uy = ry / length;
  for (int i = 0; i < set->count; i++) {
    if (fabs(ux * set->x[i] + uy * set->y[i]) > 1.0 - 1e-12)
      return;
  }
  set->x[set->count] = ux;
  set->y[set->count] = uy;
  set->count++;
}

/// The stretch factor for the direction `(x, y)` points in.
///
/// A puck whose controls all lie on ONE axis would ask for an infinite stretch
/// perpendicular to it, where every projection is zero anyway, so the largest
/// projection is floored. The floor is part of the function of direction, so it
/// applies identically to the squeeze and the pair still inverts exactly.
static inline double MirageSurfaceAxisStretch(MirageSurfaceAxisSet axes, double x,
                                              double y) {
  double length = hypot(x, y);
  if (axes.count <= 0 || length < 1e-12)
    return 1.0; // no axes to stretch toward, or no direction to stretch along
  double ux = x / length, uy = y / length;
  double biggest = 0.0;
  for (int i = 0; i < axes.count; i++)
    biggest = fmax(biggest, fabs(ux * axes.x[i] + uy * axes.y[i]));
  return 1.0 / fmax(biggest, 1e-3);
}

/// Stretch a point in the unit disc into the puck's control basis, in place, so the
/// control most aligned with it reaches exactly full deflection at the rim.
static inline void MirageSurfaceDiscToAxes(double *x, double *y,
                                           MirageSurfaceAxisSet axes) {
  if (!x || !y)
    return;
  double scale = MirageSurfaceAxisStretch(axes, *x, *y);
  *x *= scale;
  *y *= scale;
}

/// The exact inverse: squeeze a point in the control basis back into the disc. The
/// stretch depends only on DIRECTION, which a positive scale leaves alone, so the
/// two compose to the identity - which is what stops the puck creeping every time
/// the derive feeds a position back into the display.
static inline void MirageSurfaceAxesToDisc(double *x, double *y,
                                           MirageSurfaceAxisSet axes) {
  if (!x || !y)
    return;
  double scale = MirageSurfaceAxisStretch(axes, *x, *y);
  if (scale > 1e-12) {
    *x /= scale;
    *y /= scale;
  }
}

/// The value offset a bearing implies for an angular control. Proportional: the
/// magnitude is reached at half a turn, so `a:+180` maps the puck's bearing onto the
/// control one-for-one in degrees.
static inline double MirageSurfaceAngleDelta(MirageSurfaceResponse r,
                                            double bearingDegrees) {
  return r.a * (bearingDegrees / 180.0);
}

/// The bearing an angular control's offset implies, in degrees. Wrapped to
/// -180..180 because a bearing is a direction, not an accumulated rotation.
static inline double MirageSurfaceAngleForDelta(MirageSurfaceResponse r,
                                                double delta) {
  if (fabs(r.a) < 1e-12)
    return 0.0;
  double bearing = 180.0 * delta / r.a;
  return fmod(bearing + 540.0, 360.0) - 180.0;
}

/// Accumulator for deriving a polar puck. Radius is averaged and bearing is
/// averaged CIRCULARLY - as unit vectors - since a mean of 170 and -170 degrees is
/// 180, not zero.
typedef struct {
  double radiusSum;
  int radiusCount;
  double angleX;
  double angleY;
  int angleCount;
} MirageSurfacePolarFit;

static inline void MirageSurfacePolarAddRadius(MirageSurfacePolarFit *f,
                                               double deflection) {
  if (!f)
    return;
  f->radiusSum += deflection;
  f->radiusCount++;
}

static inline void MirageSurfacePolarAddAngle(MirageSurfacePolarFit *f,
                                              double bearingDegrees) {
  if (!f)
    return;
  double rad = bearingDegrees * M_PI / 180.0;
  f->angleX += cos(rad);
  f->angleY += sin(rad);
  f->angleCount++;
}

/// Resolve the accumulated observations into a puck position.
///
/// An axis nothing observes is UNCONSTRAINED, not zero, and the two directions fail
/// differently: with a bearing but no radial control the distance means nothing, so
/// the puck goes to the rim where its bearing is legible, and with a radius but no
/// angular control it lies along the +x axis. Neither invents a value the controls
/// do not hold - both put the puck where the one real observation can be read.
static inline BOOL MirageSurfacePolarResolve(MirageSurfacePolarFit f, double *outX,
                                            double *outY) {
  if (outX)
    *outX = 0.0;
  if (outY)
    *outY = 0.0;
  if (!f.radiusCount && !f.angleCount)
    return NO;
  double radius = f.radiusCount ? f.radiusSum / (double)f.radiusCount : 1.0;
  if (radius < 0.0)
    radius = 0.0;
  double bearing = 0.0;
  if (f.angleCount && hypot(f.angleX, f.angleY) > 1e-12)
    bearing = atan2(f.angleY, f.angleX);
  if (outX)
    *outX = radius * cos(bearing);
  if (outY)
    *outY = radius * sin(bearing);
  return YES;
}

/// One control's contribution to the derive: its response plus how far it
/// currently sits from its base (`default=`) value.
typedef struct {
  double rx;
  double ry;
  double delta;
} MirageSurfaceSample;

/// Derive the puck position that best explains where the controls currently sit.
///
/// A plain least-squares fit would let a wide-ranged control dominate: Radius in
/// pixels moving 40 would outvote a percent moving 4, and the puck would skew
/// toward whichever control happens to carry the biggest numbers. So each sample
/// is weighted by the inverse of its response magnitude, which puts every control
/// into the same "fraction of full deflection" currency before fitting.
///
/// Returns NO when nothing can be derived. An axis no control responds to is
/// mathematically unconstrained rather than zero, so it reports 0 and the caller
/// should present a single slider instead of a circle with a dead direction.
static inline BOOL MirageSurfaceDerivePuck(const MirageSurfaceSample *samples,
                                           int count, double *outX,
                                           double *outY) {
  if (outX)
    *outX = 0.0;
  if (outY)
    *outY = 0.0;
  if (!samples || count <= 0)
    return NO;
  double sxx = 0.0, sxy = 0.0, syy = 0.0, sxb = 0.0, syb = 0.0;
  BOOL any = NO;
  for (int i = 0; i < count; i++) {
    double rx = samples[i].rx, ry = samples[i].ry;
    double mag = hypot(rx, ry);
    if (mag < 1e-12)
      continue; // a control that doesn't respond says nothing about the puck
    double w = 1.0 / mag;
    double ax = rx * w, ay = ry * w, b = samples[i].delta * w;
    sxx += ax * ax;
    sxy += ax * ay;
    syy += ay * ay;
    sxb += ax * b;
    syb += ay * b;
    any = YES;
  }
  if (!any)
    return NO;
  // Solve the 2x2 normal equations, falling back to a single axis when the other
  // carries no response at all (every control mapped to one direction).
  double det = sxx * syy - sxy * sxy;
  if (fabs(det) > 1e-12) {
    if (outX)
      *outX = (sxb * syy - syb * sxy) / det;
    if (outY)
      *outY = (syb * sxx - sxb * sxy) / det;
    return YES;
  }
  if (sxx > 1e-12 && outX)
    *outX = sxb / sxx;
  if (syy > 1e-12 && outY)
    *outY = syb / syy;
  return YES;
}

#endif
