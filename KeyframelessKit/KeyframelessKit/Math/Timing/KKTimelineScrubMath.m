/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineScrubMath.h"

#import <math.h>

// Ruler strip geometry shared by both timeline views - kept private to this
// helper. If either view ever needs a different ruler height, take the
// trackTopY argument as already-band-bottom instead.
static const CGFloat kScrubRulerH = 13.0;
static const CGFloat kScrubRulerGap = 3.0;
static const CGFloat kScrubBandSlop = 2.0;

BOOL KKTimelineScrubBandContainsPoint(NSPoint pt, CGFloat trackMinX,
                                      CGFloat trackMaxX, CGFloat trackTopY) {
  if (trackMaxX <= trackMinX)
    return NO;
  CGFloat bandTop = trackTopY + kScrubRulerGap + kScrubRulerH + kScrubBandSlop;
  return pt.x >= trackMinX && pt.x <= trackMaxX && pt.y >= trackTopY &&
         pt.y <= bandTop;
}

double KKTimelineScrubFracDelivered(double visualFrac,
                                    double clipDurationSeconds,
                                    double frameDurationSeconds) {
  if (clipDurationSeconds <= 0.0 || frameDurationSeconds <= 0.0 ||
      frameDurationSeconds >= clipDurationSeconds)
    return visualFrac;
  double maxFrac =
      (clipDurationSeconds - frameDurationSeconds) / clipDurationSeconds;
  return visualFrac > maxFrac ? maxFrac : visualFrac;
}

double KKSnapFracToFrame(double frac, double clipDurationSeconds,
                         double frameDurationSeconds) {
  if (clipDurationSeconds <= 0.0 || frameDurationSeconds <= 0.0 ||
      frameDurationSeconds >= clipDurationSeconds)
    return frac;
  double frameFrac = frameDurationSeconds / clipDurationSeconds;
  double snapped = round(frac / frameFrac) * frameFrac;
  double maxFrac =
      (clipDurationSeconds - frameDurationSeconds) / clipDurationSeconds;
  if (snapped < 0.0)
    snapped = 0.0;
  if (snapped > maxFrac)
    snapped = maxFrac;
  return snapped;
}

double KKTimelineSnapFracInPixels(CGFloat x, double rawFrac,
                                  NSArray<NSNumber *> *candidateFracs,
                                  CGFloat (^xForFrac)(double frac),
                                  CGFloat pixelTolerance,
                                  double *_Nullable outSnapFrac) {
  double bestFrac = rawFrac;
  CGFloat bestDist = pixelTolerance;
  double bestSnap = NAN;
  for (NSNumber *cn in candidateFracs) {
    double c = cn.doubleValue;
    CGFloat cx = xForFrac(c);
    CGFloat d = fabs(x - cx);
    if (d < bestDist) {
      bestDist = d;
      bestFrac = c;
      bestSnap = c;
    }
  }
  if (outSnapFrac)
    *outSnapFrac = bestSnap;
  return bestFrac;
}
