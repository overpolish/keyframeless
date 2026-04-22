/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Height of the rendered tick strip (expected imageView height).
extern const CGFloat KKCurveTickHeight;

/// Returns the exact tick index if `value` matches one of the discrete tick
/// positions within epsilon, else -1.
NSInteger KKExactTickIndex(double value, NSInteger tickCount);

/// Renders a horizontal strip of mini curve previews into `imageView`. Each
/// tick evaluates `block(tickIndex, t)` for t ∈ [0, 1] to produce a curve.
/// The tick at `activeIndex` is highlighted with `activeColor`.
void KKRenderHalfWidthTicks(NSImageView *imageView, NSInteger tickCount,
                            NSInteger activeIndex, NSColor *activeColor,
                            CGFloat (^block)(NSInteger tickIndex, CGFloat t));

NS_ASSUME_NONNULL_END
