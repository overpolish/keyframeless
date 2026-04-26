/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../KKLog.h"
#import "../Math/KKEasing.h"
#import "../Math/KKTimingStage.h"
#import "../Views/KKAnimatableProperty.h"
#import "../Views/KKTimingGraphView.h"
#import "../Views/KKTimingSlot.h"
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

- (void)_applyTimingParamsToGraph:(KKTimingGraphView *)graph
                     withParamAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                           atTime:(CMTime)t {
  BOOL animIn = NO, animOut = NO;
  int inCurve = KKEasingCurveEaseOut, outCurve = KKEasingCurveEaseOut;
  int sel = KKTimingGraphSectionHold, holdEffectVal = KKHoldEffectNone;
  [paramGetAPI getBoolValue:&animIn fromParameter:kKKParamAnimateIn atTime:t];
  [paramGetAPI getBoolValue:&animOut fromParameter:kKKParamAnimateOut atTime:t];
  [paramGetAPI getIntValue:&inCurve
             fromParameter:kKKParamAnimateInInterpolation
                    atTime:t];
  [paramGetAPI getIntValue:&outCurve
             fromParameter:kKKParamAnimateOutInterpolation
                    atTime:t];
  [paramGetAPI getIntValue:&sel
             fromParameter:kKKParamTimingSelectedSection
                    atTime:t];
  [paramGetAPI getIntValue:&holdEffectVal
             fromParameter:kKKParamHoldEffect
                    atTime:t];

  double inIntensity = 0.5, outIntensity = 0.5, holdIntensity = 0.5;
  [paramGetAPI getFloatValue:&inIntensity
               fromParameter:kKKParamAnimateInIntensity
                      atTime:t];
  [paramGetAPI getFloatValue:&outIntensity
               fromParameter:kKKParamAnimateOutIntensity
                      atTime:t];
  [paramGetAPI getFloatValue:&holdIntensity
               fromParameter:kKKParamHoldIntensity
                      atTime:t];

  double inFrequency = 0.5, outFrequency = 0.5, holdFrequency = 0.5;
  [paramGetAPI getFloatValue:&inFrequency
               fromParameter:kKKParamAnimateInFrequency
                      atTime:t];
  [paramGetAPI getFloatValue:&outFrequency
               fromParameter:kKKParamAnimateOutFrequency
                      atTime:t];
  [paramGetAPI getFloatValue:&holdFrequency
               fromParameter:kKKParamHoldFrequency
                      atTime:t];

  int holdSeed = 0;
  [paramGetAPI getIntValue:&holdSeed fromParameter:kKKParamHoldSeed atTime:t];

  double inDuration = 0.5, outDuration = 0.5;
  [paramGetAPI getFloatValue:&inDuration
               fromParameter:kKKParamAnimateInDuration
                      atTime:t];
  [paramGetAPI getFloatValue:&outDuration
               fromParameter:kKKParamAnimateOutDuration
                      atTime:t];

  graph.inEnabled = animIn;
  graph.outEnabled = animOut;
  graph.inDuration = inDuration;
  graph.outDuration = outDuration;
  graph.inCurve = (KKEasingCurve)inCurve;
  graph.outCurve = (KKEasingCurve)outCurve;
  graph.holdEffect = (KKHoldEffect)holdEffectVal;
  graph.inIntensity = inIntensity;
  graph.outIntensity = outIntensity;
  graph.holdIntensity = holdIntensity;
  graph.inFrequency = inFrequency;
  graph.outFrequency = outFrequency;
  graph.holdFrequency = holdFrequency;
  graph.holdSeed = holdSeed;
  graph.selectedSection = (KKTimingGraphSection)sel;
}

- (void)_applySlotState:(NSArray<KKTimingSlot *> *)slots
           withParamAPI:(id<FxParameterRetrievalAPI_v6>)paramAPI
                 atTime:(CMTime)time {
  for (KKTimingSlot *slot in slots)
    slot.applyState(paramAPI, time);
}

- (void)_applyStateToTimingGraph:(KKTimingGraphView *)graph
                         seqView:(KKStageSequencerView *)seq
                    seqContainer:(NSView *)seqContainer
                           ruler:(KKStageSequencerRulerView *)ruler
                        playhead:(KKStagePlayheadView *)playhead
                    multiEnabled:(BOOL)multiStageEnabled
                           lanes:(NSArray<KKTimingLane *> *)lanes
                    effectDurSec:(double)durSec
                    playheadFrac:(double)frac
                       hasTiming:(BOOL)hasTiming
                    withParamAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                          atTime:(CMTime)t {
  if (!graph)
    return;
  if (seq) {
    seqContainer.hidden = !multiStageEnabled;
    graph.hidden = multiStageEnabled;
    if (multiStageEnabled) {
      if (lanes) {
        NSSet<NSString *> *hidden =
            [self hiddenAnimatablePropertyLabels] ?: [NSSet set];
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
  }

  [self _applyTimingParamsToGraph:graph withParamAPI:paramGetAPI atTime:t];
  [self _applySlotState:graph.globalSlots withParamAPI:paramGetAPI atTime:t];
  [self _applySlotState:graph.inSectionSlots withParamAPI:paramGetAPI atTime:t];
  [self _applySlotState:graph.holdSectionSlots
           withParamAPI:paramGetAPI
                 atTime:t];
  [self _applySlotState:graph.outSectionSlots
           withParamAPI:paramGetAPI
                 atTime:t];
  if (graph.holdPropertyApplyState)
    graph.holdPropertyApplyState(paramGetAPI, t);
}

/// Walks every lane and toggles `kFxParameterFlag_DISABLED` on each lane's
/// value param IDs based on whether the lane's currently selected segment is
/// an HTH transition (Hold-Transition-Hold). HTH transitions derive their
/// value from the surrounding holds, so editing them in the inspector is a
/// no-op — the disabled flag tells the user. Caller must already be inside
/// an action scope so `setParameterFlags` persists.
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
  if (!self.timingGraph && instState.additionalTimingViews.count == 0)
    return;
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  CMTime t = [actionAPI currentTime];

  // Read the shared state once and broadcast to every registered view set.
  BOOL multiStageEnabled = NO;
  [paramGetAPI getBoolValue:&multiStageEnabled
              fromParameter:kKKParamMultiStageEnabled
                     atTime:t];

  // Push loop state to every ruler unconditionally. The sync pump's early-
  // out skips pushing when state.loopEnabled is already correct, which
  // leaves freshly-opened window rulers out of date. Doing it here matches
  // how lane data is pushed — once per view set, every apply tick.
  BOOL loopEnabled = instState.loopEnabled;
  self.stageSequencerRuler.loopEnabled = loopEnabled;
  for (KKTimingViewRefs *refs in instState.additionalTimingViews)
    refs.ruler.loopEnabled = loopEnabled;

  NSArray<KKTimingLane *> *lanes = nil;
  if (multiStageEnabled) {
    lanes = KKReadLanesRebalanced(self.apiManager, paramGetAPI);
    if (lanes) {
      KKInstanceStateForAPI(self.apiManager).lanesSnapshot = [lanes copy];
      [self _applyHTHParameterFlagsForLanes:lanes];
    }
  }

  double durSec = 0, frac = 0;
  BOOL hasTiming = NO;
  if (multiStageEnabled) {
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
  }

  // Primary (inspector) set.
  [self _applyStateToTimingGraph:self.timingGraph
                         seqView:self.stageSequencer
                    seqContainer:self.stageSequencerContainer
                           ruler:self.stageSequencerRuler
                        playhead:KKInstanceStateForAPI(self.apiManager)
                                     .playheadView
                    multiEnabled:multiStageEnabled
                           lanes:lanes
                    effectDurSec:durSec
                    playheadFrac:frac
                       hasTiming:hasTiming
                    withParamAPI:paramGetAPI
                          atTime:t];

  // Secondary (window) sets. Prune any dead (deallocated) entries.
  NSMutableArray *pruned = [NSMutableArray array];
  for (KKTimingViewRefs *refs in instState.additionalTimingViews) {
    if (!refs.isAlive)
      continue;
    [pruned addObject:refs];
    [self _applyStateToTimingGraph:refs.graphView
                           seqView:refs.seqView
                      seqContainer:refs.seqContainer
                             ruler:refs.ruler
                          playhead:refs.playhead
                      multiEnabled:multiStageEnabled
                             lanes:lanes
                      effectDurSec:durSec
                      playheadFrac:frac
                         hasTiming:hasTiming
                      withParamAPI:paramGetAPI
                            atTime:t];
  }
  instState.additionalTimingViews = pruned;

  [actionAPI endAction:self];
}

- (void)_timingGraphSetAnimateEnabled:(BOOL)enabled
                         forParameter:(UInt32)paramID
                      disabledSection:(KKTimingGraphSection)section {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  CMTime t = [actAPI currentTime];
  [setAPI setBoolValue:enabled toParameter:paramID atTime:t];
  if (!enabled) {
    int sel = KKTimingGraphSectionHold;
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    [getAPI getIntValue:&sel
          fromParameter:kKKParamTimingSelectedSection
                 atTime:t];
    if (sel == (int)section)
      [setAPI setIntValue:KKTimingGraphSectionHold
              toParameter:kKKParamTimingSelectedSection
                   atTime:t];
  }
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)timingGraphSelectSection:(KKTimingGraphSection)section {
  if (section == KKTimingGraphSectionIn && !self.timingGraph.inEnabled)
    return;
  if (section == KKTimingGraphSectionOut && !self.timingGraph.outEnabled)
    return;

  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setIntValue:(int)section
          toParameter:kKKParamTimingSelectedSection
               atTime:[actAPI currentTime]];
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)timingGraphSetIntValue:(int)value forParameter:(UInt32)paramID {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setIntValue:value toParameter:paramID atTime:[actAPI currentTime]];
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)timingGraphSetFloatValue:(double)value forParameter:(UInt32)paramID {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setFloatValue:value toParameter:paramID atTime:[actAPI currentTime]];
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

@end
#pragma clang diagnostic pop
