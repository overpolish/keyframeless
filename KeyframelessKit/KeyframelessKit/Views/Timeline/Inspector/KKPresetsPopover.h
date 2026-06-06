/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Transient popover listing a plugin's animation presets (built-ins first,
/// badged "Default"; then user presets with rename / overwrite / delete) plus a
/// "save current as" form. Self-contained: reads and mutates the shared
/// `KKPresets` store directly and works in plugin timeline JSON strings, so it
/// stays decoupled from `KKTimeline`. Modeled on `KKGradientFavoritesPopover`.
@interface KKPresetsPopover : NSObject

/// Namespace the listed/saved presets belong to (the plugin's bundle id).
@property(nonatomic, copy, nullable) NSString *pluginKey;

/// Returns the current timeline JSON to capture on save / overwrite. Returning
/// nil or empty cancels the operation.
@property(nonatomic, copy, nullable) NSString *_Nullable (^currentTimelineJSON)
    (void);

/// The user picked a preset to apply; hand back its stored timeline JSON.
/// `atPlayhead` NO = override the whole timeline; YES = merge the preset's
/// animation in starting at the current playhead, keeping existing keyposes.
@property(nonatomic, copy, nullable) void (^onApplyPreset)
    (NSString *timelineJSON, BOOL atPlayhead);

- (void)showRelativeToRect:(NSRect)rect ofView:(NSView *)view;

@end

NS_ASSUME_NONNULL_END
