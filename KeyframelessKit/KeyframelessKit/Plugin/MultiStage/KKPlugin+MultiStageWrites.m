/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../Views/StageSequencer/KKStageSequencerView.h"
#import "../KKDataBlob.h"
#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKConstants.h>
#import <KeyframelessKit/KKTimingStage.h>

/// Stamps the "recent parameter change" timestamp used by the multi-stage
/// pump to suppress render-sourced playhead updates in the wake of a slider
/// drag. Defined in KKPlugin+MultiStagePump.m.
extern void KKMultiStageMarkParameterChanged(void);

/// Persists `lanes` to JSON, updates state's snapshot/pendingLanes, and
/// pushes the visibility-filtered lanes into the primary sequencer view and
/// any additional view sets on the next runloop tick.
static void KKMultiStagePersistAndPush(KKPluginInstanceState *state,
                                       NSArray<KKTimingLane *> *lanes,
                                       id<PROAPIAccessing> apiManager) {
  state.pendingLanes = lanes;
  state.lanesSnapshot = lanes;

  id<FxParameterSettingAPI_v5> paramSetAPI =
      [apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (paramSetAPI) {
    NSString *json = [KKTimingLane jsonFromLanes:lanes];
    if (json)
      KKWriteMultiStageJSONDeduped(json, paramSetAPI, apiManager);
  }

  KKStageSequencerView *seq = state.sequencerView;
  NSArray<KKTimingViewRefs *> *extras =
      [state.additionalTimingViews copy] ?: @[];
  if (seq || extras.count) {
    NSArray<KKTimingLane *> *visible =
        KKFilterLanesForVisibility(lanes, state.hiddenLaneLabels);
    dispatch_async(dispatch_get_main_queue(), ^{
      seq.lanes = visible;
      for (KKTimingViewRefs *r in extras)
        r.seqView.lanes = visible;
    });
  }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation KKPlugin (MultiStageWrites)

- (BOOL)multiStageSetPathData:(NSData *)pathData
                     forLabel:(NSString *)label
                 segmentIndex:(NSInteger)segmentIndex {
  if (!label.length || segmentIndex < 0)
    return NO;
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (!state)
    return NO;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return NO;

  NSMutableArray<KKTimingLane *> *lanes =
      [state.lanesSnapshot mutableCopy]
          ?: KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  if (!lanes.count)
    return NO;

  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    if (![lane.propertyLabel isEqualToString:label])
      continue;
    if ((NSUInteger)segmentIndex >= lane.segments.count)
      return NO;
    KKTimingLane *mLane = [lane copy];
    NSMutableArray *mSegs = [mLane.segments mutableCopy];
    KKTimingSegment *mSeg = [mSegs[segmentIndex] copy];
    mSeg.pathData = pathData.length > 0 ? [pathData copy] : nil;
    mSegs[segmentIndex] = mSeg;
    mLane.segments = mSegs;
    lanes[li] = mLane;

    NSMutableArray<KKTimingLane *> *normalized = [lanes mutableCopy];
    KKApplyHTHNormalizationInPlace(normalized);
    KKMultiStagePersistAndPush(state, [normalized copy], self.apiManager);
    return YES;
  }
  return NO;
}

- (BOOL)multiStageUpdateSelectedSegmentForLabel:(NSString *)label
                                         values:(NSArray<NSNumber *> *)values {
  if (!label.length || !values.count)
    return NO;
  KKMultiStageMarkParameterChanged();
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (!state || state.selectionInProgress)
    return NO;

  NSMutableArray<KKTimingLane *> *lanes = [state.lanesSnapshot mutableCopy];
  if (!lanes.count) {
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    lanes = KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  }
  if (!lanes.count)
    return NO;

  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    if (![lane.propertyLabel isEqualToString:label])
      continue;
    NSInteger selSeg = lane.selectedSegment;
    if (selSeg < 0 || (NSUInteger)selSeg >= lane.segments.count)
      break;

    KKTimingLane *mLane = [lane copy];
    NSMutableArray *mSegs = [mLane.segments mutableCopy];
    KKTimingSegment *mSeg = [mSegs[selSeg] copy];
    mSeg.values = [values copy];
    mSegs[selSeg] = mSeg;
    mLane.segments = mSegs;
    lanes[li] = mLane;

    KKApplyHTHNormalizationInPlace(lanes);
    KKMultiStagePersistAndPush(state, [lanes copy], self.apiManager);
    return YES;
  }
  return NO;
}

- (void)multiStageDeferLiveUpdateForLabel:(NSString *)label
                                   values:(NSArray<NSNumber *> *)values {
  if (!label.length || !values.count)
    return;
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (!state)
    return;

  if (!state.pendingLiveUpdates)
    state.pendingLiveUpdates = [NSMutableDictionary dictionary];
  state.pendingLiveUpdates[label] = [values copy];

  if (state.liveUpdatePending)
    return;
  state.liveUpdatePending = YES;

  __weak typeof(self) ws = self;
  // 16ms ≈ one 60fps frame. Long enough that FCP's full host-cmd-Z
  // revert burst (animatable params + multi-stage blob) lands and the
  // resulting MS-REFRESH sets `hostUndoSuppressionPending` before this
  // block fires. Imperceptible during continuous drag — successive ticks
  // overwrite the staged values, so live preview tracks the slider.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(), ^{
                   typeof(self) ss = ws;
                   if (!ss)
                     return;
                   KKPluginInstanceState *st =
                       KKInstanceStateForAPI(ss.apiManager);
                   if (!st)
                     return;
                   st.liveUpdatePending = NO;
                   if (st.hostUndoSuppressionPending) {
                     [st.pendingLiveUpdates removeAllObjects];
                     return;
                   }
                   // Param read/write APIs resolve to nil outside an action
                   // scope. The caller's parameterChanged scope is long gone by
                   // now; open our own.
                   id<FxCustomParameterActionAPI_v4> actAPI = [ss.apiManager
                       apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
                   if (!actAPI) {
                     [st.pendingLiveUpdates removeAllObjects];
                     return;
                   }
                   NSDictionary<NSString *, NSArray<NSNumber *> *> *toApply =
                       [st.pendingLiveUpdates copy];
                   [st.pendingLiveUpdates removeAllObjects];
                   [actAPI startAction:ss];
                   for (NSString *lbl in toApply) {
                     [ss multiStageUpdateSelectedSegmentForLabel:lbl
                                                          values:toApply[lbl]];
                   }
                   [actAPI endAction:ss];
                 });
}

@end

#pragma clang diagnostic pop
