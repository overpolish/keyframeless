/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../KKLog.h"
#import "../../Views/StageSequencer/KKStageSequencerView.h"
#import "../KKPlugin+Color.h"
#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKConstants.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation KKPlugin (HandlersSelection)

- (void)_handleSegmentSelectedAtLane:(NSInteger)laneIndex
                             segment:(NSInteger)segmentIndex {
  if (laneIndex < 0)
    return;
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (!state)
    return;
  state.selectionInProgress = YES;
  BOOL ug = KKBeginUndoGroup(self.apiManager, @"Select Segment");
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  CMTime ct = [actAPI currentTime];

  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  NSInteger jsonIdx =
      KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
  if (!lanes || jsonIdx < 0) {
    [actAPI endAction:self];
    KKEndUndoGroup(self.apiManager, ug);
    return;
  }

  KKTimingLane *lane = lanes[jsonIdx];

  // Write-back: save current native values into the previously selected
  // segment via the plugin's `currentValuesForLaneLabel:` hook.
  NSInteger prevSeg = lane.selectedSegment;
  NSArray<NSNumber *> *curVals =
      [self currentValuesForLaneLabel:lane.propertyLabel
                             groupKey:lane.groupKey
                               atTime:ct];
  if (curVals.count && prevSeg >= 0 &&
      (NSUInteger)prevSeg < lane.segments.count) {
    KKTimingLane *mLane = [lane copy];
    NSMutableArray *mSegs = [mLane.segments mutableCopy];
    KKTimingSegment *mSeg = [mSegs[prevSeg] copy];
    mSeg.values = curVals;
    mSegs[prevSeg] = mSeg;
    mLane.segments = mSegs;
    mLane.selectedSegment = segmentIndex;
    lanes[jsonIdx] = mLane;
    lane = mLane;
  } else {
    KKTimingLane *mLane = [lane copy];
    mLane.selectedSegment = segmentIndex;
    lanes[jsonIdx] = mLane;
    lane = mLane;
  }

  KKWriteLanesJSON(lanes, setAPI, self.apiManager);
  state.lanesSnapshot = [lanes copy];
  state.pendingLanes = nil;

  // Push new selection's values into the plugin's source of truth (params,
  // gradient control, etc). Plugin clears DISABLED flags as needed.
  if (segmentIndex >= 0 && (NSUInteger)segmentIndex < lane.segments.count) {
    [self applyLaneValues:lane.segments[segmentIndex].values
                 forLabel:lane.propertyLabel
                 groupKey:lane.groupKey
                   atTime:ct];
    [self kkLoadLaneSegmentForLabel:lane.propertyLabel
                           groupKey:lane.groupKey
                            segment:segmentIndex
                             getAPI:getAPI
                             setAPI:setAPI];
  }
  [self _applyHTHParameterFlagsForLanes:lanes];

  [actAPI endAction:self];
  state.selectionInProgress = NO;
  [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

- (void)_handleAllLanesSegmentSelectedAtPosition:(double)position {
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (!state)
    return;
  state.selectionInProgress = YES;
  BOOL ug = KKBeginUndoGroup(self.apiManager, @"Select Segments");
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  CMTime ct = [actAPI currentTime];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  if (!lanes) {
    [actAPI endAction:self];
    state.selectionInProgress = NO;
    KKEndUndoGroup(self.apiManager, ug);
    return;
  }

  NSSet<NSString *> *pluginHidden =
      [self hiddenAnimatablePropertyLabels] ?: [NSSet set];

  NSMutableArray<NSNumber *> *newSegPerLane = [NSMutableArray array];
  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    if (!lane.effectivelyVisibleInSequencer ||
        [pluginHidden containsObject:lane.propertyLabel] ||
        KKLaneIsHiddenByCollapsedGroup(lanes, li)) {
      [newSegPerLane addObject:@(-1)];
      continue;
    }
    NSInteger newIdx = -1;
    for (NSUInteger si = 0; si < lane.segments.count; si++) {
      KKTimingSegment *s = lane.segments[si];
      if (position >= s.start && position < s.end) {
        newIdx = (NSInteger)si;
        break;
      }
    }
    if (newIdx < 0 && lane.segments.count > 0)
      newIdx = (NSInteger)lane.segments.count - 1;

    KKTimingLane *mLane = [lane copy];
    NSMutableArray *mSegs = [mLane.segments mutableCopy];

    NSInteger prevSeg = lane.selectedSegment;
    NSArray<NSNumber *> *curVals =
        [self currentValuesForLaneLabel:lane.propertyLabel
                               groupKey:lane.groupKey
                                 atTime:ct];
    if (curVals.count && prevSeg >= 0 && (NSUInteger)prevSeg < mSegs.count) {
      KKTimingSegment *mSeg = [mSegs[prevSeg] copy];
      mSeg.values = curVals;
      mSegs[prevSeg] = mSeg;
    }
    mLane.segments = mSegs;
    mLane.selectedSegment = newIdx;
    lanes[li] = mLane;
    [newSegPerLane addObject:@(newIdx)];
  }

  KKWriteLanesJSON(lanes, setAPI, self.apiManager);
  state.lanesSnapshot = [lanes copy];
  state.pendingLanes = nil;

  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    NSInteger newIdx = newSegPerLane[li].integerValue;
    if (newIdx < 0 || (NSUInteger)newIdx >= lane.segments.count)
      continue;
    [self applyLaneValues:lane.segments[newIdx].values
                 forLabel:lane.propertyLabel
                 groupKey:lane.groupKey
                   atTime:ct];
    [self kkLoadLaneSegmentForLabel:lane.propertyLabel
                           groupKey:lane.groupKey
                            segment:newIdx
                             getAPI:getAPI
                             setAPI:setAPI];
  }

  [self _applyHTHParameterFlagsForLanes:lanes];

  [actAPI endAction:self];
  state.selectionInProgress = NO;
  [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

- (void)_handleLaneToggledAtIndex:(NSInteger)laneIndex enabled:(BOOL)enabled {
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  BOOL ug = KKBeginUndoGroup(self.apiManager, @"Toggle Lane");
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  CMTime ct = [actAPI currentTime];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  NSInteger jsonIdx =
      KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
  if (!lanes || jsonIdx < 0) {
    [actAPI endAction:self];
    if (state)
      state.selectionInProgress = NO;
    KKEndUndoGroup(self.apiManager, ug);
    return;
  }

  NSMutableArray *mutable = [lanes mutableCopy];
  KKTimingLane *lane = [mutable[jsonIdx] copy];
  lane.enabled = enabled;
  lane.selectedSegment = -1;
  if (enabled) {
    for (NSUInteger i = 0; i < lane.segments.count; i++) {
      if (lane.segments[i].type == KKSegmentTypeHold) {
        lane.selectedSegment = (NSInteger)i;
        break;
      }
    }
  }
  mutable[jsonIdx] = lane;
  KKWriteLanesJSON(mutable, setAPI, self.apiManager);

  // Enable-path: native params may have been edited while the lane was
  // disabled. Overwrite native params with the newly-selected segment's
  // values so the live-param-override in multiStageValuesAtTime: doesn't
  // keep rendering stale values until the user clicks a segment.
  if (enabled && lane.selectedSegment >= 0 &&
      (NSUInteger)lane.selectedSegment < lane.segments.count) {
    if (state)
      state.selectionInProgress = YES;
    [self applyLaneValues:lane.segments[lane.selectedSegment].values
                 forLabel:lane.propertyLabel
                 groupKey:lane.groupKey
                   atTime:ct];
    if (state) {
      state.lanesSnapshot = [mutable copy];
      state.pendingLanes = nil;
    }
  }
  [actAPI endAction:self];
  if (state)
    state.selectionInProgress = NO;
  [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

- (void)_handleLaneVisibilityClickedAtIndex:(NSInteger)laneIndex
                                 optionDown:(BOOL)optionDown {
  BOOL ug = KKBeginUndoGroup(self.apiManager, @"Lane Visibility");
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  if (!lanes) {
    [actAPI endAction:self];
    KKEndUndoGroup(self.apiManager, ug);
    return;
  }
  // Pills are deduped by propertyLabel — a single pill controls every lane
  // sharing that label (e.g. Canvas: one "Stroke Width" pill toggles every
  // layer's stroke-width lane). Translate the pill index back to its label
  // and operate on every matching lane.
  NSSet<NSString *> *pluginHiddenForIndex =
      [self hiddenAnimatablePropertyLabels] ?: [NSSet set];
  NSString *clickedLabel =
      KKLabelForPillIndex(laneIndex, lanes, pluginHiddenForIndex);
  if (clickedLabel.length == 0) {
    [actAPI endAction:self];
    KKEndUndoGroup(self.apiManager, ug);
    return;
  }

  // For the visibility check, treat a pill as visible iff every matching
  // lane is visible. Solo unsolos when this is the only currently-visible
  // pill.
  BOOL clickedCurrentlyVisible = YES;
  for (KKTimingLane *lane in lanes) {
    if (!lane.pluginVisible)
      continue;
    if ([lane.propertyLabel isEqualToString:clickedLabel] &&
        !lane.visibleInSequencer) {
      clickedCurrentlyVisible = NO;
      break;
    }
  }
  NSMutableSet<NSString *> *visibleLabels = [NSMutableSet set];
  NSMutableSet<NSString *> *hiddenLabels = [NSMutableSet set];
  for (KKTimingLane *lane in lanes) {
    if (!lane.pluginVisible)
      continue;
    NSString *l = lane.propertyLabel ?: @"";
    if ([pluginHiddenForIndex containsObject:l])
      continue;
    if (lane.visibleInSequencer)
      [visibleLabels addObject:l];
    else
      [hiddenLabels addObject:l];
  }
  // A label counts as visible for the pill bar only when *every* lane with
  // that label is visible.
  [visibleLabels minusSet:hiddenLabels];
  BOOL clickedIsOnlyVisible =
      clickedCurrentlyVisible && visibleLabels.count == 1;

  for (NSUInteger i = 0; i < lanes.count; i++) {
    KKTimingLane *lane = [lanes[i] copy];
    NSString *l = lane.propertyLabel ?: @"";
    BOOL matches = [l isEqualToString:clickedLabel];
    BOOL want;
    if (optionDown) {
      want = clickedIsOnlyVisible ? YES : matches;
    } else {
      want = matches ? !clickedCurrentlyVisible : lane.visibleInSequencer;
    }
    lane.visibleInSequencer = want;
    lanes[i] = lane;
  }

  KKWriteLanesJSON(lanes, setAPI, self.apiManager);

  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (state) {
    state.lanesSnapshot = [lanes copy];
    state.pendingLanes = nil;
    NSSet<NSString *> *pluginHidden =
        [self hiddenAnimatablePropertyLabels] ?: [NSSet set];
    state.hiddenLaneLabels = KKEffectiveHiddenLaneLabels(pluginHidden, lanes);
    state.pluginHiddenLaneLabels = pluginHidden;
    NSArray<KKTimingLane *> *visible =
        KKFilterLanesForVisibility(lanes, state.hiddenLaneLabels);
    KKStageSequencerView *seq = state.sequencerView;
    NSArray<KKTimingViewRefs *> *extras =
        [state.additionalTimingViews copy] ?: @[];
    dispatch_async(dispatch_get_main_queue(), ^{
      seq.lanes = visible;
      for (KKTimingViewRefs *r in extras)
        r.seqView.lanes = visible;
    });
    KKPushLanesToVisibilityBar(state.visibilityBar, lanes, pluginHidden);
    KKApplyEmptyLanesVisibility(state.emptyLanesView, lanes, self);
    for (KKTimingViewRefs *r in extras) {
      KKPushLanesToVisibilityBar(r.visibilityBar, lanes, pluginHidden);
      KKApplyEmptyLanesVisibility(r.emptyLanesView, lanes, self);
    }
  }

  [actAPI endAction:self];
  [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

- (void)_handleLaneVisibilitySetAtIndex:(NSInteger)laneIndex
                                visible:(BOOL)visible {
  BOOL ug = KKBeginUndoGroup(self.apiManager, @"Lane Visibility");
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  if (!lanes) {
    [actAPI endAction:self];
    KKEndUndoGroup(self.apiManager, ug);
    return;
  }
  NSSet<NSString *> *pluginHiddenForIndex =
      [self hiddenAnimatablePropertyLabels] ?: [NSSet set];
  NSString *targetLabel =
      KKLabelForPillIndex(laneIndex, lanes, pluginHiddenForIndex);
  if (targetLabel.length == 0) {
    [actAPI endAction:self];
    KKEndUndoGroup(self.apiManager, ug);
    return;
  }
  BOOL changed = NO;
  for (NSUInteger i = 0; i < lanes.count; i++) {
    KKTimingLane *l = lanes[i];
    if (![l.propertyLabel isEqualToString:targetLabel] ||
        l.visibleInSequencer == visible)
      continue;
    KKTimingLane *m = [l copy];
    m.visibleInSequencer = visible;
    lanes[i] = m;
    changed = YES;
  }
  if (!changed) {
    [actAPI endAction:self];
    KKEndUndoGroup(self.apiManager, ug);
    return;
  }

  KKWriteLanesJSON(lanes, setAPI, self.apiManager);

  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (state) {
    state.lanesSnapshot = [lanes copy];
    state.pendingLanes = nil;
    NSSet<NSString *> *pluginHidden =
        [self hiddenAnimatablePropertyLabels] ?: [NSSet set];
    state.hiddenLaneLabels = KKEffectiveHiddenLaneLabels(pluginHidden, lanes);
    state.pluginHiddenLaneLabels = pluginHidden;
    NSArray<KKTimingLane *> *visibleLanes =
        KKFilterLanesForVisibility(lanes, state.hiddenLaneLabels);
    KKStageSequencerView *seq = state.sequencerView;
    NSArray<KKTimingViewRefs *> *extras =
        [state.additionalTimingViews copy] ?: @[];
    dispatch_async(dispatch_get_main_queue(), ^{
      seq.lanes = visibleLanes;
      for (KKTimingViewRefs *r in extras)
        r.seqView.lanes = visibleLanes;
    });
    KKPushLanesToVisibilityBar(state.visibilityBar, lanes, pluginHidden);
    KKApplyEmptyLanesVisibility(state.emptyLanesView, lanes, self);
    for (KKTimingViewRefs *r in extras) {
      KKPushLanesToVisibilityBar(r.visibilityBar, lanes, pluginHidden);
      KKApplyEmptyLanesVisibility(r.emptyLanesView, lanes, self);
    }
  }

  [actAPI endAction:self];
  [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

- (void)_handleGroupCollapseToggledForKey:(NSString *)groupKey
                                collapsed:(BOOL)collapsed {
  if (groupKey.length == 0)
    return;
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  BOOL ug = KKBeginUndoGroup(self.apiManager,
                             collapsed ? @"Collapse Group" : @"Expand Group");
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  if (lanes) {
    BOOL changed = NO;
    for (NSUInteger i = 0; i < lanes.count; i++) {
      KKTimingLane *l = lanes[i];
      if ([l.groupKey isEqualToString:groupKey] &&
          l.groupCollapsed != collapsed) {
        KKTimingLane *m = [l copy];
        m.groupCollapsed = collapsed;
        lanes[i] = m;
        changed = YES;
      }
    }
    if (changed) {
      KKWriteLanesJSON(lanes, setAPI, self.apiManager);
      if (state)
        state.lanesSnapshot = [lanes copy];
    }
  }
  [actAPI endAction:self];
  [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

- (void)_handleLaneOSCVisibilityAtIndex:(NSInteger)laneIndex
                                visible:(BOOL)visible {
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  BOOL ug = KKBeginUndoGroup(self.apiManager, @"Toggle OSC Visibility");
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  NSInteger jsonIdx =
      KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
  if (lanes && jsonIdx >= 0) {
    KKTimingLane *lane = [lanes[jsonIdx] copy];
    lane.oscVisible = visible;
    lanes[jsonIdx] = lane;
    KKWriteLanesJSON(lanes, setAPI, self.apiManager);
    if (state)
      state.lanesSnapshot = [lanes copy];
  }
  [actAPI endAction:self];
  [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

- (void)_handleLaneChangedAtIndex:(NSInteger)laneIndex
                             lane:(KKTimingLane *)updatedLane {
  BOOL ug = KKBeginUndoGroup(self.apiManager, @"Edit Lane");
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  NSInteger jsonIdx =
      KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
  if (lanes && jsonIdx >= 0) {
    // Edge/move drag can change a locked segment's visual width. Restamp
    // `lockedDurationSeconds` to the new width so the lock target matches
    // what the user just authored — otherwise the next clip resize would
    // snap the segment back to its previous target.
    double curDur = KKCurrentEffectDurationSeconds(self.apiManager);
    if (curDur > 0) {
      KKTimingLane *relocked = [updatedLane copy];
      NSMutableArray<KKTimingSegment *> *segs = [relocked.segments mutableCopy];
      for (NSUInteger i = 0; i < segs.count; i++) {
        KKTimingSegment *s = segs[i];
        if (s.lockedDurationSeconds <= 0)
          continue;
        KKTimingSegment *m = [s copy];
        m.lockedDurationSeconds = (s.end - s.start) * curDur;
        segs[i] = m;
      }
      relocked.segments = segs;
      updatedLane = relocked;
    }
    lanes[jsonIdx] = updatedLane;
    KKWriteLanesJSON(lanes, setAPI, self.apiManager);
  }
  [actAPI endAction:self];
  [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

- (void)_handleLanesChangedAtIndexes:(NSArray<NSNumber *> *)laneIndexes
                               lanes:(NSArray<KKTimingLane *> *)updatedLanes {
  if (laneIndexes.count == 0 || laneIndexes.count != updatedLanes.count)
    return;
  BOOL ug = KKBeginUndoGroup(self.apiManager, @"Edit Lanes");
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (!lanes) {
    [actAPI endAction:self];
    KKEndUndoGroup(self.apiManager, ug);
    return;
  }

  double curDur = KKCurrentEffectDurationSeconds(self.apiManager);
  for (NSUInteger i = 0; i < laneIndexes.count; i++) {
    NSInteger viewIdx = laneIndexes[i].integerValue;
    NSInteger jsonIdx =
        KKLaneJSONIndexForViewIndex(viewIdx, lanes, state.hiddenLaneLabels);
    if (jsonIdx < 0)
      continue;
    KKTimingLane *updatedLane = updatedLanes[i];
    if (curDur > 0) {
      KKTimingLane *relocked = [updatedLane copy];
      NSMutableArray<KKTimingSegment *> *segs = [relocked.segments mutableCopy];
      for (NSUInteger si = 0; si < segs.count; si++) {
        KKTimingSegment *s = segs[si];
        if (s.lockedDurationSeconds <= 0)
          continue;
        KKTimingSegment *m = [s copy];
        m.lockedDurationSeconds = (s.end - s.start) * curDur;
        segs[si] = m;
      }
      relocked.segments = segs;
      updatedLane = relocked;
    }
    lanes[jsonIdx] = updatedLane;
  }
  KKWriteLanesJSON(lanes, setAPI, self.apiManager);
  [actAPI endAction:self];
  [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

- (void)_handleSegmentValuesCopiedAtLane:(NSInteger)laneIndex
                                     src:(NSInteger)srcSegmentIndex
                                     dst:(NSInteger)dstSegmentIndex {
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  BOOL ug = KKBeginUndoGroup(self.apiManager, @"Copy Segment Values");
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  CMTime ct = [actAPI currentTime];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  NSInteger jsonIdx =
      KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
  if (!lanes || jsonIdx < 0) {
    [actAPI endAction:self];
    KKEndUndoGroup(self.apiManager, ug);
    return;
  }
  KKTimingLane *lane = [lanes[jsonIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
  if ((NSUInteger)srcSegmentIndex >= segs.count ||
      (NSUInteger)dstSegmentIndex >= segs.count ||
      srcSegmentIndex == dstSegmentIndex) {
    [actAPI endAction:self];
    KKEndUndoGroup(self.apiManager, ug);
    return;
  }
  NSArray<NSNumber *> *newVals = [segs[srcSegmentIndex].values copy];
  KKTimingSegment *dst = [segs[dstSegmentIndex] copy];
  dst.values = newVals;
  segs[dstSegmentIndex] = dst;
  lane.segments = segs;
  lanes[jsonIdx] = lane;

  KKWriteLanesJSON(lanes, setAPI, self.apiManager);

  // Mirror any out-of-band per-segment payload (e.g. Canvas's path-morph
  // snapshots, which don't live in the lane's `values`). Runs in addition
  // to the scalar-values copy above.
  [self kkCopyLaneSegmentForLabel:lane.propertyLabel
                         groupKey:lane.groupKey
                      fromSegment:srcSegmentIndex
                        toSegment:dstSegmentIndex
                           getAPI:getAPI
                           setAPI:setAPI];

  // When the destination is the currently-selected segment, native params
  // still hold its pre-copy values. Push the new values through so the next
  // click on this segment doesn't write the stale native values back into
  // it during onSegmentSelected's write-back step.
  if (dstSegmentIndex == lane.selectedSegment) {
    if (state)
      state.selectionInProgress = YES;
    if ([self applyLaneValues:newVals
                     forLabel:lane.propertyLabel
                     groupKey:lane.groupKey
                       atTime:ct] &&
        state) {
      state.lanesSnapshot = [lanes copy];
      state.pendingLanes = nil;
    }
    [self kkLoadLaneSegmentForLabel:lane.propertyLabel
                           groupKey:lane.groupKey
                            segment:dstSegmentIndex
                             getAPI:getAPI
                             setAPI:setAPI];
  }

  [actAPI endAction:self];
  if (state)
    state.selectionInProgress = NO;
  [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

@end
