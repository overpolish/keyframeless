/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Storage behind the "Make Default" buttons: small per-plugin preferences the
/// user saves from a popover and every new segment / clip then starts at (see
/// KKCurveDefaults, KKOSCVisibilityDefaults).
///
/// Values live in the `group.co.overpolish.keyframeless` defaults suite, NOT in
/// standardUserDefaults - the latter resolves to a per-PROCESS domain inside
/// FxPlug, so a default saved from the inspector's ViewBridge would be
/// invisible to the plugin process that acts on it.
///
/// Scope is the plugin's `presetPluginKey` (its bundle id, stable across the
/// plugin's PlugIn / XPC / ViewBridge processes), so Canvas and Mirage keep
/// separate defaults; a plugin that wants finer grain appends its own suffix
/// (Mirage adds the loaded shader's `codeSaveID`). It is process-wide rather
/// than threaded through every view: one XPC process only ever hosts one
/// plugin, and the inspector re-asserts the scope every time it takes a
/// plugin's state, so the active scope always matches the inspector the open
/// popover belongs to.
FOUNDATION_EXPORT void KKDefaultsSetActiveScope(NSString *_Nullable scope);
FOUNDATION_EXPORT NSString *KKDefaultsActiveScope(void);

/// Read / write one `field` (@"curve", @"oscHidden", ...) under `scope`, or the
/// active scope when nil. Reads are cached in-process and invalidated on the
/// cross-process defaults-change notification, since the timeline decode path
/// creates intervals per render tick and must not hit cfprefsd every time.
/// Writing nil removes the stored value.
FOUNDATION_EXPORT id _Nullable KKScopedDefaultRead(NSString *field,
                                                   NSString *_Nullable scope);
FOUNDATION_EXPORT void KKScopedDefaultWrite(id _Nullable value, NSString *field,
                                            NSString *_Nullable scope);

/// Copy every stored default from one scope to another, skipping fields the
/// destination already has. Use when a scope is FORKED rather than renamed -
/// saving a Mirage shader as a new custom template mints a fresh id, and the
/// user expects the defaults they tuned on the template they started from to
/// come along. Returns the number of fields copied.
FOUNDATION_EXPORT NSUInteger KKScopedDefaultsCopyScope(NSString *fromScope,
                                                       NSString *toScope);

NS_ASSUME_NONNULL_END
