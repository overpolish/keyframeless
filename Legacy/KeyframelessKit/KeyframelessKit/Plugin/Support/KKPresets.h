/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One saved animation preset: a named copy of the timeline JSON blob
/// (`kKKParamTimelineData`), scoped to a plugin. `builtin` presets ship in the
/// framework bundle, are read-only (no delete / rename / overwrite) and render
/// with a "Default" badge; their `name` is a localization key looked up for
/// display.
@interface KKPreset : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *pluginKey;
@property(nonatomic, copy) NSString *timelineJSON;
@property(nonatomic, assign) BOOL builtin;
/// Optional plugin-defined content payload. When `payloadKind` is non-empty the
/// preset INSERTS content (the plugin decodes `payloadJSON` for that kind) rather
/// than applying a timeline curve - e.g. Canvas's `"canvasLayers"` kind whose
/// payload is a layer blob. A timeline-only preset leaves both nil. `timelineJSON`
/// may be empty for a content preset.
@property(nonatomic, copy, nullable) NSString *payloadKind;
@property(nonatomic, copy, nullable) NSString *payloadJSON;
/// Display name: built-ins resolve `name` through the localization table;
/// user presets return `name` verbatim.
@property(nonatomic, readonly) NSString *displayName;
@end

/// Per-plugin preset library. User presets persist as JSON in
/// `~/Library/Application Support/Keyframeless/presets.json`; built-ins load
/// from per-plugin bundle resources at first access. Mirrors the gradient
/// favorites store (`KKGradientFavorites`).
@interface KKPresets : NSObject
+ (instancetype)shared;

/// Built-ins first (each tagged `builtin`), then user presets; each group
/// sorted case-insensitively by display name.
- (NSArray<KKPreset *> *)presetsForPluginKey:(NSString *)pluginKey;

/// Register code-built built-in presets for `pluginKey`, merged with any from
/// `builtin_presets.json`. For presets whose payload is built programmatically
/// (e.g. Canvas layer blobs constructed from KKBezierPath) rather than authored
/// as JSON. Each preset is forced `builtin = YES`. Re-registering the same key
/// replaces the previous set. Call once before the presets popover is shown
/// (e.g. at inspector init).
- (void)registerBuiltinPresets:(NSArray<KKPreset *> *)presets
                  forPluginKey:(NSString *)pluginKey;

- (KKPreset *)addPresetWithName:(NSString *)name
                      pluginKey:(NSString *)pluginKey
                   timelineJSON:(NSString *)timelineJSON;
/// No-ops on a built-in or unknown identifier.
- (void)removePresetWithIdentifier:(NSString *)identifier;
- (void)renamePresetWithIdentifier:(NSString *)identifier
                            toName:(NSString *)name;
- (void)updatePresetWithIdentifier:(NSString *)identifier
                      timelineJSON:(NSString *)timelineJSON;
@end

NS_ASSUME_NONNULL_END
