/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKKeyposeSymbol.h"

#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"

void KKDrawKeyposeDiamond(NSPoint c, CGFloat radius, BOOL filled,
                          NSColor *color) {
  NSBezierPath *d = [NSBezierPath bezierPath];
  [d moveToPoint:NSMakePoint(c.x, c.y + radius)];
  [d lineToPoint:NSMakePoint(c.x + radius, c.y)];
  [d lineToPoint:NSMakePoint(c.x, c.y - radius)];
  [d lineToPoint:NSMakePoint(c.x - radius, c.y)];
  [d closePath];
  if (filled) {
    [color setFill];
    [d fill];
  } else {
    [[[NSColor inspectorBackground] colorWithAlphaComponent:0.9] setFill];
    [d fill];
    d.lineWidth = KKBorderWidthSM;
    [color setStroke];
    [d stroke];
  }
}

void KKDrawKeyposePill(NSRect bounds, BOOL filled, NSColor *color) {
  CGFloat r = MIN(bounds.size.width, bounds.size.height) * 0.5;
  NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:bounds
                                                    xRadius:r
                                                    yRadius:r];
  if (filled) {
    [color setFill];
    [p fill];
  } else {
    [[[NSColor inspectorBackground] colorWithAlphaComponent:0.9] setFill];
    [p fill];
    p.lineWidth = KKBorderWidthSM;
    [color setStroke];
    [p stroke];
  }
}

void KKStrokeTimelineCurve(const NSPoint *points, NSInteger count,
                           CGFloat width, BOOL dashed, NSColor *color) {
  if (count < 2 || !points)
    return;
  NSBezierPath *seg = [NSBezierPath bezierPath];
  [seg moveToPoint:points[0]];
  for (NSInteger i = 1; i < count; i++)
    [seg lineToPoint:points[i]];
  seg.lineWidth = width;
  seg.lineJoinStyle = NSLineJoinStyleRound;
  seg.lineCapStyle = NSLineCapStyleRound;
  if (dashed) {
    CGFloat pattern[] = {4.0, 3.0};
    [seg setLineDash:pattern count:2 phase:0.0];
    [[color colorWithAlphaComponent:0.45] setStroke];
  } else {
    [color setStroke];
  }
  [seg stroke];
}
