/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKCheckboxView.h"
#import <AppKit/AppKit.h>

static const CGFloat kBoxSize = 12.0;
static const CGFloat kCornerRadius = 3.0;

@implementation KKCheckboxView

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _isChecked = NO;

    NSClickGestureRecognizer *click = [[NSClickGestureRecognizer alloc]
        initWithTarget:self
                action:@selector(handleClick:)];
    [self addGestureRecognizer:click];
  }
  return self;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)handleClick:(NSClickGestureRecognizer *)sender {
  _isChecked = !_isChecked;
  [self setNeedsDisplay:YES];
  if (self.onToggle) {
    self.onToggle(_isChecked);
  }
}

- (void)setIsChecked:(BOOL)isChecked {
  _isChecked = isChecked;
  [self setNeedsDisplay:YES];
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(kBoxSize, kBoxSize);
}

- (void)drawRect:(NSRect)dirtyRect {
  CGFloat x = round((NSWidth(self.bounds) - kBoxSize) / 2.0);
  CGFloat y = round((NSHeight(self.bounds) - kBoxSize) / 2.0);
  NSRect borderInset =
      NSInsetRect(NSMakeRect(x, y, kBoxSize, kBoxSize), 0.5, 0.5);

  NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:borderInset
                                                      xRadius:kCornerRadius
                                                      yRadius:kCornerRadius];

  // Outline always drawn
  [[NSColor colorWithRed:0x7F / 255.0
                   green:0x81 / 255.0
                    blue:0x81 / 255.0
                   alpha:1.0] setStroke];
  box.lineWidth = 1.0;
  [box stroke];

  if (_isChecked) {
    NSRect fillRect = NSMakeRect(x, y, kBoxSize, kBoxSize);
    NSBezierPath *fillBox =
        [NSBezierPath bezierPathWithRoundedRect:fillRect
                                        xRadius:kCornerRadius
                                        yRadius:kCornerRadius];
    [[NSColor colorWithRed:0x59 / 255.0
                     green:0x5A / 255.0
                      blue:0xF1 / 255.0
                     alpha:1.0] setFill];
    [fillBox fill];

    NSRect strokeRect = NSInsetRect(fillRect, 0.25, 0.25);
    NSBezierPath *strokeBox =
        [NSBezierPath bezierPathWithRoundedRect:strokeRect
                                        xRadius:kCornerRadius - 0.25
                                        yRadius:kCornerRadius - 0.25];
    [[NSColor colorWithWhite:1.0 alpha:0.15] setStroke];
    strokeBox.lineWidth = 0.25;
    [strokeBox stroke];

    NSBezierPath *check = [NSBezierPath bezierPath];
    check.lineWidth = 1.5;
    check.lineCapStyle = NSLineCapStyleRound;
    check.lineJoinStyle = NSLineJoinStyleBevel;

    [check moveToPoint:NSMakePoint(x + 3.2, y + 5.4)];
    [check lineToPoint:NSMakePoint(x + 5.2, y + 3.6)];
    [check lineToPoint:NSMakePoint(x + 8.8, y + 8.5)];

    [[NSColor colorWithRed:0x17 / 255.0
                     green:0x17 / 255.0
                      blue:0x17 / 255.0
                     alpha:1.0] setStroke];
    [check stroke];
  }
}

@end
