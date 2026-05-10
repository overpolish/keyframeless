/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../Math/KKEasing.h"
#import "../../Math/KKTimingEvaluation.h"
#import "../../Math/KKTimingStage.h"
#import "../../Views/KKSegmentEditView.h"
#import "../../Views/StageSequencer/KKStageSequencerView.h"
#import "../KKConstants.h"
#import "../KKDataBlob.h"
#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

static inline NSValue *_KKTarget(NSInteger lane, NSInteger seg) {
  return [NSValue valueWithPoint:NSMakePoint(lane, seg)];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (SegmentEdit)

#pragma mark - Mutation

/// Apply `mutator` to every (lane, segment) pair in `targets`. When
/// `segmentEditDragUndoActive` is YES the outer drag wrapper holds the
/// action scope + undo group; this method just reads → mutates → writes
/// → pushes lanes to the sequencer view directly. Otherwise opens its own
/// scope and ends with a full `timingGraphApplyState`.
- (void)_mutateMultiStageSegmentsAtTargets:(NSArray<NSValue *> *)targets
                                     using:
                                         (void (^)(KKTimingSegment *))mutator {
  if (targets.count == 0)
    return;

  BOOL inDrag = self.segmentEditDragUndoActive;
  NSString *undoName = (targets.count > 1) ? @"Edit Segments" : @"Edit Segment";
  BOOL ug = inDrag ? NO : KKBeginUndoGroup(self.apiManager, undoName);
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!inDrag)
    [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  if (!lanes) {
    if (!inDrag) {
      [actAPI endAction:self];
      KKEndUndoGroup(self.apiManager, ug);
    }
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

  KKApplyHTHNormalizationInPlace(lanes);
  NSString *updated = [KKTimingLane jsonFromLanes:lanes];
  if (updated)
    KKWriteMultiStageJSONDeduped(updated, setAPI, self.apiManager);

  if (!inDrag) {
    [actAPI endAction:self];
    [self timingGraphApplyState];
    KKEndUndoGroup(self.apiManager, ug);
  } else {
    [self _pushLanesToSequencerDuringDrag:lanes];
  }
}

/// Direct seq.lanes push (no action scope). Called only inside a held
/// drag scope where `timingGraphApplyState`'s own startAction would
/// conflict with the outer one.
- (void)_pushLanesToSequencerDuringDrag:(NSArray<KKTimingLane *> *)lanes {
  KKPluginInstanceState *st = KKInstanceStateForAPI(self.apiManager);
  st.lanesSnapshot = [lanes copy];
  NSArray<KKTimingLane *> *visible =
      KKFilterLanesForVisibility(lanes, st.hiddenLaneLabels);
  KKStageSequencerView *seq = self.stageSequencer;
  NSArray<KKTimingViewRefs *> *extras = [st.additionalTimingViews copy] ?: @[];
  dispatch_async(dispatch_get_main_queue(), ^{
    seq.lanes = visible;
    for (KKTimingViewRefs *r in extras)
      r.seqView.lanes = visible;
  });
}

#pragma mark - Drag undo wrapper

/// Holds an outer FxPlug action scope + undo group across a slider drag
/// so per-tick mutator calls coalesce into one host undo entry. FxUndoAPI
/// only resolves inside an action scope; the per-tick mutator detects
/// `segmentEditDragUndoActive` and skips its own bracketing.
- (void)_wireSegmentEditDragUndo:(KKSegmentEditView *)content {
  __weak typeof(self) weakSelf = self;
  content.onSliderDragBegin = ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || strongSelf.segmentEditDragUndoActive)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!actAPI)
      return;
    [actAPI startAction:strongSelf];
    KKBeginUndoGroup(strongSelf.apiManager, @"Edit Segment");
    strongSelf.segmentEditDragUndoActive = YES;
  };
  content.onSliderDragEnd = ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.segmentEditDragUndoActive)
      return;
    KKEndUndoGroup(strongSelf.apiManager, YES);
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI endAction:strongSelf];
    strongSelf.segmentEditDragUndoActive = NO;
  };
}

#pragma mark - Callback wiring

/// Wires every `KKSegmentEditView` callback to mutate `targets`. Pass a
/// one-element array for single-segment edits, a multi-element array for
/// shift+click bulk edits. Drag-undo wrapping is handled here too.
- (void)_wireSegmentEditCallbacks:(KKSegmentEditView *)content
                          targets:(NSArray<NSValue *> *)targets {
  [self _wireSegmentEditDragUndo:content];
  __weak typeof(self) weakSelf = self;
  __weak KKSegmentEditView *weakContent = content;
  NSArray<NSValue *> *captured = [targets copy];

  content.onCurveTypeChanged = ^(NSInteger ct) {
    [weakSelf _mutateMultiStageSegmentsAtTargets:captured
                                           using:^(KKTimingSegment *s) {
                                             if (s.type == KKSegmentTypeHold)
                                               s.holdEffect = (KKHoldEffect)ct;
                                             else
                                               s.easing = (KKEasingCurve)ct;
                                           }];
  };
  content.onIntensityChanged = ^(double v) {
    [weakSelf _mutateMultiStageSegmentsAtTargets:captured
                                           using:^(KKTimingSegment *s) {
                                             s.intensity = v;
                                           }];
  };
  content.onFrequencyChanged = ^(double v) {
    [weakSelf _mutateMultiStageSegmentsAtTargets:captured
                                           using:^(KKTimingSegment *s) {
                                             s.frequency = v;
                                           }];
  };
  content.onSeedChanged = ^(uint32_t newSeed) {
    [weakSelf _mutateMultiStageSegmentsAtTargets:captured
                                           using:^(KKTimingSegment *s) {
                                             s.seed = newSeed;
                                           }];
  };
  content.onSeedReroll = ^{
    uint32_t newSeed = arc4random();
    [weakSelf _mutateMultiStageSegmentsAtTargets:captured
                                           using:^(KKTimingSegment *s) {
                                             s.seed = newSeed;
                                           }];
    weakContent.seed = newSeed;
  };
  content.onLinkedChanged = ^(BOOL linked) {
    [weakSelf _mutateMultiStageSegmentsAtTargets:captured
                                           using:^(KKTimingSegment *s) {
                                             s.linked = linked;
                                           }];
  };
}

#pragma mark - Content view construction

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
    NSUInteger expanded = 0;
    for (NSNumber *k in lane.valueComponentKinds) {
      switch ((KKAnimatableParamKind)k.integerValue) {
      case KKAnimatableParamKindColor:
        expanded += 3;
        break;
      case KKAnimatableParamKindPoint:
        expanded += 2;
        break;
      case KKAnimatableParamKindGradient:
        break;
      default:
        expanded += 1;
        break;
      }
    }
    showsLinked = expanded > 1;
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

#pragma mark - Popover plumbing

/// Reads the current lane snapshot inside a transient action scope —
/// the only place `FxParameterRetrievalAPI_v6` resolves from a
/// custom-view callback. Used by popover-show methods that need the
/// latest lanes outside any pre-existing scope.
- (NSArray<KKTimingLane *> *)_readLanesInTransientActionScope {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, getAPI);
  [actAPI endAction:self];
  return lanes;
}

/// Builds the NSPopover, replaces any existing `segmentEditPopover`,
/// and shows it relative to `anchor` of `sourceView`. Caller is
/// responsible for assigning `segmentEditPopoverRefresh` afterwards.
- (NSPopover *)
    _installSegmentEditPopoverWithContent:(KKSegmentEditView *)content
                                   anchor:(NSRect)anchor
                               sourceView:(KKStageSequencerView *)seq {
  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = content;

  NSPopover *popover = [[NSPopover alloc] init];
  popover.behavior = NSPopoverBehaviorTransient;
  popover.animates = YES;
  popover.delegate = self;
  popover.contentViewController = vc;
  popover.contentSize = content.frame.size;

  [self.segmentEditPopover close];
  self.segmentEditPopover = popover;

  [popover showRelativeToRect:anchor ofView:seq preferredEdge:NSRectEdgeMaxY];
  return popover;
}

/// Returns a closure that, given the latest lanes, repushes the source
/// segment's curve/intensity/frequency/seed/linked into `content` (used
/// when the popover is open and host undo/redo flips the underlying
/// JSON). Closes `popover` if the source segment is gone or its type
/// flipped (hold ⇄ transition no longer matches the popover's kind).
- (void (^)(NSArray<KKTimingLane *> *))
    _makeSegmentEditPopoverRefreshFor:(KKSegmentEditView *)content
                                 kind:(KKSegmentEditKind)kind
                                 lane:(NSInteger)laneIdx
                              segment:(NSInteger)segmentIdx
                              popover:(NSPopover *)popover {
  __weak KKSegmentEditView *weakContent = content;
  __weak NSPopover *weakPopover = popover;
  KKSegmentType expectedType = (kind == KKSegmentEditKindHold)
                                   ? KKSegmentTypeHold
                                   : KKSegmentTypeTransition;
  return ^(NSArray<KKTimingLane *> *latestLanes) {
    KKSegmentEditView *c = weakContent;
    if (!c)
      return;
    if ((NSUInteger)laneIdx >= latestLanes.count) {
      [weakPopover close];
      return;
    }
    KKTimingLane *latestLane = latestLanes[laneIdx];
    if ((NSUInteger)segmentIdx >= latestLane.segments.count) {
      [weakPopover close];
      return;
    }
    KKTimingSegment *latestSeg = latestLane.segments[segmentIdx];
    if (latestSeg.type != expectedType) {
      [weakPopover close];
      return;
    }
    c.curveType = (kind == KKSegmentEditKindHold)
                      ? (NSInteger)latestSeg.holdEffect
                      : (NSInteger)latestSeg.easing;
    c.intensity = latestSeg.intensity;
    c.frequency = latestSeg.frequency;
    c.seed = latestSeg.seed;
    c.linked = latestSeg.linked;
  };
}

#pragma mark - Popover entry points

- (void)_showSegmentEditPopoverForLane:(NSInteger)laneIndex
                            segmentIdx:(NSInteger)segmentIndex
                            anchorRect:(NSRect)anchorRect
                            sourceView:(KKStageSequencerView *)sourceView {
  KKStageSequencerView *seq = sourceView ?: self.stageSequencer;
  if (!seq)
    return;

  NSArray<KKTimingLane *> *lanes = [self _readLanesInTransientActionScope];
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  // View index → JSON index up front; callbacks store the JSON index.
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
                          targets:@[ _KKTarget(jsonLaneIdx, segmentIndex) ]];

  NSPopover *popover = [self _installSegmentEditPopoverWithContent:content
                                                            anchor:anchorRect
                                                        sourceView:seq];

  KKSegmentEditKind kind = (seg.type == KKSegmentTypeHold)
                               ? KKSegmentEditKindHold
                               : KKSegmentEditKindTransition;
  self.segmentEditPopoverRefresh =
      [self _makeSegmentEditPopoverRefreshFor:content
                                         kind:kind
                                         lane:jsonLaneIdx
                                      segment:segmentIndex
                                      popover:popover];
}

- (void)_showAllLanesSegmentEditPopoverForLane:(NSInteger)laneIndex
                                    segmentIdx:(NSInteger)segmentIndex
                                    anchorRect:(NSRect)anchorRect
                                    sourceView:
                                        (KKStageSequencerView *)sourceView {
  KKStageSequencerView *seq = sourceView ?: self.stageSequencer;
  if (!seq)
    return;

  NSArray<KKTimingLane *> *lanes = [self _readLanesInTransientActionScope];
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  NSInteger jsonLaneIdx =
      KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
  if (!lanes || jsonLaneIdx < 0)
    return;
  KKTimingLane *srcLane = lanes[jsonLaneIdx];
  if ((NSUInteger)segmentIndex >= srcLane.segments.count)
    return;
  KKTimingSegment *srcSeg = srcLane.segments[segmentIndex];

  // Bulk target set: every lane whose currently-selected segment is the
  // same type as the source. The source itself is always included even
  // if not pre-selected, so a shift+click on an unselected segment still
  // does something predictable.
  NSMutableArray<NSValue *> *targets = [NSMutableArray array];
  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    NSInteger sel = lane.selectedSegment;
    if (sel < 0 || (NSUInteger)sel >= lane.segments.count)
      continue;
    if (lane.segments[sel].type != srcSeg.type)
      continue;
    [targets addObject:_KKTarget(li, sel)];
  }
  NSValue *srcTarget = _KKTarget(jsonLaneIdx, segmentIndex);
  if (![targets containsObject:srcTarget])
    [targets addObject:srcTarget];

  KKSegmentEditView *content = [self _segmentEditViewForSegment:srcSeg
                                                 atSegmentIndex:segmentIndex
                                                         inLane:srcLane
                                                           bulk:YES];
  [self _wireSegmentEditCallbacks:content targets:targets];

  NSPopover *popover = [self _installSegmentEditPopoverWithContent:content
                                                            anchor:anchorRect
                                                        sourceView:seq];

  KKSegmentEditKind kind = (srcSeg.type == KKSegmentTypeHold)
                               ? KKSegmentEditKindHold
                               : KKSegmentEditKindTransition;
  self.segmentEditPopoverRefresh =
      [self _makeSegmentEditPopoverRefreshFor:content
                                         kind:kind
                                         lane:jsonLaneIdx
                                      segment:segmentIndex
                                      popover:popover];
}

- (void)popoverDidClose:(NSNotification *)notification {
  if (notification.object == self.segmentEditPopover) {
    self.segmentEditPopover = nil;
    self.segmentEditPopoverRefresh = nil;
  }
}

@end
#pragma clang diagnostic pop
