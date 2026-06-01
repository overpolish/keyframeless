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
