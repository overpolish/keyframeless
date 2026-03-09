/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Transparent, click-through view that hosts the animated focus ring as CA
/// layers.
@interface KKFocusRingOverlay : NSView

- (instancetype)initWithColor:(NSColor *)color;
- (void)animateIn;
- (void)hide;
/// Updates the padding used to position ring paths within the overlay's bounds.
- (void)setPanelPadding:(CGFloat)padding;

@end

NS_ASSUME_NONNULL_END
