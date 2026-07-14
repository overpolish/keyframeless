/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKScaleGizmo.h"
#import <math.h>

// Above 100% the half-extent continues as e0 + span + 2*span*(sqrt(1+x/100)-1)
// where x = percent - 100. The factor 2*span makes the sqrt's slope at x=0
// equal the linear segment's slope (span/100 per percent), so there is no kink
// at 100%. sqrt (vs log) keeps growing meaningfully at high scale, preserving
// drag resolution, while still flattening enough to stay on-screen.

double KKScaleGizmoExtentForPercent(double percent, double e0, double span) {
  if (percent <= 0.0)
    return e0;
  if (percent <= 100.0)
    return e0 + span * (percent / 100.0);
  double x = percent - 100.0;
  return e0 + span + 2.0 * span * (sqrt(1.0 + x / 100.0) - 1.0);
}

double KKScaleGizmoPercentForExtent(double extent, double e0, double span) {
  if (span <= 0.0)
    return 0.0;
  if (extent <= e0)
    return 0.0;
  if (extent <= e0 + span)
    return (extent - e0) / span * 100.0;
  // Invert the sqrt branch: w = (extent - e0 - span)/(2*span) + 1 =
  // sqrt(1+x/100)
  double w = (extent - e0 - span) / (2.0 * span) + 1.0;
  return 100.0 + 100.0 * (w * w - 1.0);
}

// Ring OSC e0/span as fractions of the surface min dimension. Wider than the
// scale box (0.12/0.057) because a normalized 0..1 value uses only the curve's
// linear branch (norm*100 caps at the 100% pivot), so a bigger span is needed
// for the 0..1 sweep to be a clearly visible ring.
static const double kKKRingOSCNormE0Frac = 0.10;
static const double kKKRingOSCNormSpanFrac = 0.34;

double KKRingOSCExtentForNorm(double norm, double minDim) {
  // `norm` is NOT clamped above 1: a value past its range (an unbounded field,
  // or one dragged beyond `max`) drives percent > 100 so the curve's sqrt
  // branch keeps the ring growing (compressed) instead of pegging at a max
  // radius.
  double pct = fmax(0.0, norm) * 100.0;
  return KKScaleGizmoExtentForPercent(pct, minDim * kKKRingOSCNormE0Frac,
                                      minDim * kKKRingOSCNormSpanFrac);
}

double KKRingOSCNormForExtent(double extent, double minDim) {
  return KKScaleGizmoPercentForExtent(extent, minDim * kKKRingOSCNormE0Frac,
                                      minDim * kKKRingOSCNormSpanFrac) /
         100.0;
}

// A normalized ring value mapped to a lane value: min + norm*(max-min), clamped
// to max only when bounded, rounded when integer-valued.
static double kkRingValueForNorm(double norm, double mn, double mx,
                                 BOOL bounded, BOOL isInt) {
  double val = mn + fmax(0.0, norm) * (mx - mn);
  if (bounded)
    val = fmin(val, mx);
  if (isInt)
    val = round(val);
  return val;
}

// Clamp/round an already-computed value (a ratio-scaled linked component).
static double kkRingClampValue(double val, double mn, double mx, BOOL bounded,
                               BOOL isInt) {
  val = fmax(val, mn);
  if (bounded)
    val = fmin(val, mx);
  if (isInt)
    val = round(val);
  return val;
}

NSArray<NSNumber *> *KKRingOSCDragValues(int fields, BOOL linked, double startX,
                                         double startY, double dragStartDx,
                                         double dragStartDy,
                                         double dragStartDist, double dx,
                                         double dy, double minDim, double mn,
                                         double mx, BOOL bounded, BOOL isInt) {
  if (fields < 2) {
    // Circle: the edge tracks the cursor's radial distance.
    double v = kkRingValueForNorm(KKRingOSCNormForExtent(hypot(dx, dy), minDim),
                                  mn, mx, bounded, isInt);
    return @[ @(v) ];
  }
  if (linked) {
    // Locked: scale BOTH components by ONE ellipse-scale factor `s` (how far
    // the cursor is relative to the start ellipse's edge in the drag
    // direction), so the ratio at press is preserved. Well-defined at every
    // grab angle - a per-axis geometric mean collapses to a circle at a
    // cardinal grab.
    double span = mx - mn;
    double rxStart =
        KKRingOSCExtentForNorm(span > 0 ? (startX - mn) / span : 0, minDim);
    double ryStart =
        KKRingOSCExtentForNorm(span > 0 ? (startY - mn) / span : 0, minDim);
    double ex = rxStart > 1e-6 ? dx / rxStart : 0;
    double ey = ryStart > 1e-6 ? dy / ryStart : 0;
    double s = sqrt(ex * ex + ey * ey);
    return @[
      @(kkRingClampValue(startX * s, mn, mx, bounded, isInt)),
      @(kkRingClampValue(startY * s, mn, mx, bounded, isInt))
    ];
  }
  // Unlinked: per-axis; an axis grabbed near its cardinal (start component
  // small vs the grab radius) is held at its press value (scale-box edge feel).
  static const double kCardinalFrac = 0.25;
  double minComp = kCardinalFrac * dragStartDist;
  double candX = kkRingValueForNorm(KKRingOSCNormForExtent(fabs(dx), minDim),
                                    mn, mx, bounded, isInt);
  double candY = kkRingValueForNorm(KKRingOSCNormForExtent(fabs(dy), minDim),
                                    mn, mx, bounded, isInt);
  double vx = (fabs(dragStartDx) > minComp) ? candX : startX;
  double vy = (fabs(dragStartDy) > minComp) ? candY : startY;
  return @[ @(vx), @(vy) ];
}

void KKScaleHandlePositions(CGPoint center, double sclX, double sclY, double e0,
                            double span, CGPoint anchorFrac, CGPoint out[8]) {
  double halfW = KKScaleGizmoExtentForPercent(sclX, e0, span);
  double halfH = KKScaleGizmoExtentForPercent(sclY, e0, span);
  // Box centre = anchor - half*frac, so the anchor (center) stays fixed as the
  // box grows: a centred anchor is symmetric, a corner anchor keeps that corner
  // put and grows the opposite one.
  double bcx = center.x - halfW * anchorFrac.x;
  double bcy = center.y - halfH * anchorFrac.y;
  double l = bcx - halfW, r = bcx + halfW;
  double b = bcy - halfH, t = bcy + halfH;
  out[0] = CGPointMake(l, b);
  out[1] = CGPointMake(r, b);
  out[2] = CGPointMake(r, t);
  out[3] = CGPointMake(l, t);
  out[4] = CGPointMake(bcx, b);
  out[5] = CGPointMake(r, bcy);
  out[6] = CGPointMake(bcx, t);
  out[7] = CGPointMake(l, bcy);
}

double KKScaleGizmoPercentForHandle(double effCoord, double centerCoord,
                                    double sign, double frac, double e0,
                                    double span) {
  double denom = fabs(sign - frac);
  if (denom < 1e-4)
    return -1.0; // handle coincides with the anchor on this axis: cannot scale
  return KKScaleGizmoPercentForExtent(fabs(effCoord - centerCoord) / denom, e0,
                                      span);
}

CGPoint KKScaleGizmoAnchorFrac(double ax, double ay, double refX, double refY,
                               double halfX, double halfY) {
  double fx = halfX > 1e-6 ? (ax - refX) / halfX : 0.0;
  double fy = halfY > 1e-6 ? (ay - refY) / halfY : 0.0;
  fx = fmax(-1.0, fmin(1.0, fx));
  fy = fmax(-1.0, fmin(1.0, fy));
  return CGPointMake(fx, fy);
}

void KKScaleValuesForHandleDrag(NSInteger h, double pX, double pY, double tX,
                                double tY, BOOL linked, double *outX,
                                double *outY) {
  BOOL haveRatio = (pX > 1e-6 && pY > 1e-6);
  double newX = pX, newY = pY;
  if (KKScaleHandleIsCorner(h)) {
    if (linked && haveRatio) {
      // Geometric mean of the two per-axis factors = one continuous scale
      // factor (no dominant-axis flip); the partner axis follows by ratio.
      double f = sqrt((tX / pX) * (tY / pY));
      newX = pX * f;
      newY = pY * f;
    } else {
      newX = tX;
      newY = tY;
    }
  } else if (KKScaleHandleControlsX(h)) {
    newX = tX;
    newY = linked ? (haveRatio ? pY * (tX / pX) : tX) : pY;
  } else if (KKScaleHandleControlsY(h)) {
    newY = tY;
    newX = linked ? (haveRatio ? pX * (tY / pY) : tY) : pX;
  }
  if (outX)
    *outX = fmax(0.0, round(newX));
  if (outY)
    *outY = fmax(0.0, round(newY));
}
