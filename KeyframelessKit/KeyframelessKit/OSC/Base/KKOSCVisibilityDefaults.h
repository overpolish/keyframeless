/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKScopedDefaults.h>

NS_ASSUME_NONNULL_BEGIN

/// Which on-screen controls a new clip (or, in a per-layer plugin, a new layer)
/// starts with hidden - the OSC checklist's "Make Default". Scoped exactly like
/// the curve defaults: per plugin, and per shader template in Mirage.
///
/// Stored as the HIDDEN keys rather than the full visible map so an element the
/// user has never seen (a shader that gained a control, a new plugin release)
/// defaults to visible instead of silently disappearing.
///
/// nil = the user never saved one; the caller keeps its own seed (everything
/// visible).
FOUNDATION_EXPORT NSSet<NSString *> *_Nullable KKOSCVisibilityDefaultsRead(
    NSString *_Nullable scope);
FOUNDATION_EXPORT void
KKOSCVisibilityDefaultsWrite(NSSet<NSString *> *hiddenKeys,
                             NSString *_Nullable scope);

NS_ASSUME_NONNULL_END
