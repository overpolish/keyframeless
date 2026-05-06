/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation KKPlugin (HandlersStructure)

- (void)_handleSegmentAddedAtLane:(NSInteger)laneIndex
                         position:(double)position {
  BOOL ug = KKBeginUndoGroup(self.apiManager, @"Add Segment");
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
    KKEndUndoGroup(self.apiManager, ug);
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
    KKEndUndoGroup(self.apiManager, ug);
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

  KKWriteLanesJSON(lanes, setAPI, self.apiManager);
  [self kkHandleLaneSegmentMutation:KKLaneSegmentMutationInserted
                               lane:lane
                            atIndex:splitIdx + 1
                             getAPI:getAPI
                             setAPI:setAPI];
  [actAPI endAction:self];
  [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

- (void)_handleAllLanesSegmentAddedAtPosition:(double)position {
  BOOL ug = KKBeginUndoGroup(self.apiManager, @"Add Segments");
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
    KKEndUndoGroup(self.apiManager, ug);
    return;
  }
  CMTime effectDuration = kCMTimeZero;
  if (timingAPI)
    [timingAPI durationTimeForEffect:&effectDuration];
  double durSec = CMTimeGetSeconds(effectDuration);
  double minFrac = (durSec > 0) ? (0.1 / durSec) : 0.0;

  NSSet<NSString *> *pluginHidden =
      [self hiddenAnimatablePropertyLabels] ?: [NSSet set];

  // Collect per-lane mutations so we can fire the subclass hook after the
  // JSON write completes (still inside the action scope).
  NSMutableArray<NSNumber *> *mutatedJsonIndices = [NSMutableArray array];
  NSMutableArray<NSNumber *> *mutatedSegIndices = [NSMutableArray array];
  BOOL anyChanged = NO;
  for (NSUInteger li = 0; li < lanes.count; li++) {
    if (!lanes[li].effectivelyVisibleInSequencer ||
        [pluginHidden containsObject:lanes[li].propertyLabel] ||
        KKLaneIsHiddenByCollapsedGroup(lanes, li))
      continue;
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
    [mutatedJsonIndices addObject:@(li)];
    [mutatedSegIndices addObject:@(splitIdx + 1)];
    anyChanged = YES;
  }

  if (anyChanged) {
    KKWriteLanesJSON(lanes, setAPI, self.apiManager);
    for (NSUInteger m = 0; m < mutatedJsonIndices.count; m++) {
      NSUInteger li = mutatedJsonIndices[m].unsignedIntegerValue;
      [self kkHandleLaneSegmentMutation:KKLaneSegmentMutationInserted
                                   lane:lanes[li]
                                atIndex:mutatedSegIndices[m].integerValue
                                 getAPI:getAPI
                                 setAPI:setAPI];
    }
  }
  [actAPI endAction:self];
  if (anyChanged)
    [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

- (void)_handleSegmentRemovedAtLane:(NSInteger)laneIndex
                            segment:(NSInteger)segmentIndex {
  BOOL ug = KKBeginUndoGroup(self.apiManager, @"Delete Segment");
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
    KKEndUndoGroup(self.apiManager, ug);
    return;
  }
  KKTimingLane *lane = [lanes[jsonIdx] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
  if (segs.count <= 1 || (NSUInteger)segmentIndex >= segs.count) {
    [actAPI endAction:self];
    KKEndUndoGroup(self.apiManager, ug);
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

  KKWriteLanesJSON(lanes, setAPI, self.apiManager);
  [self kkHandleLaneSegmentMutation:KKLaneSegmentMutationRemoved
                               lane:lane
                            atIndex:segmentIndex
                             getAPI:getAPI
                             setAPI:setAPI];
  [actAPI endAction:self];
  [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

- (void)_handleAllLanesSegmentRemovedAtPosition:(double)position {
  BOOL ug = KKBeginUndoGroup(self.apiManager, @"Delete Segments");
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

  NSSet<NSString *> *pluginHidden =
      [self hiddenAnimatablePropertyLabels] ?: [NSSet set];

  NSMutableArray<NSNumber *> *mutatedJsonIndices = [NSMutableArray array];
  NSMutableArray<NSNumber *> *mutatedSegIndices = [NSMutableArray array];
  BOOL anyChanged = NO;
  for (NSUInteger li = 0; li < lanes.count; li++) {
    if (!lanes[li].effectivelyVisibleInSequencer ||
        [pluginHidden containsObject:lanes[li].propertyLabel] ||
        KKLaneIsHiddenByCollapsedGroup(lanes, li))
      continue;
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
    [mutatedJsonIndices addObject:@(li)];
    [mutatedSegIndices addObject:@(hitIdx)];
    anyChanged = YES;
  }

  if (anyChanged) {
    KKWriteLanesJSON(lanes, setAPI, self.apiManager);
    for (NSUInteger m = 0; m < mutatedJsonIndices.count; m++) {
      NSUInteger li = mutatedJsonIndices[m].unsignedIntegerValue;
      [self kkHandleLaneSegmentMutation:KKLaneSegmentMutationRemoved
                                   lane:lanes[li]
                                atIndex:mutatedSegIndices[m].integerValue
                                 getAPI:getAPI
                                 setAPI:setAPI];
    }
  }
  [actAPI endAction:self];
  if (anyChanged)
    [self timingGraphApplyState];
  KKEndUndoGroup(self.apiManager, ug);
}

@end
