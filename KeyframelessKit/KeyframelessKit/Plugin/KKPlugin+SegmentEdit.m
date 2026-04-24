/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Math/KKEasing.h"
#import "../Math/KKTimingStage.h"
#import "../Views/KKSegmentEditView.h"
#import "../Views/StageSequencer/KKStageSequencerView.h"
#import "KKConstants.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
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
}

- (KKSegmentEditView *)_segmentEditViewForSegment:(KKTimingSegment *)seg
                                   atSegmentIndex:(NSInteger)segmentIndex
                                           inLane:(KKTimingLane *)lane {
  KKSegmentEditKind kind = (seg.type == KKSegmentTypeHold)
                               ? KKSegmentEditKindHold
                               : KKSegmentEditKindTransition;
  NSInteger curveType = (kind == KKSegmentEditKindHold)
                            ? (NSInteger)seg.holdEffect
                            : (NSInteger)seg.easing;

  KKSegmentEditView *content = [[KKSegmentEditView alloc] initWithKind:kind];
  content.curveType = curveType;
  content.intensity = seg.intensity;
  content.frequency = seg.frequency;
  content.seed = seg.seed;
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
                                                         inLane:lane];
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

@end
#pragma clang diagnostic pop
