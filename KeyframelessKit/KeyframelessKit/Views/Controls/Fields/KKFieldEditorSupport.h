/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Shared field-editor helpers for text fields shown in FxPlug ViewBridge
// popovers/panels, where the host stays key and there's no Edit menu, so the
// usual AppKit conveniences don't apply. Extracted from KKValueTextField so
// every field (name/search/rename) behaves identically.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Tint a field editor's caret + selection with the host accent (not system
/// blue). Pass a field's `currentEditor`; no-op unless it's an NSTextView.
/// Apply on becomeFirstResponder AND again next runloop tick - the field editor
/// may not be installed yet on the first call.
void KKStyleFieldEditorAccent(NSText *_Nullable editor);

/// Dispatch the Edit-menu key equivalents (Cmd-A/C/V/X) to a field editor - a
/// ViewBridge popover has no Edit menu, so they never route on their own.
/// Returns YES if the event was one of them (and was handled).
BOOL KKHandleEditMenuKeyEquivalent(NSText *_Nullable editor, NSEvent *event);

/// A local mouse-down monitor that blurs `field` when a click lands outside it
/// while it's editing (the popover won't resign a field on a click that hits a
/// non-responder). Install once; store the returned token and remove it with
/// `[NSEvent removeMonitor:]` in dealloc.
id KKMakeFieldOutsideClickMonitor(NSTextField *field);

NS_ASSUME_NONNULL_END
