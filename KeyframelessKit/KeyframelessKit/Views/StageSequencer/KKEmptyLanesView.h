/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Empty-state placeholder shown over the sequencer when every lane is
/// hidden via the lane-visibility bar (or when a dynamic-lane plugin has
/// no source items, e.g. Canvas with no layers). SF Symbol + dimmed label,
/// centered. Content is settable so the same view serves both cases.
@interface KKEmptyLanesView : NSView

- (instancetype)init;

- (void)setText:(NSString *)text iconName:(NSString *)iconName;

@end

NS_ASSUME_NONNULL_END
