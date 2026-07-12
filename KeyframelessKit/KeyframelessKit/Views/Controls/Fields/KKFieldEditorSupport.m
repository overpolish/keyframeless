/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKFieldEditorSupport.h"

#import "NSColor+KKColors.h"

void KKStyleFieldEditorAccent(NSText *editor) {
  if (![editor isKindOfClass:[NSTextView class]])
    return;
  NSTextView *tv = (NSTextView *)editor;
  NSColor *accent = [NSColor accentMatchingHost];
  tv.insertionPointColor = accent;
  tv.selectedTextAttributes = @{
    NSBackgroundColorAttributeName : [accent colorWithAlphaComponent:0.3],
    NSForegroundColorAttributeName : [NSColor labelColor],
  };
}

BOOL KKHandleEditMenuKeyEquivalent(NSText *editor, NSEvent *event) {
  if (!editor)
    return NO;
  if ((event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) !=
      NSEventModifierFlagCommand)
    return NO;
  NSString *key = event.charactersIgnoringModifiers.lowercaseString;
  if ([key isEqualToString:@"a"]) {
    [editor selectAll:nil];
    return YES;
  }
  if ([key isEqualToString:@"c"]) {
    [(id)editor copy:nil];
    return YES;
  }
  if ([key isEqualToString:@"v"]) {
    [(id)editor paste:nil];
    return YES;
  }
  if ([key isEqualToString:@"x"]) {
    [(id)editor cut:nil];
    return YES;
  }
  return NO;
}

id KKMakeFieldOutsideClickMonitor(NSTextField *field) {
  __weak NSTextField *weakField = field;
  return [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown |
                                           NSEventMaskRightMouseDown
                                   handler:^NSEvent *(NSEvent *e) {
                                     NSTextField *f = weakField;
                                     if (!f || !f.currentEditor)
                                       return e;
                                     NSRect r = [f convertRect:f.bounds
                                                        toView:nil];
                                     if (!(e.window == f.window &&
                                           NSPointInRect(e.locationInWindow,
                                                         r)))
                                       [f.window makeFirstResponder:nil];
                                     return e;
                                   }];
}
