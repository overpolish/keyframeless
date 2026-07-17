/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// A small capsule badge: an optional SF Symbol, an optional label, on a tinted
/// pill. The AppKit twin of the app's SwiftUI `InfoBadge` (8pt symbol, 9pt
/// medium text, 5/2 padding) - the captions picker is SwiftUI and the Shader
/// inspector is AppKit, so the geometry is shared by eye, not by code.
///
/// Sizes itself on init; the host reads `frame.size` and places it (the cards
/// lay out with manual frames, not autolayout).
///
/// Deliberately click-through: the card collapses every non-button hit to
/// itself so a badge can't steal the click-to-apply. That also means a badge
/// can't own a tooltip or its own tracking area - a host that needs either
/// drives it (see `-setExpanded:animated:`).
@interface _ShaderBadge : NSView

/// `symbol` and `text` are both optional, but at least one must be non-nil.
/// `color` tints the glyph + label; `fill` is the capsule behind them.
/// `maxWidth` clamps it (0 = unbounded); a label too long for the clamp
/// truncates with an ellipsis and can be revealed via `-setExpanded:animated:`.
- (instancetype)initWithSymbol:(nullable NSString *)symbol
                          text:(nullable NSString *)text
                         color:(NSColor *)color
                          fill:(NSColor *)fill
                      maxWidth:(CGFloat)maxWidth;

/// YES when `maxWidth` actually cut the label short, i.e. expanding reveals
/// something. A host can skip its hover plumbing entirely when this is NO.
@property(nonatomic, readonly) BOOL truncated;

/// Reveal the whole label by growing LEFT - the right edge is pinned, because
/// this sits at the right end of a row and growing right would leave the card.
/// No-op unless `truncated`.
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;

@end

NS_ASSUME_NONNULL_END
