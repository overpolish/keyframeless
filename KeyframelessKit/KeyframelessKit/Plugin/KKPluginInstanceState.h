/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

@class KKGradientBarView;
@class KKStagePlayheadView;
@class KKStageSequencerRulerView;
@class KKStageSequencerView;
@class KKTimingGraphView;
@class KKTimingLane;
@protocol PROAPIAccessing;

/// Weak references to a full set of timing views. Used to track secondary
/// view sets (e.g. a detached window) so they can receive the same updates
/// as the primary (inspector) views.
@interface KKTimingViewRefs : NSObject
@property(nonatomic, weak, nullable) KKTimingGraphView *graphView;
@property(nonatomic, weak, nullable) KKStageSequencerView *seqView;
@property(nonatomic, weak, nullable) NSView *seqContainer;
@property(nonatomic, weak, nullable) KKStageSequencerRulerView *ruler;
@property(nonatomic, weak, nullable) KKStagePlayheadView *playhead;
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

/// The live sequencer view for this instance (weak — auto-nils on dealloc).
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
/// refreshed from the OSC pump's drawOSC context — FxTimingAPI returns nil
/// when queried through a non-active instance's apiManager, and wrapping
/// in a fresh action scope inside drawOSC causes re-entrant redraws.
@property(nonatomic) double cachedEffectStart;
@property(nonatomic) double cachedEffectDuration;

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
@property(nonatomic, weak, nullable) KKGradientBarView *gradientBar;

/// Last-known gradient JSON. Set by the custom UI and by the color sync
/// pump; used to diff against the persisted param on sync ticks so self-
/// writes are ignored and undo/redo changes are detected.
@property(nonatomic, copy, nullable) NSString *gradientJSONSnapshot;

/// Lane labels the plugin currently wants hidden from the sequencer view.
/// Updated by `-multiStageRefreshLaneVisibility`; applied as a filter to
/// every `seq.lanes =` push.
@property(nonatomic, copy, nullable) NSSet<NSString *> *hiddenLaneLabels;

@end

/// Reads `kKKParamInstanceID` from the api, cached on the api via
/// associated object for fast re-reads. Returns nil if no UUID has been
/// assigned yet (the first `createViewForParameterID` call generates and
/// persists one inside an action scope — see KKPlugin+CustomViews.m).
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
/// state (e.g. gradient bar) should use this — otherwise, if the custom UI
/// runs before the first sequencer is registered, the state assignment
/// silently no-ops on nil and the UI stays disconnected until a remount.
KKPluginInstanceState *_Nullable KKInstanceStateEnsureForAPI(
    id<PROAPIAccessing> api);

/// Snapshot of all live per-instance states. Used by the OSC flush pump to
/// broadcast view updates across every effect instance — any single running
/// `drawOSC` (the OSC-selected effect) can deliver updates to every live
/// sequencer view on the timeline, not just its own.
NSArray<KKPluginInstanceState *> *KKAllInstanceStates(void);

NS_ASSUME_NONNULL_END
