/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/// Shared timing-lane utilities used by the multi-stage pump, the
/// stage-sequencer callbacks, and the custom-view state-apply path.
/// Declared in KKPlugin_Private.h.

#import "../Math/KKTimingStage.h"
#import "KKConstants.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

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

double KKCurrentEffectDurationSeconds(id<PROAPIAccessing> apiManager) {
  id<FxTimingAPI_v4> timingAPI =
      [apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!timingAPI)
    return 0;
  CMTime dur = kCMTimeZero;
  [timingAPI durationTimeForEffect:&dur];
  return CMTimeGetSeconds(dur);
}

NSMutableArray<KKTimingLane *> *
KKReadLanesRebalanced(id<PROAPIAccessing> apiManager,
                      id<FxParameterRetrievalAPI_v6> getAPI) {
  NSString *json = nil;
  [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
  NSArray<KKTimingLane *> *raw = [KKTimingLane lanesFromJSON:json];
  if (!raw) {
    // Param read failed (FxPlug XPC scope often isn't wired in custom-view
    // callbacks even inside startAction/endAction). Fall back to the
    // last-known in-memory snapshot so click handlers and the pump can
    // keep operating on the same data the sequencer is displaying.
    KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
    if (state.lanesSnapshot.count > 0)
      raw = state.lanesSnapshot;
    else
      return nil;
  }
  double dur = KKCurrentEffectDurationSeconds(apiManager);
  NSArray<KKTimingLane *> *balanced =
      (dur > 0) ? KKTimingRebalancedLanes(raw, dur) : raw;
  return [balanced mutableCopy];
}

NSInteger KKLaneJSONIndexForViewIndex(NSInteger viewIndex,
                                      NSArray<KKTimingLane *> *jsonLanes,
                                      NSSet<NSString *> *hidden) {
  if (viewIndex < 0)
    return -1;
  if (!hidden.count)
    return viewIndex < (NSInteger)jsonLanes.count ? viewIndex : -1;
  NSInteger seen = 0;
  for (NSInteger i = 0; i < (NSInteger)jsonLanes.count; i++) {
    if ([hidden containsObject:jsonLanes[i].propertyLabel])
      continue;
    if (seen == viewIndex)
      return i;
    seen++;
  }
  return -1;
}
