/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKPreset;

NS_ASSUME_NONNULL_BEGIN

/// The built-in Mesh "look" presets: each sets the Type + a curated sRGB
/// palette (Color Count + Color 1..N) and leaves every other lane at its Mesh
/// default. Register once via `-[KKPresets
/// registerBuiltinPresets:forPluginKey:]` so they appear in the shared Presets
/// popover. The palettes are drawn from paper-design/shaders' own preset
/// colours (MIT). Names double as KKLocalizable keys resolved for display
/// (falling back to the English key).
NSArray<KKPreset *> *MeshBuiltinPresets(void);

NS_ASSUME_NONNULL_END
