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
