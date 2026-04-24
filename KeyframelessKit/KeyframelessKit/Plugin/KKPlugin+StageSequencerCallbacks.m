/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

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

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (StageSequencerCallbacks)

- (void)_wireStageSequencerCallbacksFor:(KKStageSequencerView *)seqView
                              rulerView:(KKStageSequencerRulerView *)rulerView
                           playheadView:(KKStagePlayheadView *)playheadView {
  __weak typeof(self) weakSelf = self;

  // Keep ruler, lanes, and playhead overlay in lockstep horizontally.
  __weak KKStageSequencerView *weakSeqForSync = seqView;
  __weak KKStageSequencerRulerView *weakRulerForSync = rulerView;
  __weak KKStagePlayheadView *weakPlayheadForSync = playheadView;
  seqView.onZoomPanChanged = ^(CGFloat z, CGFloat p) {
    weakRulerForSync.zoom = z;
    weakRulerForSync.panOffset = p;
    weakPlayheadForSync.zoom = z;
    weakPlayheadForSync.panOffset = p;
  };
  rulerView.onZoomPanChanged = ^(CGFloat z, CGFloat p) {
    weakSeqForSync.zoom = z;
    weakSeqForSync.panOffset = p;
    weakPlayheadForSync.zoom = z;
    weakPlayheadForSync.panOffset = p;
  };

  seqView.onSegmentSelected = ^(NSInteger laneIndex, NSInteger segmentIndex) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || laneIndex < 0)
      return;
    KKPluginInstanceState *state = KKInstanceStateForAPI(strongSelf.apiManager);
    if (!state)
      return;
    state.selectionInProgress = YES;
    NSArray<KKAnimatableProperty *> *props = [strongSelf animatableProperties];
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    CMTime ct = [actAPI currentTime];

    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSMutableArray<KKTimingLane *> *lanes =
        [[KKTimingLane lanesFromJSON:json] mutableCopy];
    NSInteger jsonIdx =
        KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
    if (!lanes || jsonIdx < 0) {
      [actAPI endAction:strongSelf];
      return;
    }

    KKTimingLane *lane = lanes[jsonIdx];
    KKAnimatableProperty *prop = nil;
    for (KKAnimatableProperty *p in props) {
      if ([p.label isEqualToString:lane.propertyLabel]) {
        prop = p;
        break;
      }
    }

    // 1. Write-back: save current native param values into this lane's
    //    previously selected segment.
    NSInteger prevSeg = lane.selectedSegment;
    if (prop.valueParamIDs.count > 0 && prevSeg >= 0 &&
        (NSUInteger)prevSeg < lane.segments.count) {
      NSArray<NSNumber *> *curVals = [prop readValuesWithGetAPI:getAPI
                                                         atTime:ct];
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

    // 2. Save updated JSON with write-back + new selection.
    NSString *updated = [KKTimingLane jsonFromLanes:lanes];
    if (updated)
      [setAPI setStringParameterValue:updated
                          toParameter:kKKParamMultiStageData];

    // 3. Update snapshot + clear pending BEFORE endAction (which triggers
    //    parameterChanged: that would read stale snapshot).
    state.lanesSnapshot = [lanes copy];
    state.pendingLanes = nil;

    // 4. Sync new selection: write segment values → native params.
    NSArray<NSNumber *> *newVals = nil;
    if (prop.valueParamIDs.count > 0 && segmentIndex >= 0 &&
        (NSUInteger)segmentIndex < lane.segments.count) {
      newVals = lane.segments[segmentIndex].values;
      [prop writeValues:newVals withSetAPI:setAPI atTime:ct];
    }

    [actAPI endAction:strongSelf];
    state.selectionInProgress = NO;
    // The gradient bar isn't auto-bound to its param; the drawOSC/render
    // sync is both too slow for interactive clicks AND prone to reading a
    // stale string value right after a write. Push the known segment
    // values directly instead. No-op for non-gradient properties.
    if (newVals)
      [KKPlugin colorPushGradientForProperty:prop
                                      values:newVals
                                  apiManager:strongSelf.apiManager];
    [strongSelf timingGraphApplyState];
  };

  seqView.onLaneToggled = ^(NSInteger laneIndex, BOOL enabled) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    KKPluginInstanceState *state = KKInstanceStateForAPI(strongSelf.apiManager);
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    CMTime ct = [actAPI currentTime];
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSArray<KKTimingLane *> *lanes = [KKTimingLane lanesFromJSON:json];
    NSInteger jsonIdx =
        KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
    if (lanes && jsonIdx >= 0) {
      NSMutableArray *mutable = [lanes mutableCopy];
      KKTimingLane *lane = [mutable[jsonIdx] copy];
      lane.enabled = enabled;
      if (!enabled) {
        lane.selectedSegment = -1;
      } else {
        lane.selectedSegment = -1;
        for (NSUInteger i = 0; i < lane.segments.count; i++) {
          if (lane.segments[i].type == KKSegmentTypeHold) {
            lane.selectedSegment = (NSInteger)i;
            break;
          }
        }
      }
      mutable[jsonIdx] = lane;
      NSString *updated = [KKTimingLane jsonFromLanes:mutable];
      if (updated)
        [setAPI setStringParameterValue:updated
                            toParameter:kKKParamMultiStageData];

      // Enable-path: native params may have been edited while the lane was
      // disabled. The lane's own segment values are the source of truth, so
      // overwrite native params with the newly-selected segment's values.
      // Without this, the live-param-override in multiStageValuesAtTime:
      // would keep rendering the stale native-param values until the user
      // clicks the segment (which triggers write-back and sync).
      if (enabled && lane.selectedSegment >= 0 &&
          (NSUInteger)lane.selectedSegment < lane.segments.count) {
        NSArray<KKAnimatableProperty *> *props =
            [strongSelf animatableProperties];
        KKAnimatableProperty *prop = nil;
        for (KKAnimatableProperty *p in props) {
          if ([p.label isEqualToString:lane.propertyLabel]) {
            prop = p;
            break;
          }
        }
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
    }
    [actAPI endAction:strongSelf];
    if (state)
      state.selectionInProgress = NO;
    [strongSelf timingGraphApplyState];
  };

  seqView.onLaneOSCVisibilityToggled = ^(NSInteger laneIndex, BOOL visible) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    KKPluginInstanceState *state = KKInstanceStateForAPI(strongSelf.apiManager);
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSMutableArray<KKTimingLane *> *lanes =
        [[KKTimingLane lanesFromJSON:json] mutableCopy];
    NSInteger jsonIdx =
        KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
    if (lanes && jsonIdx >= 0) {
      KKTimingLane *lane = [lanes[jsonIdx] copy];
      lane.oscVisible = visible;
      lanes[jsonIdx] = lane;
      NSString *updated = [KKTimingLane jsonFromLanes:lanes];
      if (updated)
        [setAPI setStringParameterValue:updated
                            toParameter:kKKParamMultiStageData];
      if (state)
        state.lanesSnapshot = [lanes copy];
    }
    [actAPI endAction:strongSelf];
    [strongSelf timingGraphApplyState];
  };

  seqView.onLaneChanged = ^(NSInteger laneIndex, KKTimingLane *updatedLane) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSMutableArray<KKTimingLane *> *lanes =
        [[KKTimingLane lanesFromJSON:json] mutableCopy];
    KKPluginInstanceState *_state =
        KKInstanceStateForAPI(strongSelf.apiManager);
    NSInteger jsonIdx =
        KKLaneJSONIndexForViewIndex(laneIndex, lanes, _state.hiddenLaneLabels);
    if (lanes && jsonIdx >= 0) {
      lanes[jsonIdx] = updatedLane;
      NSString *updated = [KKTimingLane jsonFromLanes:lanes];
      if (updated)
        [setAPI setStringParameterValue:updated
                            toParameter:kKKParamMultiStageData];
    }
    [actAPI endAction:strongSelf];
    [strongSelf timingGraphApplyState];
  };

  seqView.onSegmentAdded = ^(NSInteger laneIndex, double position) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSMutableArray<KKTimingLane *> *lanes =
        [[KKTimingLane lanesFromJSON:json] mutableCopy];
    KKPluginInstanceState *_state =
        KKInstanceStateForAPI(strongSelf.apiManager);
    NSInteger jsonIdx =
        KKLaneJSONIndexForViewIndex(laneIndex, lanes, _state.hiddenLaneLabels);
    if (!lanes || jsonIdx < 0) {
      [actAPI endAction:strongSelf];
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
      [actAPI endAction:strongSelf];
      return;
    }

    KKTimingSegment *orig = segs[splitIdx];
    double splitPoint = position;

    // Create two segments from the split.
    KKTimingSegment *left = [orig copy];
    left.end = splitPoint;
    KKTimingSegment *right = [orig copy];
    right.start = splitPoint;

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

    NSString *updated = [KKTimingLane jsonFromLanes:lanes];
    if (updated)
      [setAPI setStringParameterValue:updated
                          toParameter:kKKParamMultiStageData];
    [actAPI endAction:strongSelf];
    [strongSelf timingGraphApplyState];
  };

  seqView.onSegmentRemoved = ^(NSInteger laneIndex, NSInteger segmentIndex) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSMutableArray<KKTimingLane *> *lanes =
        [[KKTimingLane lanesFromJSON:json] mutableCopy];
    KKPluginInstanceState *_state =
        KKInstanceStateForAPI(strongSelf.apiManager);
    NSInteger jsonIdx =
        KKLaneJSONIndexForViewIndex(laneIndex, lanes, _state.hiddenLaneLabels);
    if (!lanes || jsonIdx < 0) {
      [actAPI endAction:strongSelf];
      return;
    }
    KKTimingLane *lane = [lanes[jsonIdx] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
    if (segs.count <= 1 || (NSUInteger)segmentIndex >= segs.count) {
      [actAPI endAction:strongSelf];
      return;
    }

    KKTimingSegment *removed = segs[segmentIndex];
    // Expand the neighbor to fill the gap.
    if ((NSUInteger)segmentIndex + 1 < segs.count) {
      KKTimingSegment *next = [segs[segmentIndex + 1] copy];
      next.start = removed.start;
      segs[segmentIndex + 1] = next;
    } else if (segmentIndex > 0) {
      KKTimingSegment *prev = [segs[segmentIndex - 1] copy];
      prev.end = removed.end;
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

    NSString *updated = [KKTimingLane jsonFromLanes:lanes];
    if (updated)
      [setAPI setStringParameterValue:updated
                          toParameter:kKKParamMultiStageData];
    [actAPI endAction:strongSelf];
    [strongSelf timingGraphApplyState];
  };

  seqView.onSegmentTypeToggled = ^(NSInteger laneIndex,
                                   NSInteger segmentIndex) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSMutableArray<KKTimingLane *> *lanes =
        [[KKTimingLane lanesFromJSON:json] mutableCopy];
    KKPluginInstanceState *_state =
        KKInstanceStateForAPI(strongSelf.apiManager);
    NSInteger jsonIdx =
        KKLaneJSONIndexForViewIndex(laneIndex, lanes, _state.hiddenLaneLabels);
    if (!lanes || jsonIdx < 0) {
      [actAPI endAction:strongSelf];
      return;
    }
    KKTimingLane *lane = [lanes[jsonIdx] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
    if ((NSUInteger)segmentIndex >= segs.count) {
      [actAPI endAction:strongSelf];
      return;
    }
    KKTimingSegment *seg = [segs[segmentIndex] copy];
    seg.type = (seg.type == KKSegmentTypeHold) ? KKSegmentTypeTransition
                                               : KKSegmentTypeHold;
    segs[segmentIndex] = seg;
    lane.segments = segs;
    lanes[jsonIdx] = lane;

    NSString *updated = [KKTimingLane jsonFromLanes:lanes];
    if (updated)
      [setAPI setStringParameterValue:updated
                          toParameter:kKKParamMultiStageData];
    [actAPI endAction:strongSelf];
    [strongSelf timingGraphApplyState];
  };

  seqView.onSegmentValuesCopied = ^(NSInteger laneIndex,
                                    NSInteger srcSegmentIndex,
                                    NSInteger dstSegmentIndex) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    KKPluginInstanceState *state = KKInstanceStateForAPI(strongSelf.apiManager);
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    CMTime ct = [actAPI currentTime];
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSMutableArray<KKTimingLane *> *lanes =
        [[KKTimingLane lanesFromJSON:json] mutableCopy];
    NSInteger jsonIdx =
        KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
    if (!lanes || jsonIdx < 0) {
      [actAPI endAction:strongSelf];
      return;
    }
    KKTimingLane *lane = [lanes[jsonIdx] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
    if ((NSUInteger)srcSegmentIndex >= segs.count ||
        (NSUInteger)dstSegmentIndex >= segs.count ||
        srcSegmentIndex == dstSegmentIndex) {
      [actAPI endAction:strongSelf];
      return;
    }
    NSArray<NSNumber *> *newVals = [segs[srcSegmentIndex].values copy];
    KKTimingSegment *dst = [segs[dstSegmentIndex] copy];
    dst.values = newVals;
    segs[dstSegmentIndex] = dst;
    lane.segments = segs;
    lanes[jsonIdx] = lane;

    NSString *updated = [KKTimingLane jsonFromLanes:lanes];
    if (updated)
      [setAPI setStringParameterValue:updated
                          toParameter:kKKParamMultiStageData];

    // When the destination is the currently-selected segment, native params
    // still hold its pre-copy values. Push the new values through so the next
    // click on this segment doesn't write the stale native values back into
    // it during onSegmentSelected's write-back step.
    KKAnimatableProperty *prop = nil;
    if (dstSegmentIndex == lane.selectedSegment) {
      for (KKAnimatableProperty *p in [strongSelf animatableProperties]) {
        if ([p.label isEqualToString:lane.propertyLabel]) {
          prop = p;
          break;
        }
      }
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

    [actAPI endAction:strongSelf];
    if (state)
      state.selectionInProgress = NO;
    if (prop)
      [KKPlugin colorPushGradientForProperty:prop
                                      values:newVals
                                  apiManager:strongSelf.apiManager];
    [strongSelf timingGraphApplyState];
  };

  __weak KKStageSequencerView *weakSeqForPopover = seqView;
  seqView.onSegmentEditRequested =
      ^(NSInteger laneIndex, NSInteger segmentIndex, NSRect anchorRect) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
          return;
        [strongSelf _showSegmentEditPopoverForLane:laneIndex
                                        segmentIdx:segmentIndex
                                        anchorRect:anchorRect
                                        sourceView:weakSeqForPopover];
      };

  rulerView.onPlayheadScrub = ^(double fraction) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!actAPI)
      return;
    [actAPI startAction:strongSelf];
    id<FxTimingAPI_v4> timingAPI =
        [strongSelf.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    id<FxCommandAPI_v2> commandAPI =
        [strongSelf.apiManager apiForProtocol:@protocol(FxCommandAPI_v2)];
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
    [actAPI endAction:strongSelf];
  };
}

@end
#pragma clang diagnostic pop
