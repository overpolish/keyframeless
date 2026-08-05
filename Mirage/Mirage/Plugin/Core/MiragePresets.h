/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKPreset;

NS_ASSUME_NONNULL_BEGIN

/// The built-in Mirage "look" presets: each installs the plasma shader (the
/// @"Mirage" code lane) with a different Center / Scale treatment - a static
/// look plus an animated zoom and drift, so the shared Presets popover (and its
/// guide) always has something to apply. Register once via `-[KKPresets
/// registerBuiltinPresets:forPluginKey:]`. Names double as KKLocalizable keys
/// resolved for display (falling back to the English key).
NSArray<KKPreset *> *MirageBuiltinPresets(void);

NS_ASSUME_NONNULL_END
