/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../Math/KKTimingEvaluation.h"
#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

/// Stamps the "recent parameter change" timestamp used by the multi-stage
/// pump to suppress render-sourced playhead updates in the wake of a slider
/// drag. Defined in KKPlugin+MultiStagePump.m.
extern void KKMultiStageMarkParameterChanged(void);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (MultiStage)

- (KKTimingSegment *)
    multiStageActiveSegmentForLabel:(NSString *)label
                             atTime:(CMTime)time
                           segments:(NSArray<KKTimingSegment *> **)outSegments
                             localT:(double *)outLocalT {
  if (outSegments)
    *outSegments = nil;
  if (outLocalT)
    *outLocalT = 0;

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!paramGetAPI || !timingAPI || !label.length)
    return nil;

  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  if (!lanes.count)
    return nil;

  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];
  double startSec = CMTimeGetSeconds(effectStart);
  double durSec = CMTimeGetSeconds(effectDuration);
  double nowSec = CMTimeGetSeconds(time);
  double frac = (durSec > 0) ? (nowSec - startSec) / durSec : 0.0;
  frac = MAX(0.0, MIN(1.0, frac));

  for (KKTimingLane *lane in lanes) {
    if (![lane.propertyLabel isEqualToString:label])
      continue;
    if (!lane.enabled || !lane.segments.count)
      return nil;
    KKTimingSegment *active = KKTimingSegmentForFraction(lane.segments, frac);
    if (!active)
      return nil;
    if (outSegments)
      *outSegments = lane.segments;
    if (outLocalT) {
      double segDur = active.end - active.start;
      double t = (segDur > 0) ? (frac - active.start) / segDur : 0.0;
      *outLocalT = MAX(0.0, MIN(1.0, t));
    }
    return active;
  }
  return nil;
}

- (BOOL)multiStageAnyLaneInTransitionAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!paramGetAPI || !timingAPI)
    return NO;

  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  if (!lanes.count)
    return NO;

  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];
  double startSec = CMTimeGetSeconds(effectStart);
  double durSec = CMTimeGetSeconds(effectDuration);
  double nowSec = CMTimeGetSeconds(time);
  double frac = (durSec > 0) ? (nowSec - startSec) / durSec : 0.0;
  frac = MAX(0.0, MIN(1.0, frac));

  for (KKTimingLane *lane in lanes) {
    if (!lane.enabled || !lane.segments.count)
      continue;
    KKTimingSegment *active = KKTimingSegmentForFraction(lane.segments, frac);
    if (active && active.type == KKSegmentTypeTransition)
      return YES;
  }
  return NO;
}

@end

#pragma clang diagnostic pop
