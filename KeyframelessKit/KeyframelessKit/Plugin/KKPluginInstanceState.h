/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKStageSequencerView;
@class KKTimingLane;
@protocol PROAPIAccessing;

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

/// Snapshot of all live per-instance states. Used by the OSC flush pump to
/// broadcast view updates across every effect instance — any single running
/// `drawOSC` (the OSC-selected effect) can deliver updates to every live
/// sequencer view on the timeline, not just its own.
NSArray<KKPluginInstanceState *> *KKAllInstanceStates(void);

NS_ASSUME_NONNULL_END
