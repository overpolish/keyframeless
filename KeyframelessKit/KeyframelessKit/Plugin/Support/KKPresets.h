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
