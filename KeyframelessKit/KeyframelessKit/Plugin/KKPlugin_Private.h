/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKPlugin.h"
#import <FxPlug/FxPlugSDK.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

@class KKAnimatableProperty;
@class KKCustomGroupHeaderView;
@class KKEmptyLanesView;
@class KKLaneVisibilityBar;
@class KKStagePlayheadView;
@class KKStageSequencerRulerView;
@class KKStageSequencerView;
@class KKTimingLane;

/// Returns `lanes` with every lane whose `propertyLabel` is in `hidden`
/// removed. Shared between the custom-view setup and the multi-stage pump
/// so every push to `seq.lanes` applies the same visibility filter.
extern NSArray<KKTimingLane *> *
KKFilterLanesForVisibility(NSArray<KKTimingLane *> *lanes,
                           NSSet<NSString *> *_Nullable hidden);

/// Effective hidden lane labels: union of the plugin-suppressed set
/// (`pluginHidden`) and the user-toggled set (lanes whose
/// `visibleInSequencer == NO`). Returns nil when both sources are empty.
extern NSSet<NSString *> *_Nullable KKEffectiveHiddenLaneLabels(
    NSSet<NSString *> *_Nullable pluginHidden,
    NSArray<KKTimingLane *> *_Nullable lanes);

/// Pushes `lanes`' labels and per-lane visibility states to the bar on the
/// main queue. Pass the full unfiltered JSON lane list and the **plugin
/// (system) hidden-label set** — i.e. `-hiddenAnimatablePropertyLabels`,
/// NOT the effective set. The bar omits lanes whose label is in
/// `pluginHidden` (so e.g. Glow's color/gradient lanes are absent in the
/// wrong colour mode), but still shows user-hidden pills so the user can
/// click to unhide them.
extern void
KKPushLanesToVisibilityBar(KKLaneVisibilityBar *_Nullable bar,
                           NSArray<KKTimingLane *> *_Nullable lanes,
                           NSSet<NSString *> *_Nullable pluginHidden);

/// Shows the empty-lanes overlay when every lane in `lanes` is hidden.
/// Marshals to the main queue.
extern void
KKApplyEmptyLanesVisibility(KKEmptyLanesView *_Nullable emptyView,
                            NSArray<KKTimingLane *> *_Nullable lanes);

/// Translates a viewIndex (index into the filtered, view-visible lane list)
/// to the JSON index (index into the full unfiltered lane array). Returns
/// -1 if `viewIndex` is out of range. Sequencer callbacks receive view
/// indices but persist via the unfiltered JSON, so every callback that
/// mutates `lanes` must translate first or it will edit the wrong lane.
extern NSInteger
KKLaneJSONIndexForViewIndex(NSInteger viewIndex,
                            NSArray<KKTimingLane *> *jsonLanes,
                            NSSet<NSString *> *_Nullable hidden);

/// Identifier stamped on the single root subview added into a remote window's
/// host. Lets a subsequent open (help or sequencer) cleanly replace prior
/// content without disturbing the host-managed `parentView`.
extern NSUserInterfaceItemIdentifier const KKRemoteWindowContentID;

/// Current clip duration in seconds for the plugin instance behind
/// `apiManager`, or 0 when `FxTimingAPI_v4` is unavailable.
extern double KKCurrentEffectDurationSeconds(id<PROAPIAccessing> apiManager);

/// Reads the `kKKParamMultiStageData` lanes JSON and rebalances each lane
/// for the current clip duration so locked segments retain their absolute
/// seconds when the clip length has changed since the last write. Returns
/// `nil` when the param is empty or contains no valid lanes.
extern NSMutableArray<KKTimingLane *> *_Nullable KKReadLanesRebalanced(
    id<PROAPIAccessing> apiManager, id<FxParameterRetrievalAPI_v6> getAPI);

@interface KKPlugin () <FxCustomParameterViewHost_v2>

@property(nonatomic, weak, nullable) KKCustomGroupHeaderView *timingHeader;
@property(nonatomic, weak, nullable) KKStageSequencerView *stageSequencer;
@property(nonatomic, weak, nullable) NSView *stageSequencerContainer;
@property(nonatomic, weak, nullable)
    KKStageSequencerRulerView *stageSequencerRuler;
@property(nonatomic, strong, nullable) NSPopover *segmentEditPopover;

@end

@interface KKPlugin (ColorViews)
- (NSView *)_createColorCustomUI:(UInt32)parameterID;
@end

@interface KKPlugin (TimingHeader)
- (NSView *)_createTimingHeader:(UInt32)parameterID;
- (NSView *)_createMotionBlurHeader:(UInt32)parameterID;
- (void)_openTimingRemoteWindow;
@end

@interface KKPlugin (SequencerBuilder)
- (NSView *)_createTimingGraphViewUncapped:(BOOL)uncapped;
- (NSArray<KKTimingLane *> *)
    _readOrSeedLanesForProps:(NSArray<KKAnimatableProperty *> *)seqProps
                 paramGetAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                      atTime:(CMTime)time;
/// Builds display-only default lanes purely from current param values —
/// no snapshot cache, no JSON fallback. Use from inside an action scope
/// to recover from a stale build-time seed (e.g. when Gradient
/// `getStringParameterValue` came back nil during create-view).
- (NSArray<KKTimingLane *> *)
    _buildDefaultLanesForProps:(NSArray<KKAnimatableProperty *> *)seqProps
                   paramGetAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                        atTime:(CMTime)time;
@end

@interface KKPlugin (TimingGraph)
- (void)timingGraphApplyState;
- (void)_applyHTHParameterFlagsForLanes:(NSArray<KKTimingLane *> *)lanes;
- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)_kindsByLaneLabel;
- (void)_showSegmentEditPopoverForLane:(NSInteger)laneIndex
                            segmentIdx:(NSInteger)segmentIndex
                            anchorRect:(NSRect)anchorRect
                            sourceView:
                                (nullable KKStageSequencerView *)sourceView;
- (void)_showAllLanesSegmentEditPopoverForLane:(NSInteger)laneIndex
                                    segmentIdx:(NSInteger)segmentIndex
                                    anchorRect:(NSRect)anchorRect
                                    sourceView:(nullable KKStageSequencerView *)
                                                   sourceView;
@end

@class KKAnimatableProperty;

/// Writes `lanes` to the shared `kKKParamMultiStageData` JSON param. HTH
/// transitions are normalized in-place before serialization. Pass
/// `[self _kindsByLaneLabel]` for `kindsByLabel`; nil falls back to
/// normalize-everything.
extern void KKWriteLanesJSON(
    NSArray<KKTimingLane *> *lanes, id<FxParameterSettingAPI_v5> setAPI,
    id<PROAPIAccessing> _Nullable apiManager,
    NSDictionary<NSString *, NSArray<NSNumber *> *> *_Nullable kindsByLabel);

/// Looks up the animatable property by `label`, or nil when no match.
extern KKAnimatableProperty *_Nullable KKPropertyByLabel(
    NSArray<KKAnimatableProperty *> *props, NSString *label);

@interface KKPlugin (StageSequencerCallbacks)
/// Wires the sequencer view's `onX` block callbacks (segment selection,
/// lane toggles, segment add/remove/move/copy, playhead scrub, zoom/pan
/// sync). Called once during sequencer setup. The sequencer view retains
/// the callbacks, which in turn keep a weak ref to `self`.
- (void)_wireStageSequencerCallbacksFor:(KKStageSequencerView *)seqView
                              rulerView:(KKStageSequencerRulerView *)rulerView
                           playheadView:(KKStagePlayheadView *)playheadView;
@end

@class KKTimingLane;

@interface KKPlugin (HandlersSelection)
- (void)_handleSegmentSelectedAtLane:(NSInteger)laneIndex
                             segment:(NSInteger)segmentIndex;
- (void)_handleAllLanesSegmentSelectedAtPosition:(double)position;
- (void)_handleLaneToggledAtIndex:(NSInteger)laneIndex enabled:(BOOL)enabled;
/// Handles a click on a lane-visibility-bar pill: toggles or solos the
/// lane (option-click solos / unsolos when already only-visible), persists
/// the new visibility state, and refreshes the sequencer + bar.
- (void)_handleLaneVisibilityClickedAtIndex:(NSInteger)laneIndex
                                 optionDown:(BOOL)optionDown;
/// Sets a single lane's visibility to a specific value (no toggle, no solo
/// semantics). Used by drag-paint on the visibility pill bar.
- (void)_handleLaneVisibilitySetAtIndex:(NSInteger)laneIndex
                                visible:(BOOL)visible;
- (void)_handleLaneOSCVisibilityAtIndex:(NSInteger)laneIndex
                                visible:(BOOL)visible;
- (void)_handleLaneChangedAtIndex:(NSInteger)laneIndex
                             lane:(KKTimingLane *)updatedLane;
- (void)_handleLanesChangedAtIndexes:(NSArray<NSNumber *> *)laneIndexes
                               lanes:(NSArray<KKTimingLane *> *)updatedLanes;
- (void)_handleSegmentValuesCopiedAtLane:(NSInteger)laneIndex
                                     src:(NSInteger)srcSegmentIndex
                                     dst:(NSInteger)dstSegmentIndex;
@end

@interface KKPlugin (HandlersStructure)
- (void)_handleSegmentAddedAtLane:(NSInteger)laneIndex
                         position:(double)position;
- (void)_handleAllLanesSegmentAddedAtPosition:(double)position;
- (void)_handleSegmentRemovedAtLane:(NSInteger)laneIndex
                            segment:(NSInteger)segmentIndex;
- (void)_handleAllLanesSegmentRemovedAtPosition:(double)position;
@end

@interface KKPlugin (HandlersModifiers)
- (void)_handleSegmentTypeToggledAtLane:(NSInteger)laneIndex
                                segment:(NSInteger)segmentIndex;
- (void)_handleSegmentLockToggledAtLane:(NSInteger)laneIndex
                                segment:(NSInteger)segmentIndex
                               duration:(double)newLockedSeconds;
- (void)_handleAllLanesSegmentTypesToggledAtPosition:(double)position;
- (void)_handleAllLanesSegmentLockToggledAtPosition:(double)position
                                               lock:(BOOL)lock;
- (void)_handleRulerLoopToggled:(BOOL)newState;
- (void)_handleRulerPlayheadScrubToFraction:(double)fraction;
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
