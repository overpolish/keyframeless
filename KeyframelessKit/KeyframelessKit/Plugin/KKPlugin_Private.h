/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "KKPlugin.h"
#import <FxPlug/FxPlugSDK.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

@class KKCustomGroupHeaderView;
@class KKStagePlayheadView;
@class KKStageSequencerRulerView;
@class KKStageSequencerView;
@class KKTimingGraphView;
@class KKTimingLane;

/// Returns `lanes` with every lane whose `propertyLabel` is in `hidden`
/// removed. Shared between the custom-view setup and the multi-stage pump
/// so every push to `seq.lanes` applies the same visibility filter.
extern NSArray<KKTimingLane *> *
KKFilterLanesForVisibility(NSArray<KKTimingLane *> *lanes,
                           NSSet<NSString *> *_Nullable hidden);

@interface KKPlugin () <FxCustomParameterViewHost_v2>

@property(nonatomic, weak, nullable) KKCustomGroupHeaderView *timingHeader;
@property(nonatomic, weak, nullable) KKTimingGraphView *timingGraph;
@property(nonatomic, weak, nullable) KKStageSequencerView *stageSequencer;
@property(nonatomic, weak, nullable) NSView *stageSequencerContainer;
@property(nonatomic, weak, nullable)
    KKStageSequencerRulerView *stageSequencerRuler;
@property(nonatomic, strong, nullable) NSPopover *segmentEditPopover;

@end

@interface KKPlugin (ColorViews)
- (NSView *)_createColorCustomUI:(UInt32)parameterID;
@end

@interface KKPlugin (TimingGraph)
- (void)timingGraphApplyState;
- (void)_showSegmentEditPopoverForLane:(NSInteger)laneIndex
                            segmentIdx:(NSInteger)segmentIndex
                            anchorRect:(NSRect)anchorRect
                            sourceView:
                                (nullable KKStageSequencerView *)sourceView;
@end

@interface KKPlugin (MultiStagePumpInternal)
/// Wires a newly-created sequencer view into per-instance state. Generates
/// a UUID if this instance doesn't yet have one (`kKKParamInstanceID`), and
/// caches the effect's start/duration via `FxTimingAPI` — both inside an
/// `startAction:/endAction:` scope where the needed APIs are live.
/// Call from `createViewForParameterID:` right after building the view.
- (void)_registerMultiStageSequencerView:(KKStageSequencerView *)view
                               rulerView:(KKStageSequencerRulerView *)ruler
                            playheadView:(KKStagePlayheadView *)playhead;
@end

// FxPlug calls createViewForParameterID: on a fresh plugin instance, not the
// one that ran addParametersWithError:. Store parameter metadata at class level
// (keyed by the concrete plugin class) so any instance can look it up.
static const void *_Nonnull const kKKSepTexts = &kKKSepTexts;
static const void *_Nonnull const kKKSepIcons = &kKKSepIcons;
static const void *_Nonnull const kKKInfoTexts = &kKKInfoTexts;
static const void *_Nonnull const kKKInfoAttrTexts = &kKKInfoAttrTexts;
static const void *_Nonnull const kKKInfoIcons = &kKKInfoIcons;
static const void *_Nonnull const kKKTimingExtraIDs = &kKKTimingExtraIDs;
static const void *_Nonnull const kKKLinkedPairs = &kKKLinkedPairs;
static const void *_Nonnull const kKKLinkedLocking = &kKKLinkedLocking;
static const void *_Nonnull const kKKLinkedRatio = &kKKLinkedRatio;
static const void *_Nonnull const kKKLinkedSource = &kKKLinkedSource;

static inline NSMutableDictionary<NSNumber *, id> *
kkClassRegistry(Class cls, const void *_Nonnull key) {
  NSMutableDictionary *dict = objc_getAssociatedObject(cls, key);
  if (!dict) {
    dict = [NSMutableDictionary new];
    objc_setAssociatedObject(cls, key, dict, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return dict;
}

NS_ASSUME_NONNULL_END
