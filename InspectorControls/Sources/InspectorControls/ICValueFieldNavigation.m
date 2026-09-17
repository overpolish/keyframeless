/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ICValueTextField_Private.h"

BOOL ICValueFieldHandleReturnCommand(NSWindow *window, SEL commandSelector) {
  if (commandSelector == @selector(insertNewline:) || commandSelector == @selector(cancelOperation:)) {
    [window makeFirstResponder:nil];
    return YES;
  }
  return NO;
}

static void ICCollectValueFields(NSView *view, NSMutableArray<ICValueTextField *> *fields) {
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[ICValueTextField class]] && ((ICValueTextField *)subview).isEditable && ((ICValueTextField *)subview).isEnabled && !subview.isHiddenOrHasHiddenAncestor)
      [fields addObject:(ICValueTextField *)subview];
    ICCollectValueFields(subview, fields);
  }
}

BOOL ICValueFieldHandleTabCommand(NSTextField *field, SEL commandSelector) {
  BOOL forward = commandSelector == @selector(insertTab:);
  BOOL backward = commandSelector == @selector(insertBacktab:);
  if (!forward && !backward) return NO;
  if (![field isKindOfClass:[ICValueTextField class]]) return NO;
  NSView *root = field.window.contentView;
  if (!root) return YES;
  NSMutableArray<ICValueTextField *> *fields = [NSMutableArray array];
  ICCollectValueFields(root, fields);
  if (fields.count < 2) return YES;
  [fields sortUsingComparator:^NSComparisonResult(ICValueTextField *a, ICValueTextField *b) {
    NSRect ra = [a convertRect:a.bounds toView:nil], rb = [b convertRect:b.bounds toView:nil];
    if (fabs(NSMaxY(ra) - NSMaxY(rb)) > 1.0) return NSMaxY(ra) > NSMaxY(rb) ? NSOrderedAscending : NSOrderedDescending;
    return NSMinX(ra) <= NSMinX(rb) ? NSOrderedAscending : NSOrderedDescending;
  }];
  NSInteger index = [fields indexOfObject:(ICValueTextField *)field];
  if (index == NSNotFound) return YES;
  NSInteger count = (NSInteger)fields.count;
  NSInteger next = forward ? (index + 1) % count : (index - 1 + count) % count;
  ICValueTextField *current = (ICValueTextField *)field;
  current.icNavigatingAway = YES;
  [fields[next] focusForKeyboardNavigation];
  current.icNavigatingAway = NO;
  return YES;
}
