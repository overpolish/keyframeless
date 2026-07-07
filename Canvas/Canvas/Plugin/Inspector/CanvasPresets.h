/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKPreset;

NS_ASSUME_NONNULL_BEGIN

/// Payload kind for Canvas annotation presets. The preset's `payloadJSON` is a
/// base64 `+[KKBezierPath blobFromPaths:]` blob - one or more fully-built layers
/// (geometry + stroke/fill/marker props + draw-on `animationJSON`). The Canvas
/// inserts them as new layers when such a preset is applied.
extern NSString *const kCanvasPresetPayloadKind;

/// Like `kCanvasPresetPayloadKind`, but the geometry is authored in a SQUARE
/// aspect and its X is compressed by the live canvas aspect (outH/outW) on insert
/// - so diagonal-sensitive art (the checkmark's 45-degree arms) stays correct on
/// any canvas shape, not just 16:9. Axis-aligned presets don't need this.
extern NSString *const kCanvasPresetPayloadKindAspectX;

/// The built-in Canvas annotation presets (animated annotation layers). Register
/// once via `-[KKPresets registerBuiltinPresets:forPluginKey:]` so they appear in
/// the shared Presets popover for Canvas.
NSArray<KKPreset *> *CanvasBuiltinPresets(void);

NS_ASSUME_NONNULL_END
