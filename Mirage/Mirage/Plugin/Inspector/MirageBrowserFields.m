/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageBrowserInternal.h"

#import <KeyframelessKit/KeyframelessKit.h>

@implementation _MirageBrowserItem
@end

@implementation _MirageFlippedView
- (BOOL)isFlipped {
  return YES;
}
- (void)setContentHeight:(CGFloat)contentHeight {
  if (fabs(contentHeight - _contentHeight) < 0.5)
    return;
  _contentHeight = contentHeight;
  [self invalidateIntrinsicContentSize];
}
- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, _contentHeight);
}
@end

@implementation _MirageRenameField
- (BOOL)acceptsFirstResponder {
  return self.isEditable;
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
  // Only the clipboard/select-all combos. Do NOT [editor keyDown:]-forward
  // other events - in this child panel that bounces back out as another
  // performKeyEquivalent and spins (the Esc-after-rename runaway). Let the rest
  // pass; Enter/Esc are handled in doCommandBySelector, Delete via a monitor.
  if (KKHandleEditMenuKeyEquivalent(self.currentEditor, event))
    return YES;
  return [super performKeyEquivalent:event];
}
@end

@implementation _MirageSearchField
- (BOOL)acceptsFirstResponder {
  NSEvent *cur = NSApp.currentEvent;
  BOOL fromClick = cur && (cur.type == NSEventTypeLeftMouseDown ||
                           cur.type == NSEventTypeRightMouseDown);
  if (!fromClick || cur.window != self.window)
    return NO;
  NSPoint p = [self convertPoint:cur.locationInWindow fromView:nil];
  return NSPointInRect(p, self.bounds);
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
  NSText *editor = self.currentEditor;
  if (!editor)
    return [super performKeyEquivalent:event];
  if (KKHandleEditMenuKeyEquivalent(editor, event))
    return YES;
  [editor keyDown:event];
  return YES;
}
// Accent caret + selection from the FIRST tick (styling in the delegate's
// controlTextDidBeginEditing doesn't repaint until the first keystroke).
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
