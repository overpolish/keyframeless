/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKNumberFieldCell.h"

@implementation KKNumberFieldCell

- (void)selectWithFrame:(NSRect)rect
                 inView:(NSView *)controlView
                 editor:(NSText *)textObj
               delegate:(id)delegate
                  start:(NSInteger)selStart
                 length:(NSInteger)selLength {
  NSRect adjustedRect = rect;

  [super selectWithFrame:adjustedRect
                  inView:controlView
                  editor:textObj
                delegate:delegate
                   start:selStart
                  length:selLength];
}

- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
  [NSGraphicsContext saveGraphicsState];
  [[NSBezierPath bezierPathWithRect:cellFrame] addClip];
  [super drawInteriorWithFrame:cellFrame inView:controlView];
  [NSGraphicsContext restoreGraphicsState];
}

- (NSText *)setUpFieldEditorAttributes:(NSText *)textObj {
  NSText *result = [super setUpFieldEditorAttributes:textObj];

  if ([result isKindOfClass:[NSTextView class]]) {
    NSTextView *textView = (NSTextView *)result;
    [textView setSelectedTextAttributes:@{
      // TODO pull out into const
      NSBackgroundColorAttributeName : [NSColor colorWithRed:0x59 / 255.0
                                                       green:0x59 / 255.0
                                                        blue:0xE1 / 255.0
                                                       alpha:1.0]
    }];
  }
  return result;
}

@end