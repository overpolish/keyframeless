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
    NSColor *accent = _accentColor ?: [NSColor accentMatchingHost];
    if (active) {
      [[NSColor inspectorBackground] setFill];
      [bg fill];
      [accent setStroke];
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
  NSColor *accent = _accentColor ?: [NSColor accentMatchingHost];
  NSColor *color =
      active ? accent : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  [color setStroke];

  CGFloat x0 = NSMinX(rect);
  CGFloat x1 = NSMaxX(rect);
  CGFloat yBot = NSMinY(rect);
  CGFloat yTop = NSMaxY(rect);
  CGFloat w = x1 - x0;
  CGFloat h = yTop - yBot;

  CGFloat minVal, maxVal;
  if (_usesFixedRange) {
    minVal = _fixedMin;
    maxVal = _fixedMax;
  } else {
    minVal = CGFLOAT_MAX;
    maxVal = -CGFLOAT_MAX;
    for (NSInteger j = 0; j <= kSegments; j++) {
      CGFloat t = (CGFloat)j / (CGFloat)kSegments;
      CGFloat v = _valueBlock(pillIndex, t);
      if (v < minVal)
        minVal = v;
      if (v > maxVal)
        maxVal = v;
    }
  }
  CGFloat range = maxVal - minVal;

  NSBezierPath *path = [NSBezierPath bezierPath];
  path.lineWidth = active ? 1.5 : 1.0;

  // Fixed-range pills oscillate about the neutral midpoint (value 1.0 →
  // 0.5). A subtle setting barely deviates and would read as a flat line,
  // so remap the *amplitude* through a compressive curve - one uniform
  // scale about the midpoint, applied to every sample. The waveform's
  // shape stays exact (a sine still looks like a sine) while low
  // intensity/frequency becomes visible and stronger settings still read
  // bigger (monotonic - the slider's effect stays legible).
  CGFloat ampGain = 1.0;
  if (_usesFixedRange) {
    CGFloat peak = 0.0;
    for (NSInteger j = 0; j <= kSegments; j++) {
      CGFloat t = (CGFloat)j / (CGFloat)kSegments;
      CGFloat n =
          (range > 0) ? (_valueBlock(pillIndex, t) - minVal) / range : 0.5;
      n = MAX(0.0, MIN(1.0, n));
      peak = MAX(peak, (CGFloat)fabs(n - 0.5));
    }
    if (peak > 1.0e-4) {
      CGFloat shown = 0.5 * pow(peak / 0.5, 0.5); // √: lift small, keep order
      ampGain = shown / peak;
    }
  }

  for (NSInteger j = 0; j <= kSegments; j++) {
    CGFloat t = (CGFloat)j / (CGFloat)kSegments;
    CGFloat v = _valueBlock(pillIndex, t);
    CGFloat normalized = (range > 0) ? (v - minVal) / range : 0.5;
    if (_usesFixedRange) {
      normalized = MAX(0.0, MIN(1.0, normalized));
      normalized = 0.5 + (normalized - 0.5) * ampGain; // uniform: shape-true
      normalized = MAX(0.0, MIN(1.0, normalized));
    }
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
