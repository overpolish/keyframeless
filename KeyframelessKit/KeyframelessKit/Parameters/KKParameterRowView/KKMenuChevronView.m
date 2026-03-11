/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKMenuChevronView.h"
#import "NSColor+KKColors.h"

@implementation KKMenuChevronView

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];

  CGFloat chevronWidth = 6.5;
  CGFloat chevronHeight = 3.5;
  CGFloat rightMargin = 5.5;
  CGFloat bottomOffset = 0.5;

  CGFloat x = self.bounds.size.width - rightMargin - chevronWidth;
  CGFloat y = (self.bounds.size.height - chevronHeight) / 2;

  NSBezierPath *chevron = [NSBezierPath bezierPath];

  // Chevron pointing down
  [chevron moveToPoint:NSMakePoint(0, chevronHeight)]; // Top left
  [chevron lineToPoint:NSMakePoint(chevronWidth / 2, 0)];
  [chevron lineToPoint:NSMakePoint(chevronWidth, chevronHeight)]; // Top right

  NSAffineTransform *transform = [NSAffineTransform transform];
  [transform translateXBy:x yBy:y + bottomOffset];
  [chevron transformUsingAffineTransform:transform];

  [[NSColor inspectorLabelColor] setStroke];
  [chevron setLineWidth:1.5];
  [chevron stroke];
}

@end
