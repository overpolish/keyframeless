/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "GlowOSCRadiusMath.h"
#import "Constants.h"
#import <KeyframelessKit/KeyframelessKit.h>

void GlowSetTimelineSnapshot(KKTimeline *timeline) {
  KKSetProcessTimelineSnapshot(timeline);
}

void GlowSetFrameDurationSeconds(double frameDurSec) {
  KKSetProcessFrameDurationSeconds(frameDurSec);
}

static KKLane *_glowLaneForLabel(NSString *label) {
  for (KKLane *lane in KKProcessTimelineSnapshot().lanes)
    if ([lane.label isEqualToString:label])
      return lane;
  return nil;
}

NSArray<NSNumber *> *GlowOSCRadiusValuesAtFraction(double frac) {
  NSArray<NSNumber *> *def = @[ @(kGlowM1Radius), @(kGlowM1Radius) ];
  KKLane *lane = _glowLaneForLabel(@"Radius");
  if (!lane)
    return def;
  // Visual-frac variant so a Hold-only drift evaluates across the whole clip
  // (matches the Basic-view projection the mini-viewer + inspector use).
  NSArray<NSNumber *> *v =
      KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  if (v.count >= 2)
    return v;
  if (v.count == 1)
    return @[ v[0], v[0] ];
  return def;
}

BOOL GlowOSCRadiusAspectLinked(void) {
  KKLane *lane = _glowLaneForLabel(@"Radius");
  return lane ? lane.aspectLinked : YES;
}

BOOL GlowOSCLaneVisibleAtFraction(NSString *label, double frac) {
  return KKLaneVisibleAtFraction(_glowLaneForLabel(label), frac,
                                 KKProcessFrameDurationSeconds());
}
