/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../../Math/KKEasing.h"
#import "../../Math/KKTimingStage.h"
#import "../../Views/KKAnimatableProperty.h"
#import "../../Views/KKSegmentEditView.h"
#import "../../Views/StageSequencer/KKStageSequencerView.h"
#import "../KKConstants.h"
#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (SegmentEdit)

- (void)_mutateMultiStageSegmentAtLane:(NSInteger)laneIndex
                            segmentIdx:(NSInteger)segmentIndex
                                 using:(void (^)(KKTimingSegment *))mutator {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  if (!lanes || (NSUInteger)laneIndex >= lanes.count) {
    [actAPI endAction:self];
    return;
  }
  KKTimingLane *lane = [lanes[laneIndex] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
  if ((NSUInteger)segmentIndex >= segs.count) {
    [actAPI endAction:self];
    return;
  }
  KKTimingSegment *seg = [segs[segmentIndex] copy];
  mutator(seg);
  segs[segmentIndex] = seg;
  lane.segments = segs;
  lanes[laneIndex] = lane;

  KKApplyHTHNormalizationInPlace(lanes, [self _kindsByLaneLabel]);
  NSString *updated = [KKTimingLane jsonFromLanes:lanes];
  if (updated)
    [setAPI setStringParameterValue:updated toParameter:kKKParamMultiStageData];
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

/// Apply `mutator` to every (lane, segment) pair in `targets`, written as one
/// atomic action so the change is a single undo step.
- (void)
    _mutateMultiStageSegmentsAtTargets:
        (NSArray<NSValue *> *)targets // each NSValue wraps NSPoint{lane,seg}
                                 using:(void (^)(KKTimingSegment *))mutator {
  if (targets.count == 0)
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
  if (!lanes) {
    [actAPI endAction:self];
    return;
  }
  for (NSValue *v in targets) {
    NSPoint p = v.pointValue;
    NSInteger li = (NSInteger)p.x;
    NSInteger si = (NSInteger)p.y;
    if ((NSUInteger)li >= lanes.count)
      continue;
    KKTimingLane *lane = [lanes[li] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
    if ((NSUInteger)si >= segs.count)
      continue;
    KKTimingSegment *seg = [segs[si] copy];
    mutator(seg);
    segs[si] = seg;
    lane.segments = segs;
    lanes[li] = lane;
  }
  KKApplyHTHNormalizationInPlace(lanes, [self _kindsByLaneLabel]);
  NSString *updated = [KKTimingLane jsonFromLanes:lanes];
  if (updated)
    [setAPI setStringParameterValue:updated toParameter:kKKParamMultiStageData];
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)_wireSegmentEditCallbacks:(KKSegmentEditView *)content
                          forLane:(NSInteger)laneIndex
                          segment:(NSInteger)segmentIndex {
  __weak typeof(self) weakSelf = self;
  content.onCurveTypeChanged = ^(NSInteger ct) {
    [weakSelf _mutateMultiStageSegmentAtLane:laneIndex
                                  segmentIdx:segmentIndex
                                       using:^(KKTimingSegment *s) {
                                         if (s.type == KKSegmentTypeHold)
                                           s.holdEffect = (KKHoldEffect)ct;
                                         else
                                           s.easing = (KKEasingCurve)ct;
                                       }];
  };
  content.onIntensityChanged = ^(double v) {
    [weakSelf _mutateMultiStageSegmentAtLane:laneIndex
                                  segmentIdx:segmentIndex
                                       using:^(KKTimingSegment *s) {
                                         s.intensity = v;
                                       }];
  };
  content.onFrequencyChanged = ^(double v) {
    [weakSelf _mutateMultiStageSegmentAtLane:laneIndex
                                  segmentIdx:segmentIndex
                                       using:^(KKTimingSegment *s) {
                                         s.frequency = v;
                                       }];
  };
  content.onSeedChanged = ^(uint32_t newSeed) {
    [weakSelf _mutateMultiStageSegmentAtLane:laneIndex
                                  segmentIdx:segmentIndex
                                       using:^(KKTimingSegment *s) {
                                         s.seed = newSeed;
                                       }];
  };
  __weak KKSegmentEditView *weakContent = content;
  content.onSeedReroll = ^{
    uint32_t newSeed = arc4random();
    [weakSelf _mutateMultiStageSegmentAtLane:laneIndex
                                  segmentIdx:segmentIndex
                                       using:^(KKTimingSegment *s) {
                                         s.seed = newSeed;
                                       }];
    weakContent.seed = newSeed;
  };
  content.onLinkedChanged = ^(BOOL linked) {
    [weakSelf _mutateMultiStageSegmentAtLane:laneIndex
                                  segmentIdx:segmentIndex
                                       using:^(KKTimingSegment *s) {
                                         s.linked = linked;
                                       }];
  };
}

- (void)_wireBulkSegmentEditCallbacks:(KKSegmentEditView *)content
                              targets:(NSArray<NSValue *> *)targets {
  __weak typeof(self) weakSelf = self;
  NSArray<NSValue *> *capturedTargets = [targets copy];
  content.onCurveTypeChanged = ^(NSInteger ct) {
    [weakSelf _mutateMultiStageSegmentsAtTargets:capturedTargets
                                           using:^(KKTimingSegment *s) {
                                             if (s.type == KKSegmentTypeHold)
                                               s.holdEffect = (KKHoldEffect)ct;
                                             else
                                               s.easing = (KKEasingCurve)ct;
                                           }];
  };
  content.onIntensityChanged = ^(double v) {
    [weakSelf _mutateMultiStageSegmentsAtTargets:capturedTargets
                                           using:^(KKTimingSegment *s) {
                                             s.intensity = v;
                                           }];
  };
  content.onFrequencyChanged = ^(double v) {
    [weakSelf _mutateMultiStageSegmentsAtTargets:capturedTargets
                                           using:^(KKTimingSegment *s) {
                                             s.frequency = v;
                                           }];
  };
  content.onSeedChanged = ^(uint32_t newSeed) {
    [weakSelf _mutateMultiStageSegmentsAtTargets:capturedTargets
                                           using:^(KKTimingSegment *s) {
                                             s.seed = newSeed;
                                           }];
  };
  __weak KKSegmentEditView *weakContent = content;
  content.onSeedReroll = ^{
    uint32_t newSeed = arc4random();
    [weakSelf _mutateMultiStageSegmentsAtTargets:capturedTargets
                                           using:^(KKTimingSegment *s) {
                                             s.seed = newSeed;
                                           }];
    weakContent.seed = newSeed;
  };
  content.onLinkedChanged = ^(BOOL linked) {
    [weakSelf _mutateMultiStageSegmentsAtTargets:capturedTargets
                                           using:^(KKTimingSegment *s) {
                                             s.linked = linked;
                                           }];
  };
}

- (KKSegmentEditView *)_segmentEditViewForSegment:(KKTimingSegment *)seg
                                   atSegmentIndex:(NSInteger)segmentIndex
                                           inLane:(KKTimingLane *)lane
                                             bulk:(BOOL)bulk {
  KKSegmentEditKind kind = (seg.type == KKSegmentTypeHold)
                               ? KKSegmentEditKindHold
                               : KKSegmentEditKindTransition;
  NSInteger curveType = (kind == KKSegmentEditKindHold)
                            ? (NSInteger)seg.holdEffect
                            : (NSInteger)seg.easing;

  // Linked toggle is only meaningful on hold segments whose lane has more
  // than one scalar component (e.g. Position, Radius X/Y).
  BOOL showsLinked = NO;
  if (kind == KKSegmentEditKindHold) {
    for (KKAnimatableProperty *p in [self animatableProperties]) {
      if ([p.label isEqualToString:lane.propertyLabel]) {
        showsLinked = p.valueCount > 1;
        break;
      }
    }
  }

  KKSegmentEditView *content =
      [[KKSegmentEditView alloc] initWithKind:kind
                                  showsLinked:showsLinked
                                   bulkHeader:bulk];
  content.curveType = curveType;
  content.intensity = seg.intensity;
  content.frequency = seg.frequency;
  content.seed = seg.seed;
  content.linked = seg.linked;
  content.animateOut = (kind == KKSegmentEditKindTransition) &&
                       (segmentIndex == (NSInteger)lane.segments.count - 1);
  return content;
}

- (void)_showSegmentEditPopoverForLane:(NSInteger)laneIndex
                            segmentIdx:(NSInteger)segmentIndex
                            anchorRect:(NSRect)anchorRect
                            sourceView:(KKStageSequencerView *)sourceView {
  KKStageSequencerView *seq = sourceView ?: self.stageSequencer;
  if (!seq)
    return;

  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  [actAPI endAction:self];

  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  // Translate view index → JSON index up front; forward the JSON index to
  // every callback below so they don't have to repeat the translation.
  NSInteger jsonLaneIdx =
      KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
  if (!lanes || jsonLaneIdx < 0)
    return;
  KKTimingLane *lane = lanes[jsonLaneIdx];
  if ((NSUInteger)segmentIndex >= lane.segments.count)
    return;
  KKTimingSegment *seg = lane.segments[segmentIndex];

  KKSegmentEditView *content = [self _segmentEditViewForSegment:seg
                                                 atSegmentIndex:segmentIndex
                                                         inLane:lane
                                                           bulk:NO];
  [self _wireSegmentEditCallbacks:content
                          forLane:jsonLaneIdx
                          segment:segmentIndex];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = content;

  NSPopover *popover = [[NSPopover alloc] init];
  popover.behavior = NSPopoverBehaviorTransient;
  popover.animates = YES;
  popover.contentViewController = vc;
  popover.contentSize = content.frame.size;

  [self.segmentEditPopover close];
  self.segmentEditPopover = popover;

  [popover showRelativeToRect:anchorRect
                       ofView:seq
                preferredEdge:NSRectEdgeMaxY];
}

- (void)_showAllLanesSegmentEditPopoverForLane:(NSInteger)laneIndex
                                    segmentIdx:(NSInteger)segmentIndex
                                    anchorRect:(NSRect)anchorRect
                                    sourceView:
                                        (KKStageSequencerView *)sourceView {
  KKStageSequencerView *seq = sourceView ?: self.stageSequencer;
  if (!seq)
    return;

  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  [actAPI endAction:self];

  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  NSInteger jsonLaneIdx =
      KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
  if (!lanes || jsonLaneIdx < 0)
    return;
  KKTimingLane *srcLane = lanes[jsonLaneIdx];
  if ((NSUInteger)segmentIndex >= srcLane.segments.count)
    return;
  KKTimingSegment *srcSeg = srcLane.segments[segmentIndex];

  // Snapshot the bulk target set: every lane whose currently-selected
  // segment matches the source segment's type. The source itself is always
  // included even if not pre-selected, so a shift+click on an unselected
  // segment still does something predictable.
  NSMutableArray<NSValue *> *targets = [NSMutableArray array];
  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    NSInteger sel = lane.selectedSegment;
    if (sel < 0 || (NSUInteger)sel >= lane.segments.count)
      continue;
    if (lane.segments[sel].type != srcSeg.type)
      continue;
    [targets addObject:[NSValue valueWithPoint:NSMakePoint(li, sel)]];
  }
  NSValue *srcVal =
      [NSValue valueWithPoint:NSMakePoint(jsonLaneIdx, segmentIndex)];
  if (![targets containsObject:srcVal])
    [targets addObject:srcVal];

  KKSegmentEditView *content = [self _segmentEditViewForSegment:srcSeg
                                                 atSegmentIndex:segmentIndex
                                                         inLane:srcLane
                                                           bulk:YES];
  [self _wireBulkSegmentEditCallbacks:content targets:targets];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = content;

  NSPopover *popover = [[NSPopover alloc] init];
  popover.behavior = NSPopoverBehaviorTransient;
  popover.animates = YES;
  popover.contentViewController = vc;
  popover.contentSize = content.frame.size;

  [self.segmentEditPopover close];
  self.segmentEditPopover = popover;

  [popover showRelativeToRect:anchorRect
                       ofView:seq
                preferredEdge:NSRectEdgeMaxY];
}

@end
#pragma clang diagnostic pop
