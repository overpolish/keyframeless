/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Private helper views for KKCodeEditorView, lifted out of its .m so the editor
// file stays focused on editor logic. Each is a dumb renderer / input widget
// driven entirely by properties + blocks - no back-reference to the editor.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// The code text view. In a nonactivating FxPlug ViewBridge popover the host
// window stays key, so key events arrive as key EQUIVALENTS (handled in the
// .m). The two blocks let the owner (KKCodeEditorView) intercept Escape and
// classify outside clicks that land on the owner's autocomplete overlay.
@interface _KKCodeTextView : NSTextView
@property(nonatomic, copy) BOOL (^escapeHandler)(void);
@property(nonatomic, copy) BOOL (^benignOutsideClick)(NSEvent *event);
/// First refusal on a PASTE (and only a paste - typing is never routed here):
/// the pasteboard's plain text is offered to the owner, and returning YES means
/// the owner consumed it (the multi-tab `// #tab` split). NO falls through to
/// the ordinary insert-at-caret.
@property(nonatomic, copy) BOOL (^pasteHandler)(NSString *text);
@end

// Hit-transparent edge shadow overlay (decorative only).
@interface _KKErrEdgeShadow : NSView
@end

// The save-bar name field: same first-responder gating as _KKCodeTextView so a
// freshly-shown popover doesn't auto-focus it.
@interface _KKNameField : NSTextField
@end

// Inline autocomplete list for the expression editor: a display-only overlay
// (keyboard-driven) listing matching catalog entries below the caret. All state
// is pushed in by the editor.
@interface _KKExprCompletionView : NSView
@property(nonatomic, copy)
    NSArray<NSDictionary<NSString *, NSString *> *> *items;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic, copy) void (^onPick)(NSInteger index);
- (CGFloat)fittingHeight;
+ (CGFloat)preferredWidth;
@end

// A tiny read-only curve preview: normalises `samples` to its own min/max and
// strokes a polyline, with an accent dot at `marker` (0..1, negative hides it).
@interface _KKSparklineView : NSView
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *samples;
@property(nonatomic) double marker;
@end

NS_ASSUME_NONNULL_END
