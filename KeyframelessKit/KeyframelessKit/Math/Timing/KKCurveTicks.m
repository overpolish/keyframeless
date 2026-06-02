/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCurveTicks.h"

#import "NSColor+KKColors.h"

const CGFloat KKCurveTickHeight = 10.0;

static const double kTickEpsilon = 0.01;

NSInteger KKExactTickIndex(double value, NSInteger tickCount) {
  for (NSInteger i = 0; i < tickCount; i++) {
    double tickVal = (double)i / (double)(tickCount - 1);
    if (fabs(value - tickVal) < kTickEpsilon)
      return i;
  }
  return -1;
}

void KKRenderHalfWidthTicks(NSImageView *imageView, NSInteger tickCount,
                            NSInteger activeIndex, NSColor *activeColor,
                            CGFloat (^block)(NSInteger tickIndex, CGFloat t)) {
  CGFloat tickAreaWidth = NSWidth(imageView.bounds);
  if (tickAreaWidth < 1)
    return;

  static const CGFloat kHalfTickWidth = 18.0;
  static const NSInteger kTickSegments = 60;

  NSImage *image = [[NSImage alloc]
      initWithSize:NSMakeSize(tickAreaWidth, KKCurveTickHeight)];
  [image lockFocus];

  CGFloat tickPad = kHalfTickWidth / 2.0;
  CGFloat usableWidth = tickAreaWidth - 2 * tickPad;

  for (NSInteger i = 0; i < tickCount; i++) {
    CGFloat frac =
        (tickCount > 1) ? (CGFloat)i / (CGFloat)(tickCount - 1) : 0.5;
    CGFloat centerX = tickPad + frac * usableWidth;
    NSRect tickRect = NSMakeRect(centerX - kHalfTickWidth / 2.0, 0,
                                 kHalfTickWidth, KKCurveTickHeight);
    BOOL active = (i == activeIndex);

    NSColor *color =
        active ? activeColor
               : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
    [color setStroke];

    CGFloat pad = 2.0;
    CGFloat x0 = NSMinX(tickRect) + pad;
    CGFloat x1 = NSMaxX(tickRect) - pad;
    CGFloat yBot = NSMinY(tickRect) + pad;
    CGFloat yTop = NSMaxY(tickRect) - pad;
    CGFloat w = x1 - x0;
    CGFloat h = yTop - yBot;

    CGFloat minVal = 0.0, maxVal = 1.0;
    for (NSInteger j = 0; j <= kTickSegments; j++) {
      CGFloat t = (CGFloat)j / (CGFloat)kTickSegments;
      CGFloat v = block(i, t);
      if (v < minVal)
        minVal = v;
      if (v > maxVal)
        maxVal = v;
    }
    CGFloat range = maxVal - minVal;

    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = active ? 1.5 : 1.0;

    for (NSInteger j = 0; j <= kTickSegments; j++) {
      CGFloat t = (CGFloat)j / (CGFloat)kTickSegments;
      CGFloat v = block(i, t);
      CGFloat normalized = (range > 0) ? (v - minVal) / range : 0.5;
      CGFloat px = x0 + t * w;
      CGFloat py = yBot + normalized * h;

      if (j == 0)
        [path moveToPoint:NSMakePoint(px, py)];
      else
        [path lineToPoint:NSMakePoint(px, py)];
    }

    [path stroke];
  }

  [image unlockFocus];
  imageView.image = image;
}
