/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKConstants.h>
#import <KeyframelessKit/KKTimingStage.h>

void KKWriteLanesJSON(NSArray<KKTimingLane *> *lanes,
                      id<FxParameterSettingAPI_v5> setAPI,
                      id<PROAPIAccessing> apiManager) {
  NSMutableArray<KKTimingLane *> *mutableLanes = [lanes mutableCopy];
  KKApplyHTHNormalizationInPlace(mutableLanes);
  NSString *updated = [KKTimingLane jsonFromLanes:mutableLanes];
  if (updated)
    [setAPI setStringParameterValue:updated toParameter:kKKParamMultiStageData];
  if (apiManager) {
    KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
    if (state) {
      state.lanesSnapshot = [mutableLanes copy];
      state.lanesEverPersisted = YES;
    }
  }
}
