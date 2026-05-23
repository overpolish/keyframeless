/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKPlugin.h"
#import <FxPlug/FxPlugSDK.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

@class KKCustomGroupHeaderView;
@class KKLogoBannerView;
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

/// Shows the empty-lanes overlay when every lane in `lanes` is hidden,
/// or when `lanes` is empty AND `plugin` supplies an
/// `emptyLanesMessageWhenNoLanes`. Updates the view's content per state
/// before toggling visibility. Marshals to the main queue.
extern void
KKApplyEmptyLanesVisibility(KKEmptyLanesView *_Nullable emptyView,
                            NSArray<KKTimingLane *> *_Nullable lanes,
                            KKPlugin *_Nullable plugin);

/// Translates a pill index (index into the visibility bar's deduped label
/// list) back to the propertyLabel string. Returns nil if out of range.
extern NSString *_Nullable KKLabelForPillIndex(
    NSInteger pillIndex, NSArray<KKTimingLane *> *jsonLanes,
    NSSet<NSString *> *_Nullable pluginHidden);

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

@interface KKPlugin () <FxCustomParameterViewHost_v2, NSPopoverDelegate>

/// This effect instance's logo banner. Scoped per plugin instance (FxPlug
/// makes one plugin object per effect) so multi-instance timelines resolve
/// the correct banner instead of a process-global "latest".
@property(nonatomic, weak, nullable) KKLogoBannerView *logoBanner;
@property(nonatomic, weak, nullable) KKCustomGroupHeaderView *timingHeader;
@property(nonatomic, weak, nullable) KKCustomGroupHeaderView *motionBlurHeader;
/// Weak map of generic group headers (created via
/// `createGroupHeaderWithTitle:…:expandedParamID:`) keyed by the
/// `expandedParamID`. Lets `parameterChanged:` re-sync the chevron when the
/// expanded bool param is reverted by host undo. Strong key (NSNumber),
/// weak value (KKCustomGroupHeaderView).
@property(nonatomic, strong, nullable)
    NSMapTable<NSNumber *, KKCustomGroupHeaderView *> *genericGroupHeaders;
/// Companion to `genericGroupHeaders`: same headers keyed by their
/// `enabledParamID` (the native bool toggle) instead of the expanded blob
/// param. Populated by `registerGroupHeader:enabledParamID:expandedParamID:`
/// when the caller's header has a checkbox. Used by
/// `syncGroupHeaderEnabledForEnabledParamID:atTime:`.
@property(nonatomic, strong, nullable)
    NSMapTable<NSNumber *, KKCustomGroupHeaderView *>
        *genericGroupHeadersByEnabledParamID;
@property(nonatomic, weak, nullable) KKStageSequencerView *stageSequencer;
@property(nonatomic, weak, nullable) NSView *stageSequencerContainer;
@property(nonatomic, weak, nullable)
    KKStageSequencerRulerView *stageSequencerRuler;
@property(nonatomic, strong, nullable) NSPopover *segmentEditPopover;
/// Refresh closure for the currently-open segment-edit popover. Called from
/// `timingGraphApplyState` with the latest lanes so the popover's
/// curve/intensity/frequency/seed values stay in sync with undo/redo of the
/// underlying multi-stage data param. The closure must close the popover
/// (and may clear `segmentEditPopover`) if the target segment is gone.
@property(nonatomic, copy, nullable) void (^segmentEditPopoverRefresh)
    (NSArray<KKTimingLane *> *latestLanes);
/// YES while a slider drag in the segment-edit popover is in flight and an
/// outer undo group is held open. Per-tick mutators see the open group via
/// nested `KKBeginUndoGroup` returning NO, so all tick writes coalesce into
/// the single drag-spanning undo entry.
@property(nonatomic) BOOL segmentEditDragUndoActive;

/// Same coalescing pattern as `segmentEditDragUndoActive`, but for
/// gradient stop / midpoint drags in the color popover. Set YES while
/// the drag is in flight; the per-tick `onStopsChanged` callback skips
/// its own action scope + undo group when this is YES.
@property(nonatomic) BOOL gradientDragUndoActive;

/// Same coalescing pattern as `segmentEditDragUndoActive`, but for the
/// lane-visibility pill bar above the sequencer. Set YES from mouseDown
/// through mouseUp so the initial pill click + every drag-paint tick lands
/// in one undo entry.
@property(nonatomic) BOOL visibilityPillDragUndoActive;

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
    _readOrSeedLanesWithParamGetAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                             atTime:(CMTime)time
                      fromPersisted:(nullable BOOL *)fromPersisted;
@end

@interface KKPlugin (TimingGraph)
- (void)timingGraphApplyState;
- (void)_applyHTHParameterFlagsForLanes:(NSArray<KKTimingLane *> *)lanes;
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

/// `KKWriteLanesJSON` is now declared publicly in `KKPlugin.h` so plugin
/// code (e.g. OSC principals) can use it without importing private headers.

/// Writes `json` to `kKKParamMultiStageData` only if it differs from the
/// last JSON we wrote (tracked on `KKPluginInstanceState`). Each call to
/// `setCustomParameterValue:atTime:` registers a new undo entry on the
/// host stack — duplicate writes pollute the stack and force users to
/// press cmd-Z multiple times to revert a single logical change. Returns
/// YES if the write actually happened. `tag` is included in the trace
/// log so the caller can be identified.
extern BOOL
KKWriteMultiStageJSONDeduped(NSString *_Nullable json,
                             id<FxParameterSettingAPI_v5> setAPI,
                             id<PROAPIAccessing> _Nullable apiManager);

/// Canonical form of a multi-stage JSON string for dedup comparison —
/// sorted-keys reserialization. UI-state fields (sel, etc.) are NOT
/// stripped: each user click is a real undo entry, matching standard
/// document-editor behavior.
extern NSString *_Nullable KKMultiStageNormalizedForDedup(
    NSString *_Nullable json);

/// Writes the lanes JSON to the native-string mirror param. Called
/// inside `KKWriteMultiStageJSONDeduped` so the mirror stays in
/// lockstep with the canonical blob — refreshed on cmd-Z echo too.
extern void KKWriteMultiStageMirror(NSString *_Nullable json,
                                    id<FxParameterSettingAPI_v5> setAPI);

/// Reads the native-string mirror of the lanes JSON. Used by the OSC
/// drawTick on cold-boot to seed `lanesSnapshot` before consumers
/// (oscVisible, bezier path, etc.) run. Returns nil when the mirror
/// hasn't been populated yet (brand-new instance with no edits).
extern NSString *_Nullable KKReadMultiStageMirror(
    id<PROAPIAccessing> _Nullable apiManager);

/// Runs `block` on the main thread. Synchronous when already on main,
/// dispatch_async otherwise. Use for view-state pushes triggered from
/// background callbacks (parameterChanged: from non-main, etc).
extern void KKRunOnMain(dispatch_block_t block);

/// Wraps `block` in an FxUndoAPI start/endUndoGroup pair so every host
/// param write inside collapses into a single host undo entry. No-op
/// fallback if the host (or this plugin's apiManager) doesn't implement
/// FxUndoAPI — block runs unwrapped. `name` should be a short, localized
/// human-readable label ("Add Segment", "Move Segment").
extern void KKWithUndoGroup(id<PROAPIAccessing> _Nullable apiManager,
                            NSString *name, dispatch_block_t block);

/// Stack-style undo grouping. Pair every `KKBeginUndoGroup` with exactly
/// one `KKEndUndoGroup` along every code path (including early returns).
/// Returns YES if the group was actually started — pass that BOOL into
/// `KKEndUndoGroup` so the end is a no-op when the start was a no-op.
extern BOOL KKBeginUndoGroup(id<PROAPIAccessing> _Nullable apiManager,
                             NSString *name);
extern void KKEndUndoGroup(id<PROAPIAccessing> _Nullable apiManager,
                           BOOL started);

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
- (void)_handleGroupCollapseToggledForKey:(NSString *)groupKey
                                collapsed:(BOOL)collapsed;
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
static const void *_Nonnull const kKKLinkedLastPartner = &kKKLinkedLastPartner;

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
