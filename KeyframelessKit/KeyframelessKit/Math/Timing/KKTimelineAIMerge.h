/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

#import <KeyframelessKit/KKTimeline.h>

// Forward-declare the FxPlug protocol rather than #importing FxPlugSDK.h (not a
// module - importing it in a framework header trips the non-modular-header
// warning). Same pattern as KKDataBlob.h.
@protocol FxParameterRetrievalAPI_v6;

NS_ASSUME_NONNULL_BEGIN

/// The current timeline JSON to hand the AI agent: the saved
/// `kKKParamTimelineData` blob when it already holds lanes, otherwise a fresh
/// timeline seeded from `fallbackLanes` (the plugin's `+availableLanes`). Never
/// nil. Caller must already be inside an action scope (getAPI resolves there).
FOUNDATION_EXPORT NSString *
KKTimelineAICurrentJSON(id<FxParameterRetrievalAPI_v6> getAPI,
                        NSArray<KKLane *> *fallbackLanes);

/// Deterministic backstop for the agent forgetting to carry modulation across
/// unchanged regions: for every new unmodulated linked-hold interval, copy the
/// modulation fields from an old modulated hold whose time range overlaps AND
/// whose held value matches (so it only restores modulation on "the same hold
/// resegmented", not a new differently-valued hold). Operates on the JSON
/// keypose-dict arrays; returns `newKeyposes` unchanged when nothing applies.
FOUNDATION_EXPORT NSArray *KKTimelineAIPreserveModulation(NSArray *newKeyposes,
                                                          NSArray *oldKeyposes);

/// Merge the agent's compiled mutation JSON of shape
/// `{"operations":[{"lane":"<label>","keyposes":[...]}]}` into the current full
/// timeline JSON. Each named lane keeps its stable fields (id, value_type,
/// component_min/max/units) and only has its keyposes replaced (run through
/// KKTimelineAIPreserveModulation) and `enabled` set YES. Lanes not mentioned
/// are untouched; unknown labels are dropped. nil on malformed input.
///
/// Also snaps every lane's FINAL keypose from the nominal clip end (the AI
/// emits time ~1.0) back to the last renderable frame, `(clipDurSec -
/// frameDurSec) / clipDurSec` - Basic's `outEndFrac` rule. FCP's last frame
/// sits one frame before the out-point, so a keypose at 1.0 is never reached
/// and the animation lands a frame short (worst on ease-in / elastic / bounce).
/// This lives in the shared merge so EVERY plugin's AI path gets it
/// automatically - pass the clip duration (from the plugin's timing API) and
/// frame duration
/// (`KKProcessFrameDurationSeconds()`). Pass 0 for either to skip the snap.
FOUNDATION_EXPORT NSString *_Nullable KKTimelineAIMergeMutationJSON(
    NSString *currentTimelineJSON, NSString *mutationJSON, double clipDurSec,
    double frameDurSec);

NS_ASSUME_NONNULL_END
