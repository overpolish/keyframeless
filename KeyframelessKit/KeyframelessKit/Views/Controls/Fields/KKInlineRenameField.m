/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKInlineRenameField.h"

#import "KKFieldEditorSupport.h"

@implementation KKInlineRenameField

// Only while the field is actually editable: a card whose name field sits there
// as a plain label the rest of the time must not grab focus out of the key-view
// loop just by being a text field.
- (BOOL)acceptsFirstResponder {
  return self.isEditable;
}

// The Edit-menu combos (Cmd-A/C/V/X) arrive as key equivalents in the
// ViewBridge popover; handle those. Do NOT [editor keyDown:]-forward anything
// else - in this child panel it bounces back out as another
// performKeyEquivalent and spins (the Esc-after-rename runaway that aborts the
// OSC render). Regular typing reaches the field editor via the normal key path
// (the panel is really key); Enter/Esc are handled in
// control:textView:doCommandBySelector:, Delete via a host key monitor.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
  if (KKHandleEditMenuKeyEquivalent(self.currentEditor, event))
    return YES;
  return [super performKeyEquivalent:event];
}

// Accent caret + selection from the FIRST tick (styling in the delegate's
// controlTextDidBeginEditing doesn't repaint until the first keystroke). Twice:
// the field editor is not always installed yet on the synchronous pass.
- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok) {
    KKStyleFieldEditorAccent(self.currentEditor);
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      KKStyleFieldEditorAccent(weak.currentEditor);
    });
  }
  return ok;
}

@end
