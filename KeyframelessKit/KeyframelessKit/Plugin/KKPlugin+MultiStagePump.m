/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/// Multi-stage live-update pump. Drives sequencer view updates from two
/// callback sources: `drawOSC` (authoritative when an effect is OSC-selected)
/// and `renderDestinationImage:` (fallback when an unrelated plugin has OSC
/// focus). Coordinates via recency gates to avoid flicker caused by FCP's
/// warm-up renders during slider drags.
///
/// See project_fxplug_custom_view_live_update.md for the full architecture.

#import "../Math/KKTimingStage.h"
#import "../Views/KKStagePlayheadView.h"
#import "../Views/KKStageSequencerRulerView.h"
#import "../Views/KKStageSequencerView.h"
#import "KKConstants.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <QuartzCore/QuartzCore.h>

/// Timestamp of the most recent drawOSC-sourced playhead pump. Used to
/// suppress render-sourced pumps while drawOSC is active.
static NSTimeInterval sLastDrawOSCPumpTime = 0;

/// Timestamp of the most recent `parameterChanged:` on any plugin instance.
/// Suppresses render-sourced playhead pumps briefly afterwards: FCP triggers
/// warm-up renders at renderTime=0 in the wake of param changes.
static NSTimeInterval sLastParameterChangedTime = 0;

/// Window (seconds) for which a recent drawOSC/parameterChanged suppresses
/// render-sourced playhead updates. Long enough to span FCP's warm-up render
/// burst, short enough that render takes over promptly when the user stops
/// dragging.
static const NSTimeInterval kRenderSuppressionWindow = 0.2;

void KKMultiStageMarkParameterChanged(void) {
  sLastParameterChangedTime = CACurrentMediaTime();
}

NSArray<KKTimingLane *> *
KKFilterLanesForVisibility(NSArray<KKTimingLane *> *lanes,
                           NSSet<NSString *> *hidden) {
  if (!hidden.count || !lanes.count)
    return lanes;
  NSMutableArray<KKTimingLane *> *filtered =
      [NSMutableArray arrayWithCapacity:lanes.count];
  for (KKTimingLane *lane in lanes)
    if (![hidden containsObject:lane.propertyLabel])
      [filtered addObject:lane];
  return [filtered copy];
}

static void KKFlushPendingLanes(void) {
  // Broadcast: any running callback flushes pending lanes for every live
  // instance, not just its own. FCP only runs `drawOSC` for the OSC-selected
  // effect, but the inspector may show multiple effects' sequencer views at
  // once — each needs live updates when its slider moves.
  for (KKPluginInstanceState *state in KKAllInstanceStates()) {
    NSArray<KKTimingLane *> *pending = state.pendingLanes;
    if (!pending)
      continue;
    state.pendingLanes = nil;
    KKStageSequencerView *seq = state.sequencerView;
    NSArray<KKTimingViewRefs *> *extras =
        [state.additionalTimingViews copy] ?: @[];
    if (!seq && extras.count == 0)
      continue;
    NSArray<KKTimingLane *> *visible =
        KKFilterLanesForVisibility(pending, state.hiddenLaneLabels);
    dispatch_async(dispatch_get_main_queue(), ^{
      seq.lanes = visible;
      for (KKTimingViewRefs *r in extras)
        r.seqView.lanes = visible;
    });
  }
}

static void KKSyncFromParams(id<PROAPIAccessing> apiManager) {
  KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
  KKStageSequencerView *seq = state.sequencerView;
  NSArray<KKTimingViewRefs *> *extras =
      [state.additionalTimingViews copy] ?: @[];
  if (!seq && extras.count == 0)
    return;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return;
  NSString *json = nil;
  [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
  if (!json)
    return;
  NSString *snapshotJSON = [KKTimingLane jsonFromLanes:state.lanesSnapshot];
  if ([json isEqualToString:snapshotJSON ?: @""])
    return;
  NSArray<KKTimingLane *> *lanes = [KKTimingLane lanesFromJSON:json];
  if (!lanes)
    return;
  state.lanesSnapshot = lanes;
  state.pendingLanes = nil;
  NSArray<KKTimingLane *> *visible =
      KKFilterLanesForVisibility(lanes, state.hiddenLaneLabels);
  dispatch_async(dispatch_get_main_queue(), ^{
    seq.lanes = visible;
    for (KKTimingViewRefs *r in extras)
      r.seqView.lanes = visible;
  });
}

/// Refresh the calling instance's cached effectStart/effectDuration. Cross-
/// instance `FxTimingAPI_v4` queries return nil (and wrapping in a fresh
/// `startAction:/endAction:` inside drawOSC recurses and crashes Motion), so
/// we can only refresh the instance whose callback is currently running.
/// Non-active instances use their cache populated at custom-UI creation time.
static void KKRefreshActiveTiming(id<PROAPIAccessing> apiManager) {
  id<FxTimingAPI_v4> timingAPI =
      [apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!timingAPI)
    return;
  KKPluginInstanceState *activeState = KKInstanceStateForAPI(apiManager);
  if (!activeState)
    return;
  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];
  activeState.cachedEffectStart = CMTimeGetSeconds(effectStart);
  activeState.cachedEffectDuration = CMTimeGetSeconds(effectDuration);
}

/// Compute each live instance's playhead fraction from its cached timing
/// and dispatch view updates on the main queue. Coalesces repeat pumps at
/// the same fraction so slider drags (which trigger repeated renders at a
/// static playback time) don't thrash the view.
static void KKBroadcastPlayheads(double nowSec) {
  for (KKPluginInstanceState *state in KKAllInstanceStates()) {
    KKStageSequencerView *seq = state.sequencerView;
    if (!seq && state.additionalTimingViews.count == 0)
      continue;
    double durSec = state.cachedEffectDuration;
    if (durSec <= 0)
      continue;
    double frac = (nowSec - state.cachedEffectStart) / durSec;

    if (fabs(frac - state.pendingPlayheadFraction) < 0.0001 &&
        fabs(durSec - state.pendingPlayheadDuration) < 0.001)
      continue;

    state.pendingPlayheadFraction = frac;
    state.pendingPlayheadDuration = durSec;
    if (state.playheadDispatchPending)
      continue;
    state.playheadDispatchPending = YES;
    KKStageSequencerRulerView *ruler = state.rulerView;
    KKStagePlayheadView *ph = state.playheadView;
    NSArray<KKTimingViewRefs *> *extras =
        [state.additionalTimingViews copy] ?: @[];
    dispatch_async(dispatch_get_main_queue(), ^{
      state.playheadDispatchPending = NO;
      seq.effectDuration = state.pendingPlayheadDuration;
      seq.playheadFraction = state.pendingPlayheadFraction;
      ruler.effectDuration = state.pendingPlayheadDuration;
      ph.playheadFraction = state.pendingPlayheadFraction;
      for (KKTimingViewRefs *r in extras) {
        r.seqView.effectDuration = state.pendingPlayheadDuration;
        r.seqView.playheadFraction = state.pendingPlayheadFraction;
        r.ruler.effectDuration = state.pendingPlayheadDuration;
        r.playhead.playheadFraction = state.pendingPlayheadFraction;
      }
    });
  }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (MultiStagePump)

+ (void)multiStageDrawOSCTickForAPI:(id<PROAPIAccessing>)apiManager
                             atTime:(CMTime)time {
  KKFlushPendingLanes();
  KKSyncFromParams(apiManager);
  [self multiStageUpdatePlayheadsForAPI:apiManager atTime:time];
}

+ (void)multiStageRenderTickForAPI:(id<PROAPIAccessing>)apiManager
                            atTime:(CMTime)renderTime {
  // `renderTime` is filter-input time (effect-local) whereas the pump expects
  // timeline time. Convert first, otherwise playhead fractions are wrong.
  CMTime pumpTime = renderTime;
  id<FxTimingAPI_v4> timingAPI =
      [apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (timingAPI)
    [timingAPI timelineTime:&pumpTime fromInputTime:renderTime];

  KKFlushPendingLanes();
  [self multiStageUpdatePlayheadsFromRenderForAPI:apiManager atTime:pumpTime];
}

+ (void)multiStageFlushPendingLanes {
  KKFlushPendingLanes();
}

+ (void)multiStageSyncFromParams:(id<PROAPIAccessing>)apiManager {
  KKSyncFromParams(apiManager);
}

+ (void)multiStageUpdatePlayheadsForAPI:(id<PROAPIAccessing>)apiManager
                                 atTime:(CMTime)time {
  sLastDrawOSCPumpTime = CACurrentMediaTime();
  KKRefreshActiveTiming(apiManager);
  KKBroadcastPlayheads(CMTimeGetSeconds(time));
}

+ (void)multiStageUpdatePlayheadsFromRenderForAPI:
            (id<PROAPIAccessing>)apiManager
                                           atTime:(CMTime)time {
  // drawOSC is authoritative when running; recent parameterChanged means
  // warm-up renders are imminent. Either gate closed → skip to avoid
  // flickering the playhead to frame 0.
  NSTimeInterval now = CACurrentMediaTime();
  if (now - sLastDrawOSCPumpTime < kRenderSuppressionWindow)
    return;
  if (now - sLastParameterChangedTime < kRenderSuppressionWindow)
    return;
  KKRefreshActiveTiming(apiManager);
  KKBroadcastPlayheads(CMTimeGetSeconds(time));
}

- (void)multiStageRefreshLaneVisibility {
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (!state)
    return;
  NSSet<NSString *> *next =
      [self hiddenAnimatablePropertyLabels] ?: [NSSet set];
  if ([next isEqualToSet:state.hiddenLaneLabels ?: [NSSet set]])
    return;
  state.hiddenLaneLabels = next;
  NSArray<KKTimingLane *> *lanes = state.lanesSnapshot;
  KKStageSequencerView *seq = state.sequencerView;
  NSArray<KKTimingViewRefs *> *extras =
      [state.additionalTimingViews copy] ?: @[];
  if (!lanes.count || (!seq && extras.count == 0))
    return;
  NSArray<KKTimingLane *> *visible = KKFilterLanesForVisibility(lanes, next);
  dispatch_async(dispatch_get_main_queue(), ^{
    seq.lanes = visible;
    for (KKTimingViewRefs *r in extras)
      r.seqView.lanes = visible;
  });
}

- (void)_registerMultiStageSequencerView:(KKStageSequencerView *)view
                               rulerView:(KKStageSequencerRulerView *)ruler
                            playheadView:(KKStagePlayheadView *)playhead {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];

  NSString *uuid = KKInstanceUUIDForAPI(self.apiManager);
  if (!uuid.length) {
    uuid = [[NSUUID UUID] UUIDString];
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setStringParameterValue:uuid toParameter:kKKParamInstanceID];
    // Re-read via helper so it caches on the api manager.
    uuid = KKInstanceUUIDForAPI(self.apiManager);
  }

  // Cache timing while still in action scope — FxTimingAPI is only reliably
  // queryable here. The playhead pump reads this cache for non-active
  // instances since their apiManager can't answer FxTimingAPI from outside
  // their own callback context.
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  CMTime cachedStart = kCMTimeZero, cachedDur = kCMTimeZero;
  if (timingAPI) {
    [timingAPI startTimeForEffect:&cachedStart];
    [timingAPI durationTimeForEffect:&cachedDur];
  }
  [actAPI endAction:self];

  KKPluginInstanceState *state = KKInstanceStateForUUID(uuid);
  state.sequencerView = view;
  state.rulerView = ruler;
  state.playheadView = playhead;
  state.cachedEffectStart = CMTimeGetSeconds(cachedStart);
  state.cachedEffectDuration = CMTimeGetSeconds(cachedDur);
}

@end
#pragma clang diagnostic pop
