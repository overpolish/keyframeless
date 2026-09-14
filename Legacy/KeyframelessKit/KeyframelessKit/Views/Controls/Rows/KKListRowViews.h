/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Leading glyph (image thumbnail / group folder) as a passthrough view, so a
/// click or drag started over it reaches the row (select / reorder) rather than
/// being eaten by a button. Matches the name label.
@interface KKListGlyphView : NSImageView
@end

/// The row name is a label, not a button, so a drag started over it reaches
/// the row (buttons would run their own tracking loop and swallow the drag).
@interface KKListNameLabel : NSTextField
@end

/// A view that passes clicks/scroll through to whatever is beneath it (used for
/// the scroll-edge shadow overlays and spacer columns).
@interface KKListPassthroughView : NSView
@end

/// A companion panel is borderless and non-activating, so every click is a
/// "first mouse" event - buttons must opt in or they ignore clicks.
@interface KKListFirstMouseButton : NSButton
@end

/// A small inline icon button (eye / lock / disclosure chevron) for a row.
extern NSButton *KKListIconButton(NSString *symbol,
                                  NSImageSymbolConfiguration *cfg, id target,
                                  SEL action, NSUInteger tag, NSColor *tint);

NS_ASSUME_NONNULL_END
