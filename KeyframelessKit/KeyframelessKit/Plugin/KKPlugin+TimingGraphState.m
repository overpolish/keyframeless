/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../KKLog.h"
#import "../Math/KKEasing.h"
#import "../Math/KKTimingStage.h"
#import "../Views/KKAnimatableProperty.h"
#import "../Views/StageSequencer/KKStagePlayheadView.h"
#import "../Views/StageSequencer/KKStageSequencerRulerView.h"
#import "../Views/StageSequencer/KKStageSequencerView.h"
#import "KKConstants.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (TimingGraphState)

static void KKApplySequencerState(KKPlugin *plugin, KKStageSequencerView *seq,
                                  NSView *seqContainer,
                                  KKStageSequencerRulerView *ruler,
                                  KKStagePlayheadView *playhead,
                                  NSArray<KKTimingLane *> *lanes, double durSec,
                                  double frac, BOOL hasTiming) {
  if (!seq)
    return;
  seqContainer.hidden = NO;
  if (lanes) {
    NSSet<NSString *> *hidden =
        [plugin hiddenAnimatablePropertyLabels] ?: [NSSet set];
    seq.lanes = KKFilterLanesForVisibility(lanes, hidden);
  }
  if (hasTiming) {
    seq.effectDuration = durSec;
    ruler.effectDuration = durSec;
    if (durSec > 0) {
      seq.playheadFraction = frac;
      playhead.playheadFraction = frac;
    }
  }
}

/// Builds a `propertyLabel → per-scalar kind array` map for use by
/// `KKApplyHTHNormalizationInPlace` so Bool scalars can be preserved across
/// HTH normalization. Keys mirror `KKAnimatableProperty.label`; each value is
/// a flattened scalar-index → KKAnimatableParamKind array (e.g. Position with
/// kinds [Point, Bool] expands to [Point, Point, Bool] for X/Y/bool).
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)_kindsByLaneLabel {
  NSArray<KKAnimatableProperty *> *props = [self animatableProperties];
  NSMutableDictionary *result =
      [NSMutableDictionary dictionaryWithCapacity:props.count];
  for (KKAnimatableProperty *p in props) {
    NSMutableArray<NSNumber *> *flat = [NSMutableArray array];
    for (NSNumber *kindNum in p.valueParamKinds) {
      KKAnimatableParamKind kind = (KKAnimatableParamKind)kindNum.integerValue;
      NSUInteger n = 1;
      switch (kind) {
      case KKAnimatableParamKindColor:
        n = 3;
        break;
      case KKAnimatableParamKindPoint:
        n = 2;
        break;
      case KKAnimatableParamKindGradient:
        n = 0;
        break;
      default:
        n = 1;
        break;
      }
      for (NSUInteger i = 0; i < n; i++)
        [flat addObject:kindNum];
    }
    result[p.label] = [flat copy];
  }
  return result;
}

/// Walks every lane and toggles `kFxParameterFlag_DISABLED` on each lane's
/// value param IDs based on whether the lane's currently selected segment is
/// an HTH transition (Hold-Transition-Hold). HTH transitions derive their
/// value from the surrounding holds, so editing them in the inspector is a
/// no-op — the disabled flag tells the user. Caller must already be inside
/// an action scope so `setParameterFlags` persists.
- (void)_applyHTHParameterFlagsForLanes:(NSArray<KKTimingLane *> *)lanes {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!getAPI || !setAPI)
    return;
  NSArray<KKAnimatableProperty *> *props = [self animatableProperties];
  for (KKTimingLane *lane in lanes) {
    KKAnimatableProperty *prop = nil;
    for (KKAnimatableProperty *p in props) {
      if ([p.label isEqualToString:lane.propertyLabel]) {
        prop = p;
        break;
      }
    }
    if (!prop)
      continue;
    BOOL hth = KKIsHTHTransition(lane, lane.selectedSegment);
    for (NSUInteger i = 0; i < prop.valueParamIDs.count; i++) {
      UInt32 pid = prop.valueParamIDs[i].unsignedIntValue;
      // Bool params (e.g. MagicMove's "rotate with motion") are step values,
      // not derived from neighbours during a transition. Leave them editable
      // even when the rest of the lane is HTH-disabled.
      KKAnimatableParamKind kind = KKAnimatableParamKindFloat;
      if (i < prop.valueParamKinds.count)
        kind = (KKAnimatableParamKind)prop.valueParamKinds[i].integerValue;
      BOOL skip = (kind == KKAnimatableParamKindBool);
      FxParameterFlags cur = 0;
      [getAPI getParameterFlags:&cur fromParameter:pid];
      FxParameterFlags want = (hth && !skip)
                                  ? (cur | kFxParameterFlag_DISABLED)
                                  : (cur & ~kFxParameterFlag_DISABLED);
      if (cur != want)
        [setAPI setParameterFlags:want toParameter:pid];
    }
  }
}

- (void)timingGraphApplyState {
  KKPluginInstanceState *instState = KKInstanceStateForAPI(self.apiManager);
  if (!self.stageSequencer && instState.additionalTimingViews.count == 0)
    return;
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  CMTime t = [actionAPI currentTime];

  // Push loop state to every ruler unconditionally. The sync pump's early-
  // out skips pushing when state.loopEnabled is already correct, which
  // leaves freshly-opened window rulers out of date. Doing it here matches
  // how lane data is pushed — once per view set, every apply tick.
  BOOL loopEnabled = instState.loopEnabled;
  self.stageSequencerRuler.loopEnabled = loopEnabled;
  for (KKTimingViewRefs *refs in instState.additionalTimingViews)
    refs.ruler.loopEnabled = loopEnabled;

  NSArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  if (lanes) {
    instState.lanesSnapshot = [lanes copy];
    [self _applyHTHParameterFlagsForLanes:lanes];
  }

  double durSec = 0, frac = 0;
  BOOL hasTiming = NO;
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (timingAPI) {
    CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
    [timingAPI startTimeForEffect:&effectStart];
    [timingAPI durationTimeForEffect:&effectDuration];
    durSec = CMTimeGetSeconds(effectDuration);
    if (durSec > 0)
      frac = (CMTimeGetSeconds(t) - CMTimeGetSeconds(effectStart)) / durSec;
    hasTiming = YES;
  }

  // Primary (inspector) set.
  KKApplySequencerState(self, self.stageSequencer, self.stageSequencerContainer,
                        self.stageSequencerRuler, instState.playheadView, lanes,
                        durSec, frac, hasTiming);

  // Secondary (window) sets. Prune any dead (deallocated) entries.
  NSMutableArray *pruned = [NSMutableArray array];
  for (KKTimingViewRefs *refs in instState.additionalTimingViews) {
    if (!refs.isAlive)
      continue;
    [pruned addObject:refs];
    KKApplySequencerState(self, refs.seqView, refs.seqContainer, refs.ruler,
                          refs.playhead, lanes, durSec, frac, hasTiming);
  }
  instState.additionalTimingViews = pruned;

  [actionAPI endAction:self];
}

@end
#pragma clang diagnostic pop
