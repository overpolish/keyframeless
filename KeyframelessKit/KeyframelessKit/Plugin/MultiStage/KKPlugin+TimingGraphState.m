/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../KKLog.h"
#import "../../Math/KKEasing.h"
#import "../../Math/KKTimingStage.h"
#import "../../Views/StageSequencer/KKStagePlayheadView.h"
#import "../../Views/StageSequencer/KKStageSequencerRulerView.h"
#import "../../Views/StageSequencer/KKStageSequencerView.h"
#import "../KKConstants.h"
#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (TimingGraphState)

static void KKApplySequencerState(KKPlugin *plugin, KKStageSequencerView *seq,
                                  NSView *seqContainer,
                                  KKStageSequencerRulerView *ruler,
                                  KKStagePlayheadView *playhead,
                                  KKLaneVisibilityBar *visibilityBar,
                                  KKEmptyLanesView *emptyView,
                                  NSArray<KKTimingLane *> *lanes, double durSec,
                                  double frac, BOOL hasTiming) {
  if (!seq)
    return;
  seqContainer.hidden = NO;
  NSSet<NSString *> *pluginHidden =
      [plugin hiddenAnimatablePropertyLabels] ?: [NSSet set];
  if (lanes) {
    NSSet<NSString *> *hidden =
        KKEffectiveHiddenLaneLabels(pluginHidden, lanes);
    seq.lanes = KKFilterLanesForVisibility(lanes, hidden);
  }
  KKPushLanesToVisibilityBar(visibilityBar, lanes, pluginHidden);
  KKApplyEmptyLanesVisibility(emptyView, lanes, plugin);
  if (hasTiming) {
    seq.effectDuration = durSec;
    ruler.effectDuration = durSec;
    if (durSec > 0) {
      seq.playheadFraction = frac;
      playhead.playheadFraction = frac;
    }
  }
}

/// Walks every lane and toggles `kFxParameterFlag_DISABLED` on each lane's
/// value param IDs based on whether the lane's currently selected segment is
/// an HTH transition (Hold-Transition-Hold). HTH transitions derive their
/// value from the surrounding holds, so editing them in the inspector is a
/// no-op — the disabled flag tells the user. Caller must already be inside
/// an action scope so `setParameterFlags` persists.
- (void)_applyHTHParameterFlagsForLanes:(NSArray<KKTimingLane *> *)lanes {
  for (KKTimingLane *lane in lanes) {
    BOOL hth = KKIsHTHTransition(lane, lane.selectedSegment);
    [self setEditingDisabled:hth
                forLaneLabel:lane.propertyLabel
                    groupKey:lane.groupKey];
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

  // Direct JSON probe: KKReadLanesRebalanced has a snapshot fallback that
  // hides the "no JSON yet" case behind the stale build-time seed
  // (placeholder `[1]` values written when readValuesWithGetAPI fails in
  // create-view scope). Probe the param directly to know whether to
  // re-seed.
  NSString *probeJSON = nil;
  [paramGetAPI getStringParameterValue:&probeJSON
                         fromParameter:kKKParamMultiStageData];
  NSArray<KKTimingLane *> *lanes = nil;
  if (probeJSON.length) {
    lanes = KKReadLanesRebalanced(self.apiManager, paramGetAPI);
    if (lanes) {
      instState.lanesSnapshot = [lanes copy];
      instState.lanesEverPersisted = YES;
      [self _applyHTHParameterFlagsForLanes:lanes];
    }
  } else if (instState.lanesEverPersisted && instState.lanesSnapshot.count) {
    // Probe came back empty but we've already persisted JSON for this
    // instance. The empty read is an XPC scope artifact — trust the
    // in-memory snapshot rather than clobbering the user's edit with
    // rebuilt defaults.
    lanes = instState.lanesSnapshot;
  } else {
    // Fresh instance: no persisted JSON. Re-seed from live param values
    // inside this action scope (where reads actually succeed) and
    // overwrite the bad build-time snapshot.
    NSArray<KKTimingLane *> *seeded = [self defaultLanesAtTime:t
                                                   paramGetAPI:paramGetAPI];
    if (seeded.count) {
      instState.lanesSnapshot = [seeded copy];
      lanes = seeded;
    }
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
                        self.stageSequencerRuler, instState.playheadView,
                        instState.visibilityBar, instState.emptyLanesView,
                        lanes, durSec, frac, hasTiming);

  // Secondary (window) sets. Prune any dead (deallocated) entries.
  NSMutableArray *pruned = [NSMutableArray array];
  for (KKTimingViewRefs *refs in instState.additionalTimingViews) {
    if (!refs.isAlive)
      continue;
    [pruned addObject:refs];
    KKApplySequencerState(self, refs.seqView, refs.seqContainer, refs.ruler,
                          refs.playhead, refs.visibilityBar,
                          refs.emptyLanesView, lanes, durSec, frac, hasTiming);
  }
  instState.additionalTimingViews = pruned;

  [actionAPI endAction:self];
}

@end
#pragma clang diagnostic pop
