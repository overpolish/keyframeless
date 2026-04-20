/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "MarkerStyleView.h"
#import <KeyframelessKit/KeyframelessKit.h>

static void drawMarkerNone(CGFloat ox, CGFloat oy, CGFloat k) {
  NSBezierPath *p = [NSBezierPath bezierPath];
  CGFloat y = oy + 12 * k;
  [p moveToPoint:NSMakePoint(ox + 4 * k, y)];
  [p lineToPoint:NSMakePoint(ox + 20 * k, y)];
  [p setLineWidth:2.0 * k];
  [p stroke];
}

static void drawMarkerArrow(CGFloat ox, CGFloat oy, CGFloat k, BOOL isStart) {
  NSBezierPath *line = [NSBezierPath bezierPath];
  CGFloat y = oy + 12 * k;
  [line moveToPoint:NSMakePoint(ox + 4 * k, y)];
  [line lineToPoint:NSMakePoint(ox + 20 * k, y)];
  [line setLineWidth:2.0 * k];
  [line stroke];

  NSBezierPath *arrow = [NSBezierPath bezierPath];
  if (isStart) {
    [arrow moveToPoint:NSMakePoint(ox + 10 * k, oy + 7 * k)];
    [arrow lineToPoint:NSMakePoint(ox + 4 * k, y)];
    [arrow lineToPoint:NSMakePoint(ox + 10 * k, oy + 17 * k)];
    [arrow closePath];
  } else {
    [arrow moveToPoint:NSMakePoint(ox + 14 * k, oy + 7 * k)];
    [arrow lineToPoint:NSMakePoint(ox + 20 * k, y)];
    [arrow lineToPoint:NSMakePoint(ox + 14 * k, oy + 17 * k)];
    [arrow closePath];
  }
  [arrow fill];
}

static void drawMarkerCircle(CGFloat ox, CGFloat oy, CGFloat k, BOOL isStart) {
  NSBezierPath *line = [NSBezierPath bezierPath];
  CGFloat y = oy + 12 * k;
  if (isStart) {
    [line moveToPoint:NSMakePoint(ox + 10 * k, y)];
    [line lineToPoint:NSMakePoint(ox + 20 * k, y)];
  } else {
    [line moveToPoint:NSMakePoint(ox + 4 * k, y)];
    [line lineToPoint:NSMakePoint(ox + 14 * k, y)];
  }
  [line setLineWidth:2.0 * k];
  [line stroke];

  CGFloat r = 4.0 * k;
  CGFloat cx = isStart ? (ox + 6 * k) : (ox + 18 * k);
  NSRect circleRect = NSMakeRect(cx - r, y - r, r * 2, r * 2);
  [[NSBezierPath bezierPathWithOvalInRect:circleRect] fill];
}

static void drawMarkerSquare(CGFloat ox, CGFloat oy, CGFloat k, BOOL isStart) {
  NSBezierPath *line = [NSBezierPath bezierPath];
  CGFloat y = oy + 12 * k;
  if (isStart) {
    [line moveToPoint:NSMakePoint(ox + 10 * k, y)];
    [line lineToPoint:NSMakePoint(ox + 20 * k, y)];
  } else {
    [line moveToPoint:NSMakePoint(ox + 4 * k, y)];
    [line lineToPoint:NSMakePoint(ox + 14 * k, y)];
  }
  [line setLineWidth:2.0 * k];
  [line stroke];

  CGFloat side = 7.0 * k;
  CGFloat cx = isStart ? (ox + 6 * k) : (ox + 18 * k);
  NSRect sqRect = NSMakeRect(cx - side / 2, y - side / 2, side, side);
  [NSBezierPath fillRect:sqRect];
}

static void drawMarkerArrowhead(CGFloat ox, CGFloat oy, CGFloat k,
                                BOOL isStart) {
  NSBezierPath *line = [NSBezierPath bezierPath];
  CGFloat y = oy + 12 * k;
  [line moveToPoint:NSMakePoint(ox + 4 * k, y)];
  [line lineToPoint:NSMakePoint(ox + 20 * k, y)];
  [line setLineWidth:2.0 * k];
  [line stroke];

  NSBezierPath *chev = [NSBezierPath bezierPath];
  [chev setLineWidth:2.0 * k];
  [chev setLineCapStyle:NSLineCapStyleRound];
  if (isStart) {
    [chev moveToPoint:NSMakePoint(ox + 10 * k, oy + 7 * k)];
    [chev lineToPoint:NSMakePoint(ox + 4 * k, y)];
    [chev lineToPoint:NSMakePoint(ox + 10 * k, oy + 17 * k)];
  } else {
    [chev moveToPoint:NSMakePoint(ox + 14 * k, oy + 7 * k)];
    [chev lineToPoint:NSMakePoint(ox + 20 * k, y)];
    [chev lineToPoint:NSMakePoint(ox + 14 * k, oy + 17 * k)];
  }
  [chev stroke];
}

static void drawMarkerLine(CGFloat ox, CGFloat oy, CGFloat k, BOOL isStart) {
  NSBezierPath *line = [NSBezierPath bezierPath];
  CGFloat y = oy + 12 * k;
  [line moveToPoint:NSMakePoint(ox + 4 * k, y)];
  [line lineToPoint:NSMakePoint(ox + 20 * k, y)];
  [line setLineWidth:2.0 * k];
  [line stroke];

  NSBezierPath *bar = [NSBezierPath bezierPath];
  [bar setLineWidth:2.0 * k];
  CGFloat bx = isStart ? (ox + 4 * k) : (ox + 20 * k);
  [bar moveToPoint:NSMakePoint(bx, oy + 7 * k)];
  [bar lineToPoint:NSMakePoint(bx, oy + 17 * k)];
  [bar stroke];
}

@implementation KKMarkerStyleView

- (NSInteger)pillCount {
  return 6;
}

- (NSImage *)imageForIndex:(NSInteger)index active:(BOOL)active {
  CGFloat imgSize = 24.0;
  BOOL start = _isStart;
  NSImage *img = [NSImage
       imageWithSize:NSMakeSize(imgSize, imgSize)
             flipped:YES
      drawingHandler:^BOOL(NSRect rect) {
        NSColor *color =
            active ? [NSColor accentMatchingHost]
                   : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
        [color setFill];
        [color setStroke];
        CGFloat s = fmin(rect.size.width, rect.size.height);
        CGFloat ox = NSMinX(rect) + (rect.size.width - s) / 2.0;
        CGFloat oy = NSMinY(rect) + (rect.size.height - s) / 2.0;
        CGFloat k = s / 24.0;
        switch (index) {
        case 0:
          drawMarkerNone(ox, oy, k);
          break;
        case 1:
          drawMarkerArrow(ox, oy, k, start);
          break;
        case 2:
          drawMarkerCircle(ox, oy, k, start);
          break;
        case 3:
          drawMarkerSquare(ox, oy, k, start);
          break;
        case 4:
          drawMarkerArrowhead(ox, oy, k, start);
          break;
        default:
          drawMarkerLine(ox, oy, k, start);
          break;
        }
        return YES;
      }];
  img.template = NO;
  return img;
}

- (void)setIsStart:(BOOL)isStart {
  _isStart = isStart;
  [self rebuildImages];
}

@end
