/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "RoundedOSCRadiusMath.h"
#import <KeyframelessKit/KeyframelessKit.h>

float paddingForRadius(double radius, float minDim) {
  float t = radius / 100.0f;
  float power = 5.0f * (1.0f - t) + 2.0f * t;
  float cornerRadiusPixels = minDim * 0.5f * t;
  float circleInsetFactor = 1.0f - 1.0f / sqrtf(2.0f);
  float squircleInsetFactor = 1.0f - 1.0f / powf(2.0f, 1.0f / power);
  float insetFactor = squircleInsetFactor * (1.0f - t) + circleInsetFactor * t;
  float squircleCorrection = 1.0f - 0.22f * sinf(t * M_PI);
  return minDim * 0.05f + cornerRadiusPixels * insetFactor * squircleCorrection;
}

// Single-instance assumption (PLAN §"OSC cache"). Retained on assignment.
// Reads on drawOSC tick / hit-test are pointer-atomic; no torn reads possible.
static KKTimeline *sTimelineSnapshot = nil;

void RoundedSetTimelineSnapshot(KKTimeline *timeline) {
  // MRR: retain new before releasing old.
  KKTimeline *prev = sTimelineSnapshot;
  sTimelineSnapshot = [timeline retain];
  [prev release];
}

KKTimeline *RoundedTimelineSnapshot(void) { return sTimelineSnapshot; }

static KKLane *_laneForLabel(NSString *label) {
  KKTimeline *tl = sTimelineSnapshot;
  for (KKLane *lane in tl.lanes)
    if ([lane.label isEqualToString:label])
      return lane;
  return nil;
}

NSArray<NSNumber *> *
RoundedSnapshotValuesForLabel(NSString *label, double frac,
                              NSArray<NSNumber *> *defaultValues) {
  KKLane *lane = _laneForLabel(label);
  if (!lane)
    return defaultValues;
  // Visual-frac variant so a Hold-only drift evaluates across the entire
  // clip (matches Basic-view projection: Hold-start at visual t=0 when In
  // off, Hold-end at visual t=1 when Out off).
  NSArray<NSNumber *> *vals =
      KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  return vals.count > 0 ? vals : defaultValues;
}

double RoundedSnapshotRadiusAtFraction(double frac) {
  NSArray<NSNumber *> *vals =
      RoundedSnapshotValuesForLabel(@"Radius", frac, @[ @20.0 ]);
  return vals.firstObject.doubleValue;
}

// Frame-aware snap tolerance. FCP's playhead is frame-quantized, so the
// readback frac is up to one frame off the keypose's stored time. We
// compute eps as ~1 frame in fraction units: frameDurSec / clipDurSec.
// Pushed in from the plugin render path (FxTimingAPI is unavailable here).
static double sFrameDurSec = 1.0 / 60.0;

void RoundedSetFrameDurationSeconds(double frameDurSec) {
  if (frameDurSec > 0.0)
    sFrameDurSec = frameDurSec;
}

BOOL RoundedLaneVisibleAtFraction(NSString *label, double frac) {
  return KKLaneVisibleAtFraction(_laneForLabel(label), frac, sFrameDurSec);
}
