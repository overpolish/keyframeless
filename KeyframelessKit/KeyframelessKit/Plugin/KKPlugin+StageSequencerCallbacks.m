/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../KKLog.h"
#import "../Math/KKTimingStage.h"
#import "../Views/KKAnimatableProperty.h"
#import "../Views/StageSequencer/KKStagePlayheadView.h"
#import "../Views/StageSequencer/KKStageSequencerRulerView.h"
#import "../Views/StageSequencer/KKStageSequencerView.h"
#import "KKConstants.h"
#import "KKPlugin+Color.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

/// Writes `lanes` to the shared `kKKParamMultiStageData` JSON param. HTH
/// transitions are normalized in-place before serialization so their
/// `values` array always mirrors the preceding hold for non-Bool scalars.
/// Bool scalars are preserved (per-segment step toggles like "rotate with
/// motion" survive normalization). Pass `[self _kindsByLaneLabel]` for
/// `kindsByLabel`; nil falls back to normalize-everything.
static void KKWriteLanesJSON(
    NSArray<KKTimingLane *> *lanes, id<FxParameterSettingAPI_v5> setAPI,
    NSDictionary<NSString *, NSArray<NSNumber *> *> *kindsByLabel) {
  NSMutableArray<KKTimingLane *> *mutableLanes = [lanes mutableCopy];
  KKApplyHTHNormalizationInPlace(mutableLanes, kindsByLabel);
  NSString *updated = [KKTimingLane jsonFromLanes:mutableLanes];
  if (updated)
    [setAPI setStringParameterValue:updated toParameter:kKKParamMultiStageData];
}

/// Looks up the animatable property by `label`, or nil when no match.
static KKAnimatableProperty *
KKPropertyByLabel(NSArray<KKAnimatableProperty *> *props, NSString *label) {
  for (KKAnimatableProperty *p in props) {
    if ([p.label isEqualToString:label])
      return p;
  }
  return nil;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (StageSequencerCallbacks)

- (void)_wireStageSequencerCallbacksFor:(KKStageSequencerView *)seqView
                              rulerView:(KKStageSequencerRulerView *)rulerView
                           playheadView:(KKStagePlayheadView *)playheadView {
  __weak typeof(self) weakSelf = self;
  __weak KKStageSequencerView *weakSeq = seqView;
  __weak KKStageSequencerRulerView *weakRuler = rulerView;
  __weak KKStagePlayheadView *weakPlayhead = playheadView;

  // Keep ruler, lanes, and playhead overlay in lockstep horizontally.
  seqView.onZoomPanChanged = ^(CGFloat z, CGFloat p) {
    weakRuler.zoom = z;
    weakRuler.panOffset = p;
    weakPlayhead.zoom = z;
    weakPlayhead.panOffset = p;
  };
  rulerView.onZoomPanChanged = ^(CGFloat z, CGFloat p) {
    weakSeq.zoom = z;
    weakSeq.panOffset = p;
    weakPlayhead.zoom = z;
    weakPlayhead.panOffset = p;
  };

  seqView.onSegmentSelected = ^(NSInteger laneIndex, NSInteger segmentIndex) {
    [weakSelf _handleSegmentSelectedAtLane:laneIndex segment:segmentIndex];
  };
  seqView.onLaneToggled = ^(NSInteger laneIndex, BOOL enabled) {
    [weakSelf _handleLaneToggledAtIndex:laneIndex enabled:enabled];
  };
  seqView.onLaneOSCVisibilityToggled = ^(NSInteger laneIndex, BOOL visible) {
    [weakSelf _handleLaneOSCVisibilityAtIndex:laneIndex visible:visible];
  };
  seqView.onLaneChanged = ^(NSInteger laneIndex, KKTimingLane *updatedLane) {
    [weakSelf _handleLaneChangedAtIndex:laneIndex lane:updatedLane];
  };
  seqView.onLanesChanged = ^(NSArray<NSNumber *> *laneIndexes,
                             NSArray<KKTimingLane *> *updatedLanes) {
    [weakSelf _handleLanesChangedAtIndexes:laneIndexes lanes:updatedLanes];
  };
  seqView.onSegmentAdded = ^(NSInteger laneIndex, double position) {
    [weakSelf _handleSegmentAddedAtLane:laneIndex position:position];
  };
  seqView.onAllLanesSegmentAdded = ^(double position) {
    [weakSelf _handleAllLanesSegmentAddedAtPosition:position];
  };
  seqView.onAllLanesSegmentLockToggled = ^(double position, BOOL lock) {
    [weakSelf _handleAllLanesSegmentLockToggledAtPosition:position lock:lock];
  };
  seqView.onAllLanesSegmentSelected = ^(double position) {
    [weakSelf _handleAllLanesSegmentSelectedAtPosition:position];
  };
  seqView.onAllLanesSegmentTypesToggled = ^(double position) {
    [weakSelf _handleAllLanesSegmentTypesToggledAtPosition:position];
  };
  seqView.onSegmentRemoved = ^(NSInteger laneIndex, NSInteger segmentIndex) {
    [weakSelf _handleSegmentRemovedAtLane:laneIndex segment:segmentIndex];
  };
  seqView.onAllLanesSegmentRemoved = ^(double position) {
    [weakSelf _handleAllLanesSegmentRemovedAtPosition:position];
  };
  seqView.onSegmentTypeToggled = ^(NSInteger laneIndex,
                                   NSInteger segmentIndex) {
    [weakSelf _handleSegmentTypeToggledAtLane:laneIndex segment:segmentIndex];
  };
  seqView.onSegmentLockToggled =
      ^(NSInteger laneIndex, NSInteger segmentIndex, double newLockedSeconds) {
        [weakSelf _handleSegmentLockToggledAtLane:laneIndex
                                          segment:segmentIndex
                                         duration:newLockedSeconds];
      };
  seqView.onSegmentValuesCopied =
      ^(NSInteger laneIndex, NSInteger srcSegmentIndex,
        NSInteger dstSegmentIndex) {
        [weakSelf _handleSegmentValuesCopiedAtLane:laneIndex
                                               src:srcSegmentIndex
                                               dst:dstSegmentIndex];
      };
  seqView.onSegmentEditRequested =
      ^(NSInteger laneIndex, NSInteger segmentIndex, NSRect anchorRect) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf _showSegmentEditPopoverForLane:laneIndex
                                        segmentIdx:segmentIndex
                                        anchorRect:anchorRect
                                        sourceView:weakSeq];
      };
  seqView.onAllLanesSegmentEditRequested =
      ^(NSInteger laneIndex, NSInteger segmentIndex, NSRect anchorRect) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf _showAllLanesSegmentEditPopoverForLane:laneIndex
                                                segmentIdx:segmentIndex
                                                anchorRect:anchorRect
                                                sourceView:weakSeq];
      };
  rulerView.onLoopToggled = ^(BOOL newState) {
    [weakSelf _handleRulerLoopToggled:newState];
  };
  rulerView.onPlayheadScrub = ^(double fraction) {
    [weakSelf _handleRulerPlayheadScrubToFraction:fraction];
  };
}

#pragma mark - Handlers

- (void)_handleSegmentSelectedAtLane:(NSInteger)laneIndex
                             segment:(NSInteger)segmentIndex {
  if (laneIndex < 0)
    return;
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (!state)
    return;
  state.selectionInProgress = YES;
  NSArray<KKAnimatableProperty *> *props = [self animatableProperties];
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
    return;
  }

  KKTimingLane *lane = lanes[jsonIdx];
  KKAnimatableProperty *prop = KKPropertyByLabel(props, lane.propertyLabel);

  // 1. Write-back: save current native param values into this lane's
  //    previously selected segment.
  NSInteger prevSeg = lane.selectedSegment;
  if (prop.valueParamIDs.count > 0 && prevSeg >= 0 &&
      (NSUInteger)prevSeg < lane.segments.count) {
    NSArray<NSNumber *> *curVals = [prop readValuesWithGetAPI:getAPI atTime:ct];
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

  KKWriteLanesJSON(lanes, setAPI, [self _kindsByLaneLabel]);
  // Update snapshot + clear pending BEFORE endAction (which triggers
  // parameterChanged: that would read stale snapshot).
  state.lanesSnapshot = [lanes copy];
  state.pendingLanes = nil;

  // FxPlug silently drops writes to DISABLED params, so make sure the value
  // params for this lane are enabled while we push the new segment's values.
  // If the new selection is itself HTH, the trailing
  // `_applyHTHParameterFlagsForLanes:` call re-applies the disable.
  for (NSNumber *pidNum in prop.valueParamIDs) {
    UInt32 pid = pidNum.unsignedIntValue;
    FxParameterFlags cur = 0;
    [getAPI getParameterFlags:&cur fromParameter:pid];
    FxParameterFlags want = cur & ~kFxParameterFlag_DISABLED;
    if (cur != want)
      [setAPI setParameterFlags:want toParameter:pid];
  }

  // Sync new selection: write segment values → native params.
  NSArray<NSNumber *> *newVals = nil;
  if (prop.valueParamIDs.count > 0 && segmentIndex >= 0 &&
      (NSUInteger)segmentIndex < lane.segments.count) {
    newVals = lane.segments[segmentIndex].values;
    [prop writeValues:newVals withSetAPI:setAPI atTime:ct];
  }
  [self _applyHTHParameterFlagsForLanes:lanes];

  [actAPI endAction:self];
  state.selectionInProgress = NO;
  // The gradient bar isn't auto-bound to its param; the drawOSC/render
  // sync is both too slow for interactive clicks AND prone to reading a
  // stale string value right after a write. Push the known segment values
  // directly instead. No-op for non-gradient properties.
  if (newVals)
    [KKPlugin colorPushGradientForProperty:prop
                                    values:newVals
                                apiManager:self.apiManager];
  [self timingGraphApplyState];
}

- (void)_handleAllLanesSegmentSelectedAtPosition:(double)position {
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (!state)
    return;
  state.selectionInProgress = YES;
  NSArray<KKAnimatableProperty *> *props = [self animatableProperties];
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
    return;
  }

  // Capture each lane's new (segIdx, values) before writing, so we can push
  // them to native params after the JSON write.
  NSMutableArray<NSNumber *> *newSegPerLane = [NSMutableArray array];
  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    NSInteger newIdx = -1;
    for (NSUInteger si = 0; si < lane.segments.count; si++) {
      KKTimingSegment *s = lane.segments[si];
      if (position >= s.start && position < s.end) {
        newIdx = (NSInteger)si;
        break;
      }
    }
    // Edge: position == 1.0 lands past the last segment's [start, end).
    if (newIdx < 0 && lane.segments.count > 0)
      newIdx = (NSInteger)lane.segments.count - 1;

    KKAnimatableProperty *prop = KKPropertyByLabel(props, lane.propertyLabel);
    KKTimingLane *mLane = [lane copy];
    NSMutableArray *mSegs = [mLane.segments mutableCopy];

    // Write-back native values to the previously selected segment.
    NSInteger prevSeg = lane.selectedSegment;
    if (prop.valueParamIDs.count > 0 && prevSeg >= 0 &&
        (NSUInteger)prevSeg < mSegs.count) {
      NSArray<NSNumber *> *curVals = [prop readValuesWithGetAPI:getAPI
                                                         atTime:ct];
      KKTimingSegment *mSeg = [mSegs[prevSeg] copy];
      mSeg.values = curVals;
      mSegs[prevSeg] = mSeg;
    }
    mLane.segments = mSegs;
    mLane.selectedSegment = newIdx;
    lanes[li] = mLane;
    [newSegPerLane addObject:@(newIdx)];
  }

  KKWriteLanesJSON(lanes, setAPI, [self _kindsByLaneLabel]);
  state.lanesSnapshot = [lanes copy];
  state.pendingLanes = nil;

  // Push each lane's newly-selected segment values into native params. Clear
  // DISABLED on every value param first so writes aren't silently dropped
  // (HTH-selected lanes get the flag re-applied at the end).
  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    NSInteger newIdx = newSegPerLane[li].integerValue;
    KKAnimatableProperty *prop = KKPropertyByLabel(props, lane.propertyLabel);
    if (prop.valueParamIDs.count == 0 || newIdx < 0 ||
        (NSUInteger)newIdx >= lane.segments.count)
      continue;
    for (NSNumber *pidNum in prop.valueParamIDs) {
      UInt32 pid = pidNum.unsignedIntValue;
      FxParameterFlags cur = 0;
      [getAPI getParameterFlags:&cur fromParameter:pid];
      FxParameterFlags want = cur & ~kFxParameterFlag_DISABLED;
      if (cur != want)
        [setAPI setParameterFlags:want toParameter:pid];
    }
    NSArray<NSNumber *> *newVals = lane.segments[newIdx].values;
    [prop writeValues:newVals withSetAPI:setAPI atTime:ct];
    [KKPlugin colorPushGradientForProperty:prop
                                    values:newVals
                                apiManager:self.apiManager];
  }

  [self _applyHTHParameterFlagsForLanes:lanes];

  [actAPI endAction:self];
  state.selectionInProgress = NO;
  [self timingGraphApplyState];
}

- (void)_handleLaneToggledAtIndex:(NSInteger)laneIndex enabled:(BOOL)enabled {
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
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
  KKWriteLanesJSON(mutable, setAPI, [self _kindsByLaneLabel]);

  // Enable-path: native params may have been edited while the lane was
  // disabled. The lane's own segment values are the source of truth, so
  // overwrite native params with the newly-selected segment's values.
  // Without this, the live-param-override in multiStageValuesAtTime: would
  // keep rendering the stale native-param values until the user clicks the
  // segment (which triggers write-back and sync).
  if (enabled && lane.selectedSegment >= 0 &&
      (NSUInteger)lane.selectedSegment < lane.segments.count) {
    KKAnimatableProperty *prop =
        KKPropertyByLabel([self animatableProperties], lane.propertyLabel);
    if (state)
      state.selectionInProgress = YES;
    [prop writeValues:lane.segments[lane.selectedSegment].values
           withSetAPI:setAPI
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
}

- (void)_handleLaneOSCVisibilityAtIndex:(NSInteger)laneIndex
                                visible:(BOOL)visible {
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
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
    KKWriteLanesJSON(lanes, setAPI, [self _kindsByLaneLabel]);
    if (state)
      state.lanesSnapshot = [lanes copy];
  }
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)_handleLaneChangedAtIndex:(NSInteger)laneIndex
                             lane:(KKTimingLane *)updatedLane {
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
    KKWriteLanesJSON(lanes, setAPI, [self _kindsByLaneLabel]);
  }
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)_handleLanesChangedAtIndexes:(NSArray<NSNumber *> *)laneIndexes
                               lanes:(NSArray<KKTimingLane *> *)updatedLanes {
  if (laneIndexes.count == 0 || laneIndexes.count != updatedLanes.count)
    return;
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
  KKWriteLanesJSON(lanes, setAPI, [self _kindsByLaneLabel]);
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)_handleSegmentAddedAtLane:(NSInteger)laneIndex
                         position:(double)position {
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
  if (!lanes || jsonIdx < 0) {
    [actAPI endAction:self];
    return;
  }
  KKTimingLane *lane = [lanes[jsonIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];

  // Find which segment the click landed in and split it.
  NSInteger splitIdx = -1;
  for (NSUInteger i = 0; i < segs.count; i++) {
    if (position >= segs[i].start && position < segs[i].end) {
      splitIdx = (NSInteger)i;
      break;
    }
  }
  if (splitIdx < 0) {
    [actAPI endAction:self];
    return;
  }

  KKTimingSegment *orig = segs[splitIdx];
  double splitPoint = position;

  // Create two segments from the split. Clear any duration lock — the
  // original's `lockedDurationSeconds` targeted the whole width, so
  // inheriting it on both halves would double the intended total.
  KKTimingSegment *left = [orig copy];
  left.end = splitPoint;
  left.lockedDurationSeconds = 0;
  KKTimingSegment *right = [orig copy];
  right.start = splitPoint;
  right.lockedDurationSeconds = 0;

  // Whichever side is closer to the click is treated as the "new" piece
  // and gets the opposite type; the bulk half keeps the original type.
  // Splitting a hold near its trailing edge grows a trailing transition;
  // splitting near its leading edge grows a leading one.
  double midpoint = (orig.start + orig.end) / 2.0;
  KKSegmentType flipped = (orig.type == KKSegmentTypeHold)
                              ? KKSegmentTypeTransition
                              : KKSegmentTypeHold;
  if (splitPoint < midpoint)
    left.type = flipped;
  else
    right.type = flipped;

  [segs replaceObjectAtIndex:splitIdx withObject:left];
  [segs insertObject:right atIndex:splitIdx + 1];

  lane.segments = segs;
  lane.selectedSegment = splitIdx + 1;
  lanes[jsonIdx] = lane;

  KKWriteLanesJSON(lanes, setAPI, [self _kindsByLaneLabel]);
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)_handleAllLanesSegmentAddedAtPosition:(double)position {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  if (!lanes) {
    [actAPI endAction:self];
    return;
  }
  CMTime effectDuration = kCMTimeZero;
  if (timingAPI)
    [timingAPI durationTimeForEffect:&effectDuration];
  double durSec = CMTimeGetSeconds(effectDuration);
  double minFrac = (durSec > 0) ? (0.1 / durSec) : 0.0;

  BOOL anyChanged = NO;
  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = [lanes[li] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];

    NSInteger splitIdx = -1;
    for (NSUInteger i = 0; i < segs.count; i++) {
      if (position >= segs[i].start && position < segs[i].end) {
        splitIdx = (NSInteger)i;
        break;
      }
    }
    if (splitIdx < 0)
      continue;
    KKTimingSegment *orig = segs[splitIdx];
    if (position - orig.start < minFrac || orig.end - position < minFrac)
      continue;

    KKTimingSegment *left = [orig copy];
    left.end = position;
    left.lockedDurationSeconds = 0;
    KKTimingSegment *right = [orig copy];
    right.start = position;
    right.lockedDurationSeconds = 0;

    double midpoint = (orig.start + orig.end) / 2.0;
    KKSegmentType flipped = (orig.type == KKSegmentTypeHold)
                                ? KKSegmentTypeTransition
                                : KKSegmentTypeHold;
    if (position < midpoint)
      left.type = flipped;
    else
      right.type = flipped;

    [segs replaceObjectAtIndex:splitIdx withObject:left];
    [segs insertObject:right atIndex:splitIdx + 1];
    lane.segments = segs;
    if (lane.selectedSegment > splitIdx)
      lane.selectedSegment++;
    lanes[li] = lane;
    anyChanged = YES;
  }

  if (anyChanged)
    KKWriteLanesJSON(lanes, setAPI, [self _kindsByLaneLabel]);
  [actAPI endAction:self];
  if (anyChanged)
    [self timingGraphApplyState];
}

- (void)_handleSegmentRemovedAtLane:(NSInteger)laneIndex
                            segment:(NSInteger)segmentIndex {
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
  if (!lanes || jsonIdx < 0) {
    [actAPI endAction:self];
    return;
  }
  KKTimingLane *lane = [lanes[jsonIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
  if (segs.count <= 1 || (NSUInteger)segmentIndex >= segs.count) {
    [actAPI endAction:self];
    return;
  }

  KKTimingSegment *removed = segs[segmentIndex];
  // Expand the neighbor to fill the gap. Clear its lock too — the
  // neighbor's stored `lockedDurationSeconds` reflects its old width,
  // which no longer matches after absorbing the removed segment's span.
  if ((NSUInteger)segmentIndex + 1 < segs.count) {
    KKTimingSegment *next = [segs[segmentIndex + 1] copy];
    next.start = removed.start;
    next.lockedDurationSeconds = 0;
    segs[segmentIndex + 1] = next;
  } else if (segmentIndex > 0) {
    KKTimingSegment *prev = [segs[segmentIndex - 1] copy];
    prev.end = removed.end;
    prev.lockedDurationSeconds = 0;
    segs[segmentIndex - 1] = prev;
  }
  [segs removeObjectAtIndex:segmentIndex];

  // Fix selection.
  if (lane.selectedSegment == segmentIndex) {
    lane.selectedSegment = -1;
    for (NSUInteger i = 0; i < segs.count; i++) {
      if (segs[i].type == KKSegmentTypeHold) {
        lane.selectedSegment = (NSInteger)i;
        break;
      }
    }
  } else if (lane.selectedSegment > segmentIndex) {
    lane.selectedSegment--;
  }

  lane.segments = segs;
  lanes[jsonIdx] = lane;

  KKWriteLanesJSON(lanes, setAPI, [self _kindsByLaneLabel]);
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)_handleAllLanesSegmentRemovedAtPosition:(double)position {
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
    return;
  }

  BOOL anyChanged = NO;
  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = [lanes[li] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
    if (segs.count <= 1)
      continue;
    NSInteger hitIdx = -1;
    for (NSUInteger i = 0; i < segs.count; i++) {
      if (position >= segs[i].start && position < segs[i].end) {
        hitIdx = (NSInteger)i;
        break;
      }
    }
    if (hitIdx < 0)
      continue;

    KKTimingSegment *removed = segs[hitIdx];
    if ((NSUInteger)hitIdx + 1 < segs.count) {
      KKTimingSegment *next = [segs[hitIdx + 1] copy];
      next.start = removed.start;
      next.lockedDurationSeconds = 0;
      segs[hitIdx + 1] = next;
    } else if (hitIdx > 0) {
      KKTimingSegment *prev = [segs[hitIdx - 1] copy];
      prev.end = removed.end;
      prev.lockedDurationSeconds = 0;
      segs[hitIdx - 1] = prev;
    }
    [segs removeObjectAtIndex:hitIdx];

    if (lane.selectedSegment == hitIdx) {
      lane.selectedSegment = -1;
      for (NSUInteger i = 0; i < segs.count; i++) {
        if (segs[i].type == KKSegmentTypeHold) {
          lane.selectedSegment = (NSInteger)i;
          break;
        }
      }
    } else if (lane.selectedSegment > hitIdx) {
      lane.selectedSegment--;
    }

    lane.segments = segs;
    lanes[li] = lane;
    anyChanged = YES;
  }

  if (anyChanged)
    KKWriteLanesJSON(lanes, setAPI, [self _kindsByLaneLabel]);
  [actAPI endAction:self];
  if (anyChanged)
    [self timingGraphApplyState];
}

- (void)_handleSegmentTypeToggledAtLane:(NSInteger)laneIndex
                                segment:(NSInteger)segmentIndex {
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
  if (!lanes || jsonIdx < 0) {
    [actAPI endAction:self];
    return;
  }
  KKTimingLane *lane = [lanes[jsonIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
  if ((NSUInteger)segmentIndex >= segs.count) {
    [actAPI endAction:self];
    return;
  }
  KKTimingSegment *seg = [segs[segmentIndex] copy];
  seg.type = (seg.type == KKSegmentTypeHold) ? KKSegmentTypeTransition
                                             : KKSegmentTypeHold;
  segs[segmentIndex] = seg;
  lane.segments = segs;
  lanes[jsonIdx] = lane;

  KKWriteLanesJSON(lanes, setAPI, [self _kindsByLaneLabel]);
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)_handleSegmentLockToggledAtLane:(NSInteger)laneIndex
                                segment:(NSInteger)segmentIndex
                               duration:(double)newLockedSeconds {
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
  if (!lanes || jsonIdx < 0) {
    [actAPI endAction:self];
    return;
  }
  KKTimingLane *lane = [lanes[jsonIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
  if ((NSUInteger)segmentIndex >= segs.count) {
    [actAPI endAction:self];
    return;
  }
  KKTimingSegment *seg = [segs[segmentIndex] copy];
  seg.lockedDurationSeconds = MAX(0.0, newLockedSeconds);
  segs[segmentIndex] = seg;
  lane.segments = segs;
  lanes[jsonIdx] = lane;

  KKWriteLanesJSON(lanes, setAPI, [self _kindsByLaneLabel]);
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)_handleAllLanesSegmentTypesToggledAtPosition:(double)position {
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
    return;
  }

  BOOL anyChanged = NO;
  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = [lanes[li] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
    NSInteger hitIdx = -1;
    for (NSUInteger i = 0; i < segs.count; i++) {
      if (position >= segs[i].start && position < segs[i].end) {
        hitIdx = (NSInteger)i;
        break;
      }
    }
    if (hitIdx < 0)
      continue;
    KKTimingSegment *seg = [segs[hitIdx] copy];
    seg.type = (seg.type == KKSegmentTypeHold) ? KKSegmentTypeTransition
                                               : KKSegmentTypeHold;
    segs[hitIdx] = seg;
    lane.segments = segs;
    lanes[li] = lane;
    anyChanged = YES;
  }

  if (anyChanged) {
    KKApplyHTHNormalizationInPlace(lanes, [self _kindsByLaneLabel]);
    NSString *updated = [KKTimingLane jsonFromLanes:lanes];
    if (updated)
      [setAPI setStringParameterValue:updated
                          toParameter:kKKParamMultiStageData];
  }
  [actAPI endAction:self];
  if (anyChanged)
    [self timingGraphApplyState];
}

- (void)_handleAllLanesSegmentLockToggledAtPosition:(double)position
                                               lock:(BOOL)lock {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  if (!lanes) {
    [actAPI endAction:self];
    return;
  }
  CMTime effectDuration = kCMTimeZero;
  if (timingAPI)
    [timingAPI durationTimeForEffect:&effectDuration];
  double durSec = CMTimeGetSeconds(effectDuration);

  BOOL anyChanged = NO;
  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = [lanes[li] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
    NSInteger hitIdx = -1;
    for (NSUInteger i = 0; i < segs.count; i++) {
      if (position >= segs[i].start && position < segs[i].end) {
        hitIdx = (NSInteger)i;
        break;
      }
    }
    if (hitIdx < 0)
      continue;
    KKTimingSegment *seg = [segs[hitIdx] copy];
    double newLocked = lock ? (seg.end - seg.start) * durSec : 0.0;
    if (fabs(seg.lockedDurationSeconds - newLocked) < 1e-6)
      continue;
    seg.lockedDurationSeconds = MAX(0.0, newLocked);
    segs[hitIdx] = seg;
    lane.segments = segs;
    lanes[li] = lane;
    anyChanged = YES;
  }

  if (anyChanged)
    KKWriteLanesJSON(lanes, setAPI, [self _kindsByLaneLabel]);
  [actAPI endAction:self];
  if (anyChanged)
    [self timingGraphApplyState];
}

- (void)_handleSegmentValuesCopiedAtLane:(NSInteger)laneIndex
                                     src:(NSInteger)srcSegmentIndex
                                     dst:(NSInteger)dstSegmentIndex {
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
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
    return;
  }
  KKTimingLane *lane = [lanes[jsonIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
  if ((NSUInteger)srcSegmentIndex >= segs.count ||
      (NSUInteger)dstSegmentIndex >= segs.count ||
      srcSegmentIndex == dstSegmentIndex) {
    [actAPI endAction:self];
    return;
  }
  NSArray<NSNumber *> *newVals = [segs[srcSegmentIndex].values copy];
  KKTimingSegment *dst = [segs[dstSegmentIndex] copy];
  dst.values = newVals;
  segs[dstSegmentIndex] = dst;
  lane.segments = segs;
  lanes[jsonIdx] = lane;

  KKWriteLanesJSON(lanes, setAPI, [self _kindsByLaneLabel]);

  // When the destination is the currently-selected segment, native params
  // still hold its pre-copy values. Push the new values through so the next
  // click on this segment doesn't write the stale native values back into
  // it during onSegmentSelected's write-back step.
  KKAnimatableProperty *prop = nil;
  if (dstSegmentIndex == lane.selectedSegment) {
    prop = KKPropertyByLabel([self animatableProperties], lane.propertyLabel);
    if (prop && prop.valueParamIDs.count > 0) {
      if (state)
        state.selectionInProgress = YES;
      [prop writeValues:newVals withSetAPI:setAPI atTime:ct];
      if (state) {
        state.lanesSnapshot = [lanes copy];
        state.pendingLanes = nil;
      }
    }
  }

  [actAPI endAction:self];
  if (state)
    state.selectionInProgress = NO;
  if (prop)
    [KKPlugin colorPushGradientForProperty:prop
                                    values:newVals
                                apiManager:self.apiManager];
  [self timingGraphApplyState];
}

- (void)_handleRulerLoopToggled:(BOOL)newState {
  // Write the param and stop. The loop-sync pump (runs on every drawOSC and
  // render tick) picks up the change and pushes it back to every ruler
  // (primary + additional). Inspector↔window sync is automatic.
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actAPI)
    return;
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setBoolValue:newState
           toParameter:kKKParamTimingLoopEnabled
                atTime:kCMTimeZero];
  [actAPI endAction:self];
}

- (void)_handleRulerPlayheadScrubToFraction:(double)fraction {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actAPI)
    return;
  [actAPI startAction:self];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  id<FxCommandAPI_v2> commandAPI =
      [self.apiManager apiForProtocol:@protocol(FxCommandAPI_v2)];
  if (timingAPI && commandAPI) {
    CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
    [timingAPI startTimeForEffect:&effectStart];
    [timingAPI durationTimeForEffect:&effectDuration];
    double startSec = CMTimeGetSeconds(effectStart);
    double durSec = CMTimeGetSeconds(effectDuration);
    double targetSec = startSec + fraction * durSec;
    CMTime targetTime = CMTimeMakeWithSeconds(targetSec, 600);
    [commandAPI movePlayheadToTime:targetTime error:nil];
  }
  [actAPI endAction:self];
}

@end
#pragma clang diagnostic pop
