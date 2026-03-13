/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKNumberFieldCell.h"
#include <CoreFoundation/CFCGTypes.h>
#include <Foundation/Foundation.h>

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

- (NSRect)drawingRectForBounds:(NSRect)rect {
  // Remove cell's default vertical insets so focus ring matches the background
  // rect
  NSRect adjustedRect = [super drawingRectForBounds:rect];
  rect.origin.y = rect.origin.y;
  rect.size.height = rect.size.height;
  return adjustedRect;
}

- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
  [NSGraphicsContext saveGraphicsState];
  [[NSBezierPath bezierPathWithRect:cellFrame] addClip];
  [super drawInteriorWithFrame:cellFrame inView:controlView];
  [NSGraphicsContext restoreGraphicsState];
}

@end