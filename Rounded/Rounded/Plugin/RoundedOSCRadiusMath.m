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

double radiusFromBlobAtFraction(id<PROAPIAccessing> apiManager, double frac) {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return 20.0;
  NSString *json = KKReadCustomParamString(paramGetAPI, kKKParamTimelineData);
  if (!json.length)
    return 20.0;
  KKTimeline *tl = [KKTimeline timelineFromJSON:json];
  for (KKLane *lane in tl.lanes) {
    // `enabled` == animatable; a constant lane still supplies its value.
    if ([lane.label isEqualToString:@"Radius"]) {
      NSArray<NSNumber *> *vals = KKTimelineLaneValueAtFraction(lane, frac);
      return vals.count > 0 ? vals[0].doubleValue : 20.0;
    }
  }
  return 20.0;
}
