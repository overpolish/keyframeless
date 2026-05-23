/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKCanvasStore.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

@class KKCanvasStore;
@class KKCanvasStoreSnapshot;

/// Centralized parameter flag visibility sync engine.
///
/// This is the SINGLE owner of all setParameterFlags calls for per-object
/// params (stroke, fill, sketch, opacity, closedPath, etc.).  No other code
/// should call setParameterFlags or the KKSet*Visible / KKShowObjectParams /
/// KKHideObjectParams helpers directly.
///
/// Uses a visibility hash to skip redundant work - only opens an action scope
/// and calls setParameterFlags when the desired visibility state has actually
/// changed from what was last applied.

/// YES iff the snapshot's selection is non-empty and contains only group paths.
/// Used by group-header echo handlers to skip writes to stroke/fill/sketch
/// headers (which aren't applicable to groups).
BOOL KKCanvasSelectionIsGroupOnly(KKCanvasStoreSnapshot *_Nonnull snap);

/// Push an expanded/enabled bool into the right store setter for one of the
/// four group headers. Caller must already be inside `performBatch:`.
void KKCanvasApplyExpandedToStore(KKCanvasStore *_Nonnull store, UInt32 paramID,
                                  BOOL expanded);
void KKCanvasApplyEnabledToStore(KKCanvasStore *_Nonnull store, UInt32 paramID,
                                 BOOL enabled);

/// Apply parameter flag visibility based on a store snapshot, opening a
/// fresh action scope. Use from off-FCP-scope callers (async store
/// observer block, initial setup).
void KKParamSyncApplyFromSnapshot(KKCanvasStoreSnapshot *_Nonnull snap,
                                  KKBezierPath *_Nullable selectedPath,
                                  NSString *_Nonnull uuid,
                                  id<PROAPIAccessing> _Nonnull api);

/// Same logic, but the caller is already inside an action scope (FCP's
/// parameterChanged wrapper). No startAction is opened here, so the flag
/// writes coalesce into the caller's existing undo entry - mirrors how
/// motion blur's _setFlagsIfNeeded lands in parameterChanged's scope.
void KKParamSyncApplyFromSnapshotInScope(KKCanvasStoreSnapshot *_Nonnull snap,
                                         KKBezierPath *_Nullable selectedPath,
                                         NSString *_Nonnull uuid,
                                         id<PROAPIAccessing> _Nonnull api);
