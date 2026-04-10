/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKColor.h>
#import <KeyframelessKit/KKPlugin.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKPlugin (Color)

/// Registers native color parameters (mode popup, color swatch, gradient,
/// dynamic info). Pass the modes the plugin supports.
- (BOOL)addColorParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                            modes:(NSArray<NSNumber *> *)modes
                            error:(NSError **)error;

/// Returns the current color state at renderTime.
- (KKColorResult *)colorAtTime:(CMTime)renderTime;

/// Updates color parameter visibility (hides params based on mode).
- (void)updateColorParameterVisibility;

@end

NS_ASSUME_NONNULL_END
