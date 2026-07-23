/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "GlowOSCRadiusMath.h"
#import "Constants.h"
#import <KeyframelessKit/KeyframelessKit.h>
#import <math.h>

// e0/span as fractions of the canvas min dimension - the same proportions the
// MagicMove scale gizmo uses (see kScaleGizmoE0Frac / kScaleGizmoSpanFrac), so
// the radius ring shares the scale box's minimum size at 0 and growth feel.
static const double kGlowRingE0Frac = 0.12;
static const double kGlowRingSpanFrac = 0.057;

double GlowOSCRingExtentForRadius(double radiusPx, double minDim) {
  return KKScaleGizmoExtentForPercent(fmax(0.0, radiusPx),
                                      minDim * kGlowRingE0Frac,
                                      minDim * kGlowRingSpanFrac);
}

double GlowOSCRadiusForRingExtent(double extent, double minDim) {
  return KKScaleGizmoPercentForExtent(extent, minDim * kGlowRingE0Frac,
                                      minDim * kGlowRingSpanFrac);
}

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
