/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Inline-rename lifecycle for the layer list, split from CanvasLayerListView.m:
// begin / commit, the rename field's end-of-edit delegate callback, and the
// context-menu rename action target.

#import "CanvasLayerListView_Private.h"

#import <KeyframelessKit/KKBezierPath.h>

@implementation CanvasLayerListView (Rename)

- (void)beginRenameAtIndex:(NSUInteger)idx {
  [self _beginRenameAtIndex:idx];
}

- (void)commitRenameIfEditing {
  [self _commitRenameIfEditing];
}

- (void)renameRow:(NSMenuItem *)sender {
  [self _beginRenameAtIndex:(NSUInteger)sender.tag];
}

- (void)_beginRenameAtIndex:(NSUInteger)idx {
  if (idx >= _paths.count)
    return;
  if (_editingIndex >= 0 && _editingIndex != (NSInteger)idx)
    [self _commitRenameIfEditing];
  _editingIndex = (NSInteger)idx;
  [self _rebuildRows];
  // Become key + focus the field on the next tick (after the rebuild lands).
  NSTextField *field = _editingField;
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.window makeKeyWindow];
    [self.window makeFirstResponder:field];
    [field selectText:nil];
    // Now that focus is established, listen for the real end-of-edit.
    field.delegate = self;
  });
}

- (void)_commitRename {
  NSInteger idx = _editingIndex;
  NSTextField *field = _editingField;
  _editingIndex = -1;
  _editingField = nil;
  if (idx < 0 || (NSUInteger)idx >= _paths.count) {
    [self _rebuildRows];
    [self _resetCursorAfterEditing];
    return;
  }
  NSString *newName = [field.stringValue
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  [self _modifyPaths:^(NSMutableArray<KKBezierPath *> *paths) {
    if ((NSUInteger)idx < paths.count && newName.length)
      paths[idx].name = newName;
  }];
  [self _resetCursorAfterEditing];
}

// The field editor installs an I-beam cursor rect that lingers after the field
// is gone; force the arrow back and rebuild cursor rects.
- (void)_resetCursorAfterEditing {
  [self.window invalidateCursorRectsForView:self];
  [[NSCursor arrowCursor] set];
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
  if (_editingIndex < 0)
    return;
  // Defer so we're not mutating the view tree inside the field's callback.
  dispatch_async(dispatch_get_main_queue(), ^{
    [self _commitRename];
  });
}

// Clicking another row's button doesn't change first responder (buttons don't
// take focus on click), so the editing field never gets its end-of-edit and
// the rename would stay live. Commit it before handling any other interaction.
- (void)_commitRenameIfEditing {
  if (_editingIndex < 0)
    return;
  [self.window makeFirstResponder:nil];
  [self _commitRename];
}

@end
