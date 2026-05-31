/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

@class KKEmptyLanesView;
@class KKGradientControl;
@class KKLaneVisibilityBar;
@class KKPlugin;
@class KKStagePlayheadView;
@class KKStageSequencerRulerView;
@class KKStageSequencerView;
@class KKTimingLane;
@protocol PROAPIAccessing;

/// Weak references to a full set of timing views. Used to track secondary
/// view sets (e.g. a detached window) so they can receive the same updates
/// as the primary (inspector) views.
@interface KKTimingViewRefs : NSObject
@property(nonatomic, weak, nullable) KKStageSequencerView *seqView;
@property(nonatomic, weak, nullable) NSView *seqContainer;
@property(nonatomic, weak, nullable) KKStageSequencerRulerView *ruler;
@property(nonatomic, weak, nullable) KKStagePlayheadView *playhead;
@property(nonatomic, weak, nullable) KKLaneVisibilityBar *visibilityBar;
@property(nonatomic, weak, nullable) KKEmptyLanesView *emptyLanesView;
- (BOOL)isAlive;
@end

NS_ASSUME_NONNULL_BEGIN

/// Per-plugin-instance state for the multi-stage timing system. Keyed by a
/// UUID stored in `kKKParamInstanceID` so multiple copies of a plugin on
/// the same timeline don't clobber each other via process-wide statics.
///
/// Thread notes:
/// - `sequencerView` is a weak ref (ARC atomic read/write).
/// - All other fields are written on the main thread (parameterChanged +
///   custom-view callbacks). `lanesSnapshot` and `pendingLanes` are read
///   from the OSC render queue via `multiStage*ForAPI:` class methods.
///   Reads return the immutable NSArray pointer value atomically.
@interface KKPluginInstanceState : NSObject

/// Last-known lanes snapshot. Used by parameterChanged to build live updates
/// without re-reading JSON, and by OSC sync to detect external changes.
@property(nonatomic, copy, nullable) NSArray<KKTimingLane *> *lanesSnapshot;

/// Lanes that should be pushed to the sequencer view on the next OSC draw.
@property(nonatomic, copy, nullable) NSArray<KKTimingLane *> *pendingLanes;

/// Set once we've either successfully read non-empty JSON for this instance
/// or written JSON via KKWriteLanesJSON. Distinguishes a truly fresh instance
/// (re-seed from defaults is correct) from an XPC scope where the param
/// probe transiently returns nil right after a write (re-seeding would clobber
/// the user's edit).
@property(nonatomic) BOOL lanesEverPersisted;

/// The live sequencer view for this instance (weak - auto-nils on dealloc).
@property(nonatomic, weak, nullable) KKStageSequencerView *sequencerView;

/// The paired ruler view (weak). Mirrors effectDuration/playheadFraction
/// updates pushed to the sequencer.
@property(nonatomic, weak, nullable) KKStageSequencerRulerView *rulerView;

/// Unified playhead overlay (weak). Receives playheadFraction updates from
/// the broadcast pump so the line + knob track the timeline.
@property(nonatomic, weak, nullable) KKStagePlayheadView *playheadView;

/// Cached effect timing (seconds). Populated when the custom UI is created
/// (inside an action scope where FxTimingAPI answers) and used by the
/// playhead pump to broadcast updates across all instances. Cannot be
/// refreshed from the OSC pump's drawOSC context - FxTimingAPI returns nil
/// when queried through a non-active instance's apiManager, and wrapping
/// in a fresh action scope inside drawOSC causes re-entrant redraws.
@property(nonatomic) double cachedEffectStart;
@property(nonatomic) double cachedEffectDuration;

/// Timeline-time start of the clip, in seconds. `cachedEffectStart` above is
/// in source (clip-local) time, but `FxCommandAPI_v2 movePlayheadToTime:`
/// requires timeline time. Cached because `FxTimingAPI_v4` returns nil when
/// queried from the loop-back's render-tick context - populated at custom-UI
/// creation (inside an action scope, where the API is reliable) and opportu-
/// nistically refreshed by the playhead pump. Computed via
/// `startTimeOfInputToFilter:` + `timelineTime:fromInputTime:` (same pattern
/// as the sequencer-click seek in KKPlugin+HandlersModifiers.m).
@property(nonatomic) double cachedTimelineStart;

/// Cached native frame duration for the clip, in seconds. Populated from
/// `FxTimingAPI_v4 frameDuration:`. Used by the loop pump to trigger
/// loop-back at the last rendered frame regardless of frame rate.
@property(nonatomic) double cachedFrameDuration;

/// Re-entrancy guard: YES while a segment-selection callback is writing
/// native params so `multiStageHandleParameterChanged:` skips its work.
@property(nonatomic) BOOL selectionInProgress;

/// Playhead throttle: latest values from OSC, coalesced to one main-thread
/// dispatch per tick.
@property(nonatomic) double pendingPlayheadFraction;
@property(nonatomic) double pendingPlayheadDuration;
@property(nonatomic) BOOL playheadDispatchPending;

/// Secondary timing-view sets for this instance (e.g. a detached window).
/// Live pump updates (lanes, playhead) iterate this in addition to the
/// primary sequencer/ruler/playhead properties above.
@property(nonatomic, strong, nullable)
    NSMutableArray<KKTimingViewRefs *> *additionalTimingViews;

/// Live gradient bar for this instance (weak). Used by the color sync pump
/// to push undo/redo-restored stops back into the UI.
@property(nonatomic, weak, nullable) KKGradientControl *gradientControl;

/// Last-known gradient JSON. Set by the custom UI and by the color sync
/// pump; used to diff against the persisted param on sync ticks so self-
/// writes are ignored and undo/redo changes are detected.
@property(nonatomic, copy, nullable) NSString *gradientJSONSnapshot;

/// Lane labels currently hidden from the sequencer view. Combines the
/// plugin-suppressed set (from `-hiddenAnimatablePropertyLabels`) with the
/// user-toggled set (lanes whose `visibleInSequencer == NO` in JSON).
/// Applied as a filter to every `seq.lanes =` push.
@property(nonatomic, copy, nullable) NSSet<NSString *> *hiddenLaneLabels;

/// Plugin-suppressed lanes only - i.e. the latest snapshot of
/// `-hiddenAnimatablePropertyLabels`. Maintained alongside
/// `hiddenLaneLabels` so the JSON-drift pump can filter without having to
/// reverse-derive plugin-hidden from the (possibly stale) effective set.
@property(nonatomic, copy, nullable) NSSet<NSString *> *pluginHiddenLaneLabels;

/// The live lane-visibility-bar view for this instance (weak - auto-nils on
/// dealloc). Sync pump pushes lane label/state updates here on JSON change.
@property(nonatomic, weak, nullable) KKLaneVisibilityBar *visibilityBar;

/// Empty-state overlay shown when every lane is user-hidden (weak).
@property(nonatomic, weak, nullable) KKEmptyLanesView *emptyLanesView;

/// Weak ref to the plugin instance that owns this state. Set by the
/// sequencer registration path so static pump helpers can route empty-
/// state messaging through the plugin's `emptyLanesMessageWhenNoLanes`.
@property(nonatomic, weak, nullable) KKPlugin *plugin;

/// Whether the sequencer's loop-playback toggle is on. Session-scoped (not
/// persisted across FCP restarts, not written to a param). Written from the
/// ruler's loop button, consulted by the render pump to decide whether to
/// wrap playback back to the effect start when the playhead passes the end.
@property(nonatomic) BOOL loopEnabled;

/// Master "on-screen controls visible" tick. Per-instance runtime cache the
/// OSC's draw tick reads to gate handle visibility (the OSC can't read the
/// host's UI-state blob from its own apiManager scope). Seeded from the
/// persisted blob at custom-UI creation / parameterChanged and written on
/// toggle. Defaults YES so a control-less cold-boot tick still shows the OSC.
@property(nonatomic) BOOL oscMasterVisible;

/// Pointer of the api manager that "owns" this state. Used by
/// `KKInstanceStateEnsureForAPI` to detect duplicate-UUID clones (FCP
/// copy/paste/cut clones the `kKKParamInstanceID` value) and mint a fresh
/// UUID for the second instance. Stored unsafe-unretained: only ever
/// pointer-compared, never dereferenced.
@property(nonatomic, assign, nullable) void *ownerAPIPointer;

/// Fingerprint of the most recent successful reconcile. The pump skips both
/// the FCP JSON read and the plugin reconcile call when the plugin's current
/// fingerprint matches this value (see `-kkReconcileFingerprintForAPI:`).
/// Read concurrently from main (store observer) and render queue
/// (drawOSCTick); each call computes its own fingerprint and compares
/// locally - never use a shared "did we skip" flag, races corrupt it.
@property(nonatomic, copy, nullable) NSString *cachedReconcileFingerprint;

/// The `lanesSnapshot` array pointer most recently pushed to the sequencer
/// view(s). The pump pointer-compares `state.lanesSnapshot` against this
/// to decide whether a fresh seq.lanes push is needed. Pointer identity
/// is sufficient because every `lanesSnapshot` writer assigns `[copy]` of
/// a new array. Strong reference so the pointer stays valid for compare.
///
/// Why both this AND `cachedReconcileFingerprint`: the fingerprint gates
/// the FCP reconcile call (skipped when source topology unchanged). This
/// gates the seq push (skipped when the in-memory lanes pointer hasn't
/// been replaced since the last push). Without this, in-memory edits
/// that don't touch source topology - e.g. inspector value tweaks
/// flowing into lanesSnapshot via a plugin-side mutation site - would
/// match the fingerprint, get short-circuited, and never reach seq.
@property(nonatomic, strong, nullable)
    NSArray<KKTimingLane *> *lastPushedLanesSnapshot;

/// Last JSON string we wrote to `kKKParamMultiStageData`. Used to dedupe
/// no-op writes - every `setCustomParameterValue:atTime:` registers an
/// undo entry on FCP/Motion's stack, so writing identical content puts
/// phantom entries between user edits and forces extra cmd-Z presses to
/// revert a single logical change.
@property(nonatomic, copy, nullable) NSString *lastWrittenMultiStageJSON;

/// Set transiently by `multiStageRefreshFromParamForAPI:` (the host cmd-Z
/// entry point) and cleared on the next runloop tick via `dispatch_async`.
/// While set, `KKWriteMultiStageJSONDeduped` skips the write - without this
/// every host-driven param revert (animatable scalar OR multi-stage blob)
/// triggers our live-update path, which writes a fresh entry back onto
/// FCP's undo stack, immediately overwriting the host's revert and
/// fragmenting one logical undo into N entries.
@property(nonatomic) BOOL hostUndoSuppressionPending;

/// Coalescing flag for plugin-side `parameterChanged:` live-update
/// handlers funnelling through `multiStageDeferLiveUpdateForLabel:`.
/// First call in a coalescing window sets the flag and schedules a
/// `dispatch_after` block; subsequent calls early-return after merely
/// updating `pendingLiveUpdates` with the latest values. When the
/// deferred block fires it drains the dictionary and clears the flag.
@property(nonatomic) BOOL liveUpdatePending;

/// Mach-time deadline used to swallow a live-update echo whose source
/// write was already flushed synchronously inside an outer drag scope.
/// `multiStageDeferLiveUpdateForLabel:` early-returns while
/// `CACurrentMediaTime() < liveUpdateSuppressUntil`. Set by drag-end
/// handlers (e.g. gradient `onDragEnd`) after force-flushing pending
/// values inline so the host's post-endAction `parameterChanged:` echo
/// doesn't spawn an orphan undo entry.
@property(nonatomic) NSTimeInterval liveUpdateSuppressUntil;

/// Latest-values-per-label staging dict drained by the deferred block
/// in `multiStageDeferLiveUpdateForLabel:`. Last-wins semantics - a
/// continuous slider drag keeps overwriting the same key, so the block
/// always writes the freshest values when it fires.
@property(nonatomic, strong, nullable)
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *pendingLiveUpdates;

/// How many `parameterChanged:` callbacks for `kKKParamMultiStageData`
/// we expect from the host as echoes of our own setCustomParameterValue
/// writes. Bumped on every successful MS-WRITE; decremented when MS-
/// REFRESH fires and the count is > 0 (in which case the refresh is
/// classified as an echo and suppression is NOT set). When the count is
/// 0, the refresh is a real host cmd-Z and suppression is engaged. This
/// replaces the earlier probeJSON-based echo detection - that approach
/// required a custom-param read which could yield to the runloop and
/// let a racing live-update block write before suppression was set.
@property(nonatomic) NSInteger expectedMultiStageEchoCount;

@end

/// Reads `kKKParamInstanceID` from the api, cached on the api via
/// associated object for fast re-reads. Returns nil if no UUID has been
/// assigned yet (the first `createViewForParameterID` call generates and
/// persists one inside an action scope - see KKPlugin+CustomViews.m).
NSString *_Nullable KKInstanceUUIDForAPI(id<PROAPIAccessing> api);

/// Returns (or lazy-creates) the state for a given UUID. Uses the
/// immutable-copy static-map pattern from project_fxplug_static_mutability.md.
KKPluginInstanceState *_Nullable KKInstanceStateForUUID(
    NSString *_Nullable uuid);

/// Convenience wrapper: UUID lookup + state lookup in one call.
KKPluginInstanceState *_Nullable KKInstanceStateForAPI(id<PROAPIAccessing> api);

/// Like `KKInstanceStateForAPI` but generates and persists a UUID to
/// `kKKParamInstanceID` if one is not yet set, so subsequent lookups across
/// fresh FxPlug plugin instances resolve to the same state entry. Must be
/// called inside an `startAction:/endAction:` scope (required for the
/// string-param write). Any custom-UI creation that stores per-instance
/// state (e.g. gradient bar) should use this - otherwise, if the custom UI
/// runs before the first sequencer is registered, the state assignment
/// silently no-ops on nil and the UI stays disconnected until a remount.
KKPluginInstanceState *_Nullable KKInstanceStateEnsureForAPI(
    id<PROAPIAccessing> api);

/// Snapshot of all live per-instance states. Used by the OSC flush pump to
/// broadcast view updates across every effect instance - any single running
/// `drawOSC` (the OSC-selected effect) can deliver updates to every live
/// sequencer view on the timeline, not just its own.
NSArray<KKPluginInstanceState *> *KKAllInstanceStates(void);

NS_ASSUME_NONNULL_END
