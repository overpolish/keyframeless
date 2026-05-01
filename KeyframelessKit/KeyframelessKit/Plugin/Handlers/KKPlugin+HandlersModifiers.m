/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKConstants.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation KKPlugin (HandlersModifiers)

- (void)_handleSegmentTypeToggledAtLane:(NSInteger)laneIndex
                                segment:(NSInteger)segmentIndex {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  NSInteger jsonIdx =
      KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
  if (!lanes || jsonIdx < 0) {
    [actAPI endAction:self];
    return;
  }
  KKTimingLane *lane = [lanes[jsonIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
  if ((NSUInteger)segmentIndex >= segs.count) {
    [actAPI endAction:self];
    return;
  }
  KKTimingSegment *seg = [segs[segmentIndex] copy];
  seg.type = (seg.type == KKSegmentTypeHold) ? KKSegmentTypeTransition
                                             : KKSegmentTypeHold;
  segs[segmentIndex] = seg;
  lane.segments = segs;
  lanes[jsonIdx] = lane;

  KKWriteLanesJSON(lanes, setAPI, self.apiManager);
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)_handleSegmentLockToggledAtLane:(NSInteger)laneIndex
                                segment:(NSInteger)segmentIndex
                               duration:(double)newLockedSeconds {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  NSInteger jsonIdx =
      KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
  if (!lanes || jsonIdx < 0) {
    [actAPI endAction:self];
    return;
  }
  KKTimingLane *lane = [lanes[jsonIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
  if ((NSUInteger)segmentIndex >= segs.count) {
    [actAPI endAction:self];
    return;
  }
  KKTimingSegment *seg = [segs[segmentIndex] copy];
  seg.lockedDurationSeconds = MAX(0.0, newLockedSeconds);
  segs[segmentIndex] = seg;
  lane.segments = segs;
  lanes[jsonIdx] = lane;

  KKWriteLanesJSON(lanes, setAPI, self.apiManager);
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)_handleAllLanesSegmentTypesToggledAtPosition:(double)position {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  if (!lanes) {
    [actAPI endAction:self];
    return;
  }

  NSSet<NSString *> *pluginHidden =
      [self hiddenAnimatablePropertyLabels] ?: [NSSet set];

  BOOL anyChanged = NO;
  for (NSUInteger li = 0; li < lanes.count; li++) {
    if (!lanes[li].visibleInSequencer ||
        [pluginHidden containsObject:lanes[li].propertyLabel])
      continue;
    KKTimingLane *lane = [lanes[li] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
    NSInteger hitIdx = -1;
    for (NSUInteger i = 0; i < segs.count; i++) {
      if (position >= segs[i].start && position < segs[i].end) {
        hitIdx = (NSInteger)i;
        break;
      }
    }
    if (hitIdx < 0)
      continue;
    KKTimingSegment *seg = [segs[hitIdx] copy];
    seg.type = (seg.type == KKSegmentTypeHold) ? KKSegmentTypeTransition
                                               : KKSegmentTypeHold;
    segs[hitIdx] = seg;
    lane.segments = segs;
    lanes[li] = lane;
    anyChanged = YES;
  }

  if (anyChanged) {
    KKApplyHTHNormalizationInPlace(lanes);
    NSString *updated = [KKTimingLane jsonFromLanes:lanes];
    if (updated)
      [setAPI setStringParameterValue:updated
                          toParameter:kKKParamMultiStageData];
  }
  [actAPI endAction:self];
  if (anyChanged)
    [self timingGraphApplyState];
}

- (void)_handleAllLanesSegmentLockToggledAtPosition:(double)position
                                               lock:(BOOL)lock {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  if (!lanes) {
    [actAPI endAction:self];
    return;
  }
  CMTime effectDuration = kCMTimeZero;
  if (timingAPI)
    [timingAPI durationTimeForEffect:&effectDuration];
  double durSec = CMTimeGetSeconds(effectDuration);

  NSSet<NSString *> *pluginHidden =
      [self hiddenAnimatablePropertyLabels] ?: [NSSet set];

  BOOL anyChanged = NO;
  for (NSUInteger li = 0; li < lanes.count; li++) {
    if (!lanes[li].visibleInSequencer ||
        [pluginHidden containsObject:lanes[li].propertyLabel])
      continue;
    KKTimingLane *lane = [lanes[li] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
    NSInteger hitIdx = -1;
    for (NSUInteger i = 0; i < segs.count; i++) {
      if (position >= segs[i].start && position < segs[i].end) {
        hitIdx = (NSInteger)i;
        break;
      }
    }
    if (hitIdx < 0)
      continue;
    KKTimingSegment *seg = [segs[hitIdx] copy];
    double newLocked = lock ? (seg.end - seg.start) * durSec : 0.0;
    if (fabs(seg.lockedDurationSeconds - newLocked) < 1e-6)
      continue;
    seg.lockedDurationSeconds = MAX(0.0, newLocked);
    segs[hitIdx] = seg;
    lane.segments = segs;
    lanes[li] = lane;
    anyChanged = YES;
  }

  if (anyChanged)
    KKWriteLanesJSON(lanes, setAPI, self.apiManager);
  [actAPI endAction:self];
  if (anyChanged)
    [self timingGraphApplyState];
}

- (void)_handleRulerLoopToggled:(BOOL)newState {
  // Write the param and stop. The loop-sync pump (runs on every drawOSC and
  // render tick) picks up the change and pushes it back to every ruler
  // (primary + additional). Inspector↔window sync is automatic.
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actAPI)
    return;
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setBoolValue:newState
           toParameter:kKKParamTimingLoopEnabled
                atTime:kCMTimeZero];
  [actAPI endAction:self];
}

- (void)_handleRulerPlayheadScrubToFraction:(double)fraction {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actAPI)
    return;
  [actAPI startAction:self];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  id<FxCommandAPI_v2> commandAPI =
      [self.apiManager apiForProtocol:@protocol(FxCommandAPI_v2)];
  if (timingAPI && commandAPI) {
    // Timeline in/out are the only timing-API values that return true
    // timeline time across all clip kinds. -startTimeForEffect: and
    // -startTimeOfInputToFilter: are source-relative in FCP and on still
    // images return a stock ~1h offset, so movePlayheadToTime: (which
    // expects timeline time) silently rejects the out-of-range value.
    CMTime inPoint = kCMTimeZero, outPoint = kCMTimeZero;
    [timingAPI inPointTimeOfTimelineForEffect:&inPoint];
    [timingAPI outPointTimeOfTimelineForEffect:&outPoint];
    double startSec = CMTimeGetSeconds(inPoint);
    double endSec = CMTimeGetSeconds(outPoint);
    double targetSec = startSec + fraction * (endSec - startSec);
    // Nudge half a frame inside the clip at the boundaries so the playhead
    // never lands exactly on the seam with the neighbouring clip (FCP
    // resolves t==inPoint to the previous clip's last frame).
    CMTime frameDur = kCMTimeZero;
    [timingAPI frameDuration:&frameDur];
    double half = CMTimeGetSeconds(frameDur) * 0.5;
    if (half > 0) {
      double lo = startSec + half;
      double hi = endSec - half;
      if (hi > lo)
        targetSec = MAX(lo, MIN(hi, targetSec));
    }
    CMTime targetTime = CMTimeMakeWithSeconds(targetSec, 600);
    [commandAPI movePlayheadToTime:targetTime error:nil];
  }
  [actAPI endAction:self];
}

@end
