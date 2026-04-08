/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKColor.h>
#import <KeyframelessKit/KKPlugin.h>

NS_ASSUME_NONNULL_BEGIN

@class KKColorWellView;
@class KKGradientBarView;

@interface KKPlugin (Color)

/// Registers color parameters (separator, custom UI, mode, RGB, gradient data).
/// Pass the modes the plugin supports (e.g. @[@(KKColorModeSolid),
/// @(KKColorModeGradient)]). When only one mode is given no popup is shown.
- (BOOL)addColorParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                            modes:(NSArray<NSNumber *> *)modes
                            error:(NSError **)error;

/// Returns the current color state at renderTime.
- (KKColorResult *)colorAtTime:(CMTime)renderTime;

/// Updates color parameter visibility. Call from
/// updateParameterVisibilityAtTime:.
- (void)updateColorParameterVisibility;

@end

NS_ASSUME_NONNULL_END
