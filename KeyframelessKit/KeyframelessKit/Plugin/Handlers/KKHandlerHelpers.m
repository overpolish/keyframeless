/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../../Views/KKAnimatableProperty.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKConstants.h>
#import <KeyframelessKit/KKTimingStage.h>

void KKWriteLanesJSON(
    NSArray<KKTimingLane *> *lanes, id<FxParameterSettingAPI_v5> setAPI,
    NSDictionary<NSString *, NSArray<NSNumber *> *> *kindsByLabel) {
  NSMutableArray<KKTimingLane *> *mutableLanes = [lanes mutableCopy];
  KKApplyHTHNormalizationInPlace(mutableLanes, kindsByLabel);
  NSString *updated = [KKTimingLane jsonFromLanes:mutableLanes];
  if (updated)
    [setAPI setStringParameterValue:updated toParameter:kKKParamMultiStageData];
}

KKAnimatableProperty *KKPropertyByLabel(NSArray<KKAnimatableProperty *> *props,
                                        NSString *label) {
  for (KKAnimatableProperty *p in props) {
    if ([p.label isEqualToString:label])
      return p;
  }
  return nil;
}
