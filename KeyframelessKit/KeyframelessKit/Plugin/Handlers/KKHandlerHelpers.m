/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../Views/KKAnimatableProperty.h"
#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKConstants.h>
#import <KeyframelessKit/KKTimingStage.h>

void KKWriteLanesJSON(
    NSArray<KKTimingLane *> *lanes, id<FxParameterSettingAPI_v5> setAPI,
    id<PROAPIAccessing> apiManager,
    NSDictionary<NSString *, NSArray<NSNumber *> *> *kindsByLabel) {
  NSMutableArray<KKTimingLane *> *mutableLanes = [lanes mutableCopy];
  KKApplyHTHNormalizationInPlace(mutableLanes, kindsByLabel);
  NSString *updated = [KKTimingLane jsonFromLanes:mutableLanes];
  if (updated)
    [setAPI setStringParameterValue:updated toParameter:kKKParamMultiStageData];
  // Keep the in-memory snapshot consistent with what we just wrote so that
  // a follow-up read which hits the snapshot fallback (XPC scope not yet
  // synced) still sees the user's edit. Also flag that this instance has
  // persisted lanes — `timingGraphApplyState`'s "fresh instance" branch
  // checks this to avoid clobbering the edit with rebuilt defaults when
  // the param probe transiently returns nil right after a write.
  if (apiManager) {
    KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
    if (state) {
      state.lanesSnapshot = [mutableLanes copy];
      state.lanesEverPersisted = YES;
    }
  }
}

KKAnimatableProperty *KKPropertyByLabel(NSArray<KKAnimatableProperty *> *props,
                                        NSString *label) {
  for (KKAnimatableProperty *p in props) {
    if ([p.label isEqualToString:label])
      return p;
  }
  return nil;
}
