/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "CapStyleView.h"
#import <KeyframelessKit/KeyframelessKit.h>

static const CGFloat kKappa = 0.5522847498f;

// All three SVG paths share a common left side:
//   M 2,4 → V 11 → h 10.874 → arc(bump right) → arc(bump left) → H 2 → v 6.996
// Then differ on the right edge closing back to (*, 4).
// The arcs form a small rounded connector between the two bars.

static void drawCapPath(CGFloat ox, CGFloat oy, CGFloat k, NSInteger cap) {
  NSBezierPath *p = [NSBezierPath bezierPath];

  [p moveToPoint:NSMakePoint(ox + 2 * k, oy + 4 * k)];
  [p lineToPoint:NSMakePoint(ox + 2 * k, oy + 11 * k)];
  [p lineToPoint:NSMakePoint(ox + 12.874 * k, oy + 11 * k)];
  [p curveToPoint:NSMakePoint(ox + 13.786 * k, oy + 12.004 * k)
      controlPoint1:NSMakePoint(ox + (12.874 + 0.911 * kKappa) * k, oy + 11 * k)
      controlPoint2:NSMakePoint(ox + 13.786 * k,
                                oy + (12.004 - 1.004 * kKappa) * k)];
  [p curveToPoint:NSMakePoint(ox + 12.874 * k, oy + 13.008 * k)
      controlPoint1:NSMakePoint(ox + 13.786 * k,
                                oy + (12.004 + 1.004 * kKappa) * k)
      controlPoint2:NSMakePoint(ox + (12.874 + 0.911 * kKappa) * k,
                                oy + 13.008 * k)];
  [p lineToPoint:NSMakePoint(ox + 2 * k, oy + 13.008 * k)];
  [p lineToPoint:NSMakePoint(ox + 2 * k, oy + 20 * k)];

  // Right edge + close — differs per cap style.
  switch (cap) {
  case 0: // Butt
    [p lineToPoint:NSMakePoint(ox + 14 * k, oy + 20 * k)];
    [p lineToPoint:NSMakePoint(ox + 14 * k, oy + 4 * k)];
    break;
  case 1: { // Round
    CGFloat cx = 13.805;
    CGFloat ry = 8.0;
    CGFloat rx = 8.195;
    [p lineToPoint:NSMakePoint(ox + cx * k, oy + 20 * k)];
    [p curveToPoint:NSMakePoint(ox + (cx + rx) * k, oy + 12 * k)
        controlPoint1:NSMakePoint(ox + (cx + rx * kKappa) * k, oy + 20 * k)
        controlPoint2:NSMakePoint(ox + (cx + rx) * k,
                                  oy + (12 + ry * kKappa) * k)];
    [p curveToPoint:NSMakePoint(ox + cx * k, oy + 4 * k)
        controlPoint1:NSMakePoint(ox + (cx + rx) * k,
                                  oy + (12 - ry * kKappa) * k)
        controlPoint2:NSMakePoint(ox + (cx + rx * kKappa) * k, oy + 4 * k)];
    break;
  }
  default: // Square
    [p lineToPoint:NSMakePoint(ox + 22 * k, oy + 20 * k)];
    [p lineToPoint:NSMakePoint(ox + 22 * k, oy + 4 * k)];
    break;
  }

  [p closePath];
  [p fill];
}

@implementation KKCapStyleView

- (NSInteger)pillCount {
  return 3;
}

- (NSImage *)imageForIndex:(NSInteger)index active:(BOOL)active {
  CGFloat imgSize = 24.0;
  NSImage *img = [NSImage
       imageWithSize:NSMakeSize(imgSize, imgSize)
             flipped:YES
      drawingHandler:^BOOL(NSRect rect) {
        NSColor *color =
            active ? [NSColor accentMatchingHost]
                   : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
        [color setFill];
        CGFloat s = fmin(rect.size.width, rect.size.height);
        CGFloat ox = NSMinX(rect) + (rect.size.width - s) / 2.0;
        CGFloat oy = NSMinY(rect) + (rect.size.height - s) / 2.0;
        drawCapPath(ox, oy, s / 24.0, index);
        return YES;
      }];
  img.template = NO;
  return img;
}

@end
