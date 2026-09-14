/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineScale.h"

// Warp time constant. Smaller τ = more boost to short segments / more hold
// compression. Shared so Basic and Advanced warp identically.
static const double kKKWarpTau = 0.05; // seconds

NSString *KKTimelineScaleTimecode(double seconds) {
  int totalSec = (int)seconds;
  int m = totalSec / 60;
  int s = totalSec % 60;
  double frac = seconds - totalSec;
  if (frac > 0.001 && seconds < 60)
    return [NSString stringWithFormat:@"%d.%ds", s, (int)(frac * 10)];
  if (m > 0)
    return [NSString stringWithFormat:@"%d:%02d", m, s];
  return [NSString stringWithFormat:@"%ds", s];
}

double KKTimelineScaleTickInterval(CGFloat pixelsPerSecond,
                                   CGFloat minSpacing) {
  static const double candidates[] = {0.1,  0.25, 0.5,  1.0,  2.0,   5.0,
                                      10.0, 15.0, 30.0, 60.0, 120.0, 300.0};
  static const int count = sizeof(candidates) / sizeof(candidates[0]);
  for (int i = 0; i < count; i++)
    if (candidates[i] * pixelsPerSecond >= minSpacing)
      return candidates[i];
  return candidates[count - 1];
}

double KKTimelineScaleLogWeight(double frac, double clipDur) {
  double secs = frac * (clipDur > 0.0 ? clipDur : 1.0);
  if (secs <= 0.0)
    return 0.0;
  return log(1.0 + secs / kKKWarpTau);
}

CGFloat KKTimelineScaleUToX(double u, NSRect g, double zoom, double pan) {
  double z = zoom > 0.0 ? zoom : 1.0;
  return NSMinX(g) + (u - pan) * z * NSWidth(g);
}

double KKTimelineScaleXToU(CGFloat x, NSRect g, double zoom, double pan) {
  double z = zoom > 0.0 ? zoom : 1.0;
  double w = NSWidth(g) > 0.0 ? NSWidth(g) : 1.0;
  return pan + (x - NSMinX(g)) / (z * w);
}

double KKTimelineScaleClampPan(double pan, double zoom) {
  double span = 1.0 / (zoom > 0.0 ? zoom : 1.0);
  return MAX(0.0, MIN(1.0 - span, pan));
}
