/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../Views/StageSequencer/KKStagePlayheadView.h"
#import "../../Views/StageSequencer/KKStageSequencerRulerView.h"
#import "../../Views/StageSequencer/KKStageSequencerView.h"
#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation KKPlugin (MultiStageInstance)

- (void)multiStageRefreshLaneVisibility {
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (!state)
    return;
  NSSet<NSString *> *pluginHidden =
      [self hiddenAnimatablePropertyLabels] ?: [NSSet set];
  NSArray<KKTimingLane *> *lanes = state.lanesSnapshot;
  NSSet<NSString *> *next = KKEffectiveHiddenLaneLabels(pluginHidden, lanes);
  BOOL effectiveSame =
      ([next isEqualToSet:state.hiddenLaneLabels ?: [NSSet set]] ||
       (!next && !state.hiddenLaneLabels));
  state.hiddenLaneLabels = next;
  state.pluginHiddenLaneLabels = pluginHidden;
  KKStageSequencerView *seq = state.sequencerView;
  NSArray<KKTimingViewRefs *> *extras =
      [state.additionalTimingViews copy] ?: @[];
  // Always re-push the pill bar — its filter is plugin-hidden only, which
  // can change (e.g. Glow color-mode swap) even when the effective set is
  // unchanged because user-hidden lanes are different too.
  KKPushLanesToVisibilityBar(state.visibilityBar, lanes, pluginHidden);
  for (KKTimingViewRefs *r in extras)
    KKPushLanesToVisibilityBar(r.visibilityBar, lanes, pluginHidden);
  if (effectiveSame)
    return;
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

  KKPluginInstanceState *state = KKInstanceStateEnsureForAPI(self.apiManager);

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

  state.sequencerView = view;
  state.rulerView = ruler;
  state.playheadView = playhead;
  state.cachedEffectStart = CMTimeGetSeconds(cachedStart);
  state.cachedEffectDuration = CMTimeGetSeconds(cachedDur);
}

@end
