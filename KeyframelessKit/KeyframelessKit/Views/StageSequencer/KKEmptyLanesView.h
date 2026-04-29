/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Empty-state placeholder shown over the sequencer when every lane is
/// hidden via the lane-visibility bar. SF Symbol + dimmed label, centered.
@interface KKEmptyLanesView : NSView

- (instancetype)init;

@end

NS_ASSUME_NONNULL_END
