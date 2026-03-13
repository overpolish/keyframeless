/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Transparent, click-through view that hosts the animated focus ring as CA
/// layers. Intended to fill an NSPanel that is sized with extra padding on all
/// sides so the ring stroke can expand outward without clipping.
@interface KKFocusRingOverlay : NSView

- (instancetype)initWithColor:(NSColor *)color;
- (void)animateIn;
- (void)show; // show immediately, no animation
- (void)hide;
/// Updates the padding used to offset ring paths within the overlay's bounds.
- (void)setPanelPadding:(CGFloat)padding;

@end

NS_ASSUME_NONNULL_END
