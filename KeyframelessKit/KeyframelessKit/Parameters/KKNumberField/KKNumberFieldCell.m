/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKNumberFieldCell.h"
#import "NSColor+KKColors.h"
#include <AppKit/AppKit.h>
#import <CoreFoundation/CFCGTypes.h>
#import <Foundation/Foundation.h>

static const CGFloat kInputHorizontalShift =
    1.0; // shift text right within the field

@implementation KKNumberFieldCell

- (void)selectWithFrame:(NSRect)rect
                 inView:(NSView *)controlView
                 editor:(NSText *)textObj
               delegate:(id)delegate
                  start:(NSInteger)selStart
                 length:(NSInteger)selLength {

  NSRect adjustedRect = rect;
  adjustedRect.origin.x += kInputHorizontalShift;

  [super selectWithFrame:adjustedRect
                  inView:controlView
                  editor:textObj
                delegate:delegate
                   start:selStart
                  length:selLength];
}

- (NSRect)drawingRectForBounds:(NSRect)rect {
  // Remove cell's default vertical insets so focus ring matches the background
  // rect
  NSRect adjustedRect = [super drawingRectForBounds:rect];
  adjustedRect.origin.x += kInputHorizontalShift;
  return adjustedRect;
}

- (NSRect)titleRectForBounds:(NSRect)rect {
  NSRect titleRect = [super titleRectForBounds:rect];
  titleRect.origin.x += kInputHorizontalShift;
  return titleRect;
}

- (NSText *)setUpFieldEditorAttributes:(NSText *)textObj {
  NSText *result = [super setUpFieldEditorAttributes:textObj];

  if ([result isKindOfClass:[NSTextView class]]) {
    NSTextView *textView = (NSTextView *)result;
    [textView setSelectedTextAttributes:@{
      NSBackgroundColorAttributeName : [NSColor selection],
      NSForegroundColorAttributeName : [NSColor selectionForeground]
    }];
  }
  return result;
}

@end