/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "KKPlugin.h"
#import <FxPlug/FxPlugSDK.h>
#import <objc/runtime.h>

@class KKCustomGroupHeaderView;
@class KKStageSequencerView;
@class KKTimingGraphView;

@interface KKPlugin () <FxCustomParameterViewHost_v2>

@property(nonatomic, weak) KKCustomGroupHeaderView *timingHeader;
@property(nonatomic, weak) KKTimingGraphView *timingGraph;
@property(nonatomic, weak) KKStageSequencerView *stageSequencer;
@property(nonatomic, strong, nullable) NSPopover *segmentEditPopover;

@end

@interface KKPlugin (ColorViews)
- (NSView *)_createColorCustomUI:(UInt32)parameterID;
@end

@interface KKPlugin (TimingGraph)
- (void)timingGraphApplyState;
- (void)_showSegmentEditPopoverForLane:(NSInteger)laneIndex
                            segmentIdx:(NSInteger)segmentIndex
                            anchorRect:(NSRect)anchorRect;
@end

@interface KKPlugin (MultiStagePumpInternal)
/// Wires a newly-created sequencer view into per-instance state. Generates
/// a UUID if this instance doesn't yet have one (`kKKParamInstanceID`), and
/// caches the effect's start/duration via `FxTimingAPI` — both inside an
/// `startAction:/endAction:` scope where the needed APIs are live.
/// Call from `createViewForParameterID:` right after building the view.
- (void)_registerMultiStageSequencerView:(KKStageSequencerView *)view;
@end

// FxPlug calls createViewForParameterID: on a fresh plugin instance, not the
// one that ran addParametersWithError:. Store parameter metadata at class level
// (keyed by the concrete plugin class) so any instance can look it up.
static const void *const kKKSepTexts = &kKKSepTexts;
static const void *const kKKSepIcons = &kKKSepIcons;
static const void *const kKKInfoTexts = &kKKInfoTexts;
static const void *const kKKInfoAttrTexts = &kKKInfoAttrTexts;
static const void *const kKKInfoIcons = &kKKInfoIcons;
static const void *const kKKTimingExtraIDs = &kKKTimingExtraIDs;
static const void *const kKKLinkedPairs = &kKKLinkedPairs;
static const void *const kKKLinkedLocking = &kKKLinkedLocking;
static const void *const kKKLinkedRatio = &kKKLinkedRatio;
static const void *const kKKLinkedSource = &kKKLinkedSource;

static inline NSMutableDictionary<NSNumber *, id> *
kkClassRegistry(Class cls, const void *key) {
  NSMutableDictionary *dict = objc_getAssociatedObject(cls, key);
  if (!dict) {
    dict = [NSMutableDictionary new];
    objc_setAssociatedObject(cls, key, dict, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return dict;
}
