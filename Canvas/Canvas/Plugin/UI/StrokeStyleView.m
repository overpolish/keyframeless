/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "StrokeStyleView.h"
#import <KeyframelessKit/KeyframelessKit.h>

static void drawStrokeStyle(CGFloat ox, CGFloat oy, CGFloat k,
                            NSInteger style) {
  NSBezierPath *p = [NSBezierPath bezierPath];

  switch (style) {
  case 0: {
    // Solid: single rounded rect centered vertically.
    NSRect r = NSMakeRect(ox + 4 * k, oy + 10.5 * k, 16 * k, 3 * k);
    [p appendBezierPathWithRoundedRect:r xRadius:1.5 * k yRadius:1.5 * k];
    break;
  }
  case 1: {
    // Dashed: two rounded rects with a gap.
    NSRect r1 = NSMakeRect(ox + 4 * k, oy + 10.5 * k, 7 * k, 3 * k);
    [p appendBezierPathWithRoundedRect:r1 xRadius:1.5 * k yRadius:1.5 * k];
    NSRect r2 = NSMakeRect(ox + 13 * k, oy + 10.5 * k, 7 * k, 3 * k);
    [p appendBezierPathWithRoundedRect:r2 xRadius:1.5 * k yRadius:1.5 * k];
    break;
  }
  default: {
    // Dotted: four circles evenly spaced.
    for (NSInteger i = 0; i < 4; i++) {
      CGFloat cx = ox + (5.75 + i * 4.25) * k;
      CGFloat cy = oy + 12 * k;
      NSRect r = NSMakeRect(cx - 1.5 * k, cy - 1.5 * k, 3 * k, 3 * k);
      [p appendBezierPathWithOvalInRect:r];
    }
    break;
  }
  }

  [p fill];
}

@implementation KKStrokeStyleView

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
        drawStrokeStyle(ox, oy, s / 24.0, index);
        return YES;
      }];
  img.template = NO;
  return img;
}

@end
