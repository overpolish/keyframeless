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

#pragma mark - Guide support

/// When YES the popover stays open (ApplicationDefined behavior) and applying a
/// preset does NOT auto-close it, so a walkthrough can drive apply / insert /
/// save in one open popover. The guide owns closing it.
@property(nonatomic) BOOL guideMode;
/// Fired right after the popover is shown (guide's open step advances on it).
@property(nonatomic, copy, nullable) void (^onDidShow)(void);
/// Fired after any preset is applied (guide advances on it).
@property(nonatomic, copy, nullable) void (^onDidApplyPreset)(void);
/// Fired after a preset is saved, with its new identifier (guide captures it
/// to delete on completion, and advances).
@property(nonatomic, copy, nullable) void (^onDidSavePreset)
    (NSString *identifier);
/// The popover's window, for the guide's `additionalPassthroughWindow`.
@property(nonatomic, readonly, nullable) NSWindow *popoverWindow;
- (NSRect)guidePopoverScreenRect; // the whole popover content
- (NSRect)guideFirstRowScreenRect;
- (NSRect)guideFirstRowInsertButtonScreenRect;
- (NSRect)guideSaveAreaScreenRect; // field + save button unioned
/// Pre-fill the name/filter field (so a guide's save step is a single click).
- (void)guidePrefillName:(NSString *)name;
- (void)closeForGuide;

@end

NS_ASSUME_NONNULL_END
