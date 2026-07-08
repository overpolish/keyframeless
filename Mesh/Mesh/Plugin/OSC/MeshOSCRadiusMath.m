/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MeshOSCRadiusMath.h"
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

// OSC ticks resolve the timeline via the framework's process-snapshot store.
// Set from the plugin's parameterChanged: + cold-boot seed in createView:.
void MeshSetTimelineSnapshot(KKTimeline *timeline) {
  KKSetProcessTimelineSnapshot(timeline);
}

KKTimeline *MeshTimelineSnapshot(void) {
  return KKProcessTimelineSnapshot();
}

static KKLane *_laneForLabel(NSString *label) {
  for (KKLane *lane in KKProcessTimelineSnapshot().lanes)
    if ([lane.label isEqualToString:label])
      return lane;
  return nil;
}

NSArray<NSNumber *> *
MeshSnapshotValuesForLabel(NSString *label, double frac,
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

double MeshSnapshotRadiusAtFraction(double frac) {
  NSArray<NSNumber *> *vals =
      MeshSnapshotValuesForLabel(@"Radius", frac, @[ @20.0 ]);
  return vals.firstObject.doubleValue;
}

void MeshSetFrameDurationSeconds(double frameDurSec) {
  KKSetProcessFrameDurationSeconds(frameDurSec);
}

BOOL MeshLaneVisibleAtFraction(NSString *label, double frac) {
  return KKLaneVisibleAtFraction(_laneForLabel(label), frac,
                                 KKProcessFrameDurationSeconds());
}
