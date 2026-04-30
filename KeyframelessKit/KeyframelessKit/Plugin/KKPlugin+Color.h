/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKColor.h>
#import <KeyframelessKit/KKPlugin.h>

@class KKAnimatableProperty;

NS_ASSUME_NONNULL_BEGIN

@interface KKPlugin (Color)

/// Registers native color parameters (mode popup, color swatch, gradient,
/// dynamic info). Pass the modes the plugin supports.
- (BOOL)addColorParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                            modes:(NSArray<NSNumber *> *)modes
                            error:(NSError **)error;

/// Returns the current color state at renderTime.
- (KKColorResult *)colorAtTime:(CMTime)renderTime;

/// Resolves the popup-index value of `kKKParamColorMode` to the actual
/// `KKColorMode` enum (different plugins order the popup differently, so
/// raw index comparisons don't match the enum). Defaults to Solid when
/// the plugin only supports a single mode.
- (KKColorMode)colorModeAtTime:(CMTime)time;

/// Updates color parameter visibility (hides params based on mode).
- (void)updateColorParameterVisibility;

/// Diff-syncs the gradient bar UI from the persisted JSON param. Call from
/// the plugin's drawOSC and render hooks so undo/redo (and cross-copy state
/// changes) flow back into the inspector.
+ (void)colorSyncFromParams:(id<PROAPIAccessing>)apiManager;

/// Pushes a flat gradient (from a segment's `.values`) directly onto the
/// gradient bar and its favorites popover, bypassing the param-read + diff
/// in `colorSyncFromParams:`. Used after segment-select writes the new
/// gradient to `kKKParamGradientData` — FxPlug's string-param read right
/// after a write can return stale data, so the diff check misses the
/// change. No-op for non-gradient properties.
+ (void)colorPushGradientForProperty:(KKAnimatableProperty *)prop
                              values:(NSArray<NSNumber *> *)flatValues
                          apiManager:(id<PROAPIAccessing>)apiManager;

@end

NS_ASSUME_NONNULL_END
