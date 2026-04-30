/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKCanvasStore.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

/// Centralized parameter flag visibility sync engine.
///
/// This is the SINGLE owner of all setParameterFlags calls for per-object
/// params (stroke, fill, sketch, opacity, closedPath, etc.).  No other code
/// should call setParameterFlags or the KKSet*Visible / KKShowObjectParams /
/// KKHideObjectParams helpers directly.
///
/// Uses a visibility hash to skip redundant work — only opens an action scope
/// and calls setParameterFlags when the desired visibility state has actually
/// changed from what was last applied.

/// Apply parameter flag visibility based on a store snapshot.
///
/// Reads all visibility inputs from the snapshot (not from FxPlug params)
/// to avoid races with UI callbacks that haven't committed yet.
///
/// @param snap  Store snapshot with current state.
/// @param selectedPath  The first selected non-group path, or nil.
/// @param uuid  Instance UUID (for hash storage).
/// @param api   API accessor for opening action scopes.
void KKParamSyncApplyFromSnapshot(KKCanvasStoreSnapshot *_Nonnull snap,
                                  KKBezierPath *_Nullable selectedPath,
                                  NSString *_Nonnull uuid,
                                  id<PROAPIAccessing> _Nonnull api);
