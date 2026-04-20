/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "JoinStyleView.h"
#import <KeyframelessKit/KeyframelessKit.h>

static const CGFloat kKappa = 0.5522847498f;

// Each SVG has two sub-paths:
//   Outer: an L-shape whose top-left corner varies per join style.
//   Inner: a smaller L-shape (same for all three).
//
// The corner region (from ~(2,2) area to ~(22,2) area) differs:
//   Miter:  sharp corner at (2,2).
//   Round:  quarter-circle from (2,8) to (8,2) curving through ~(2,2).
//   Bevel:  diagonal line from (2,8) to (8,2).

static void drawJoinPath(CGFloat ox, CGFloat oy, CGFloat k, NSInteger join) {
  NSBezierPath *p = [NSBezierPath bezierPath];

  // --- Outer shape ---
  [p moveToPoint:NSMakePoint(ox + 2 * k, oy + 22 * k)];

  switch (join) {
  case 0: // Miter: sharp corner at (2,2)
    [p lineToPoint:NSMakePoint(ox + 2 * k, oy + 2 * k)];
    [p lineToPoint:NSMakePoint(ox + 22 * k, oy + 2 * k)];
    break;
  case 1: { // Round: up to (2,8), quarter-circle to (8,2), right to (22,2)
    [p lineToPoint:NSMakePoint(ox + 2 * k, oy + 8 * k)];
    CGFloat r = 6.0;
    [p curveToPoint:NSMakePoint(ox + 8 * k, oy + 2 * k)
        controlPoint1:NSMakePoint(ox + 2 * k, oy + (8 - r * kKappa) * k)
        controlPoint2:NSMakePoint(ox + (8 - r * kKappa) * k, oy + 2 * k)];
    [p lineToPoint:NSMakePoint(ox + 22 * k, oy + 2 * k)];
    break;
  }
  default: // Bevel: up to (2,8), diagonal to (8,2), right to (22,2)
    [p lineToPoint:NSMakePoint(ox + 2 * k, oy + 8 * k)];
    [p lineToPoint:NSMakePoint(ox + 8 * k, oy + 2 * k)];
    [p lineToPoint:NSMakePoint(ox + 22 * k, oy + 2 * k)];
    break;
  }

  // Down to the connector.
  [p lineToPoint:NSMakePoint(ox + 22 * k, oy + 7.055 * k)];
  [p lineToPoint:NSMakePoint(ox + 8 * k, oy + 7.055 * k)];
  // Small arc connector.
  [p curveToPoint:NSMakePoint(ox + 7.055 * k, oy + 8 * k)
      controlPoint1:NSMakePoint(ox + (8 - 0.945 * kKappa) * k, oy + 7.055 * k)
      controlPoint2:NSMakePoint(ox + 7.055 * k, oy + (8 - 0.945 * kKappa) * k)];
  [p lineToPoint:NSMakePoint(ox + 7.055 * k, oy + 22 * k)];
  [p closePath];

  // --- Inner L-shape (same for all three) ---
  [p moveToPoint:NSMakePoint(ox + 8.945 * k, oy + 8.945 * k)];
  [p lineToPoint:NSMakePoint(ox + 8.945 * k, oy + 22 * k)];
  [p lineToPoint:NSMakePoint(ox + 14 * k, oy + 22 * k)];
  [p lineToPoint:NSMakePoint(ox + 14 * k, oy + 14 * k)];
  [p lineToPoint:NSMakePoint(ox + 22 * k, oy + 14 * k)];
  [p lineToPoint:NSMakePoint(ox + 22 * k, oy + 8.945 * k)];
  [p closePath];

  [p setWindingRule:NSWindingRuleEvenOdd];
  [p fill];
}

@implementation KKJoinStyleView

- (NSInteger)pillCount {
  return 3;
}

- (NSImage *)imageForIndex:(NSInteger)index active:(BOOL)active {
  CGFloat imgSize = 24.0;
  CGFloat inset = 2.0;
  NSImage *img = [NSImage
       imageWithSize:NSMakeSize(imgSize, imgSize)
             flipped:YES
      drawingHandler:^BOOL(NSRect rect) {
        NSColor *color =
            active ? [NSColor accentMatchingHost]
                   : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
        [color setFill];
        CGFloat s = fmin(rect.size.width, rect.size.height) - inset * 2;
        CGFloat ox = NSMinX(rect) + (rect.size.width - s) / 2.0;
        CGFloat oy = NSMinY(rect) + (rect.size.height - s) / 2.0;
        drawJoinPath(ox, oy, s / 24.0, index);
        return YES;
      }];
  img.template = NO;
  return img;
}

@end
