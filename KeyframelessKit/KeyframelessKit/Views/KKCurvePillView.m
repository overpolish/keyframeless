/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCurvePillView.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import <AppKit/AppKit.h>

static const CGFloat kPillHeight = 24.0;
static const CGFloat kPillSpacing = 2.0;
static const CGFloat kCurvePad = 4.0;
static const NSInteger kSegments = 60;

@implementation KKCurvePillView

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _pillCount = 0;
    _selectedIndex = 0;
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (NSRect)pillRectForIndex:(NSInteger)index {
  if (_pillCount <= 0)
    return NSZeroRect;
  CGFloat totalSpacing = kPillSpacing * (_pillCount - 1);
  CGFloat pillWidth = (NSWidth(self.bounds) - totalSpacing) / _pillCount;
  CGFloat x = index * (pillWidth + kPillSpacing);
  return NSMakeRect(x, 0, pillWidth, kPillHeight);
}

- (void)redraw {
  [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
  if (_pillCount <= 0 || !_valueBlock)
    return;

  for (NSInteger i = 0; i < _pillCount; i++) {
    NSRect pillRect = [self pillRectForIndex:i];
    BOOL active = (i == _selectedIndex);

    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:pillRect
                                                       xRadius:KKRadiusMD
                                                       yRadius:KKRadiusMD];
    if (active) {
      [[NSColor inspectorBackground] setFill];
      [bg fill];
      [[NSColor accentMatchingHost] setStroke];
      bg.lineWidth = 1.5;
      [bg stroke];
    } else {
      [[[NSColor inspectorLabel] colorWithAlphaComponent:0.06] setFill];
      [bg fill];
    }

    NSRect curveRect = NSInsetRect(pillRect, kCurvePad, kCurvePad);
    [self drawCurveInRect:curveRect pillIndex:i active:active];
  }
}

- (void)drawCurveInRect:(NSRect)rect
              pillIndex:(NSInteger)pillIndex
                 active:(BOOL)active {
  NSColor *color =
      active ? [NSColor accentMatchingHost]
             : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  [color setStroke];

  CGFloat x0 = NSMinX(rect);
  CGFloat x1 = NSMaxX(rect);
  CGFloat yBot = NSMinY(rect);
  CGFloat yTop = NSMaxY(rect);
  CGFloat w = x1 - x0;
  CGFloat h = yTop - yBot;

  CGFloat minVal = CGFLOAT_MAX, maxVal = -CGFLOAT_MAX;
  for (NSInteger j = 0; j <= kSegments; j++) {
    CGFloat t = (CGFloat)j / (CGFloat)kSegments;
    CGFloat v = _valueBlock(pillIndex, t);
    if (v < minVal)
      minVal = v;
    if (v > maxVal)
      maxVal = v;
  }
  CGFloat range = maxVal - minVal;

  NSBezierPath *path = [NSBezierPath bezierPath];
  path.lineWidth = active ? 1.5 : 1.0;

  for (NSInteger j = 0; j <= kSegments; j++) {
    CGFloat t = (CGFloat)j / (CGFloat)kSegments;
    CGFloat v = _valueBlock(pillIndex, t);
    CGFloat normalized = (range > 0) ? (v - minVal) / range : 0.5;
    CGFloat px = x0 + t * w;
    CGFloat py = yTop - normalized * h;

    if (j == 0)
      [path moveToPoint:NSMakePoint(px, py)];
    else
      [path lineToPoint:NSMakePoint(px, py)];
  }

  [path stroke];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  for (NSInteger i = 0; i < _pillCount; i++) {
    if (NSPointInRect(loc, [self pillRectForIndex:i])) {
      _selectedIndex = i;
      [self redraw];
      if (_onSelectionChanged)
        _onSelectionChanged(i);
      return;
    }
  }
}

@end
