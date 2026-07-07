/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Leading glyph (image thumbnail / group folder) as a passthrough view, so a
/// click or drag started over it reaches the row (select / reorder) rather than
/// being eaten by a button. Matches the name label.
@interface CanvasLayerGlyphView : NSImageView
@end

/// The layer name is a label, not a button, so a drag started over it reaches
/// the row (buttons would run their own tracking loop and swallow the drag).
@interface CanvasLayerNameLabel : NSTextField
@end

/// A view that passes clicks/scroll through to whatever is beneath it (used for
/// the scroll-edge shadow overlays and spacer columns).
@interface CanvasLayerPassthroughView : NSView
@end

/// The Layers panel is a borderless non-activating panel, so every click is a
/// "first mouse" event - buttons must opt in or they ignore clicks.
@interface CanvasLayerFirstMouseButton : NSButton
@end

/// Inline rename field. In a ViewBridge popover key events arrive as key
/// equivalents to the window, not normal keyDown to the field editor, so this
/// forwards them (the mechanism KKValueTextField uses) and applies the accent
/// caret/selection styling.
@interface CanvasLayerRenameField : NSTextField
@end

/// Image file extensions accepted as drag-in layers.
extern NSSet<NSString *> *CanvasLayerImageExtensions(void);

/// A small inline icon button (eye / lock / disclosure chevron) for a row.
extern NSButton *CanvasLayerIconButton(NSString *symbol,
                                       NSImageSymbolConfiguration *cfg,
                                       id target, SEL action, NSUInteger tag,
                                       NSColor *tint);

NS_ASSUME_NONNULL_END
