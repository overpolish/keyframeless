/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../Views/StageSequencer/KKStagePlayheadView.h"
#import "../../Views/StageSequencer/KKStageSequencerRulerView.h"
#import "../../Views/StageSequencer/KKStageSequencerView.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKTimingStage.h>

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
  seqView.onGroupCollapseToggled = ^(NSString *groupKey, BOOL collapsed) {
    [weakSelf _handleGroupCollapseToggledForKey:groupKey collapsed:collapsed];
  };
  seqView.onGroupSegmentClicked = ^(NSString *groupKey) {
    [weakSelf kkHandleGroupSegmentClickedForKey:groupKey];
  };
  seqView.selectedGroupKey = [weakSelf kkSelectedGroupKey];
  rulerView.onLoopToggled = ^(BOOL newState) {
    [weakSelf _handleRulerLoopToggled:newState];
  };
  rulerView.onPlayheadScrub = ^(double fraction) {
    [weakSelf _handleRulerPlayheadScrubToFraction:fraction];
  };
}

@end
