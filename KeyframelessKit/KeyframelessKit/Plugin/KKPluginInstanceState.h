/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>
#import <PluginManager/PluginManager.h>

@class KKStageSequencerView;
@class KKTimingLane;

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

NS_ASSUME_NONNULL_END
