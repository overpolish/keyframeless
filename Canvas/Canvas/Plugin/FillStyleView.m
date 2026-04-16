/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "FillStyleView.h"
#import <KeyframelessKit/KeyframelessKit.h>

static const CGFloat kPillSpacing = 2.0;
static const CGFloat kPillCorner = 3.0;
static const NSInteger kStyleCount = 5;
static const CGFloat kPillSize = 22.0;

@implementation KKFillStyleView {
  NSArray<NSButton *> *_buttons;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _selectedIndex = 0;
    [self buildButtons];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

static void drawFillStyle(CGFloat ox, CGFloat oy, CGFloat k, NSInteger style) {
  NSBezierPath *p = [NSBezierPath bezierPath];

  // All styles draw inside a 14x14 area centered in the 24x24 cell.
  CGFloat inset = 5.0 * k;
  CGFloat size = 14.0 * k;

  switch (style) {
  case 0: {
    // Solid: filled rounded rect.
    NSRect r = NSMakeRect(ox + inset, oy + inset, size, size);
    [p appendBezierPathWithRoundedRect:r xRadius:2.0 * k yRadius:2.0 * k];
    [p fill];
    break;
  }
  case 1: {
    // Hachure: diagonal parallel lines (bottom-left to top-right).
    NSRect clipRect = NSMakeRect(ox + inset, oy + inset, size, size);
    [NSGraphicsContext saveGraphicsState];
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:clipRect
                                                         xRadius:2.0 * k
                                                         yRadius:2.0 * k];
    [clip addClip];
    for (CGFloat offset = -size; offset <= size * 2; offset += 4.5 * k) {
      NSBezierPath *line = [NSBezierPath bezierPath];
      [line moveToPoint:NSMakePoint(ox + inset + offset, oy + inset + size)];
      [line lineToPoint:NSMakePoint(ox + inset + offset + size, oy + inset)];
      [line setLineWidth:1.0 * k];
      [line stroke];
    }
    [NSGraphicsContext restoreGraphicsState];
    break;
  }
  case 2: {
    // Cross-hatch: two sets of diagonal lines crossing.
    NSRect clipRect = NSMakeRect(ox + inset, oy + inset, size, size);
    [NSGraphicsContext saveGraphicsState];
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:clipRect
                                                         xRadius:2.0 * k
                                                         yRadius:2.0 * k];
    [clip addClip];
    for (CGFloat offset = -size; offset <= size * 2; offset += 5.0 * k) {
      NSBezierPath *line = [NSBezierPath bezierPath];
      [line moveToPoint:NSMakePoint(ox + inset + offset, oy + inset + size)];
      [line lineToPoint:NSMakePoint(ox + inset + offset + size, oy + inset)];
      [line setLineWidth:1.0 * k];
      [line stroke];
    }
    for (CGFloat offset = -size; offset <= size * 2; offset += 5.0 * k) {
      NSBezierPath *line = [NSBezierPath bezierPath];
      [line moveToPoint:NSMakePoint(ox + inset + offset, oy + inset)];
      [line lineToPoint:NSMakePoint(ox + inset + offset + size,
                                    oy + inset + size)];
      [line setLineWidth:1.0 * k];
      [line stroke];
    }
    [NSGraphicsContext restoreGraphicsState];
    break;
  }
  case 3: {
    // Zigzag: single zigzag line centered vertically.
    NSRect clipRect = NSMakeRect(ox + inset, oy + inset, size, size);
    [NSGraphicsContext saveGraphicsState];
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:clipRect
                                                         xRadius:2.0 * k
                                                         yRadius:2.0 * k];
    [clip addClip];
    CGFloat zigH = 3.0 * k;
    CGFloat zigW = 2.5 * k;
    CGFloat midY = oy + inset + (size - zigH) / 2.0;
    NSBezierPath *zig = [NSBezierPath bezierPath];
    [zig moveToPoint:NSMakePoint(ox + inset, midY)];
    for (CGFloat x = 0; x < size; x += zigW * 2) {
      [zig lineToPoint:NSMakePoint(ox + inset + x + zigW, midY + zigH)];
      [zig lineToPoint:NSMakePoint(ox + inset + x + zigW * 2, midY)];
    }
    [zig setLineWidth:1.2 * k];
    [zig stroke];
    [NSGraphicsContext restoreGraphicsState];
    break;
  }
  default: {
    // Dots: 3x3 grid of circles.
    NSRect clipRect = NSMakeRect(ox + inset, oy + inset, size, size);
    [NSGraphicsContext saveGraphicsState];
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:clipRect
                                                         xRadius:2.0 * k
                                                         yRadius:2.0 * k];
    [clip addClip];
    CGFloat dotR = 1.0 * k;
    CGFloat step = size / 4.0;
    for (NSInteger row = 0; row < 3; row++) {
      for (NSInteger col = 0; col < 3; col++) {
        CGFloat cx = ox + inset + step * (col + 1);
        CGFloat cy = oy + inset + step * (row + 1);
        NSRect dot = NSMakeRect(cx - dotR, cy - dotR, dotR * 2, dotR * 2);
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
      }
    }
    [NSGraphicsContext restoreGraphicsState];
    break;
  }
  }
}

- (NSImage *)styleImageForIndex:(NSInteger)index active:(BOOL)active {
  CGFloat imgSize = 24.0;
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
        drawFillStyle(ox, oy, s / 24.0, index);
        return YES;
      }];
  img.template = NO;
  return img;
}

- (void)buildButtons {
  NSMutableArray<NSButton *> *btns = [NSMutableArray array];

  NSStackView *stack = [NSStackView stackViewWithViews:@[]];
  stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  stack.spacing = kPillSpacing;
  stack.translatesAutoresizingMaskIntoConstraints = NO;

  for (NSInteger i = 0; i < kStyleCount; i++) {
    BOOL active = (i == _selectedIndex);
    NSButton *btn = [NSButton buttonWithImage:[self styleImageForIndex:i
                                                                active:active]
                                       target:self
                                       action:@selector(pillClicked:)];
    btn.bezelStyle = NSBezelStyleSmallSquare;
    btn.bordered = NO;
    btn.tag = i;
    btn.wantsLayer = YES;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn.widthAnchor constraintEqualToConstant:kPillSize].active = YES;
    [btn.heightAnchor constraintEqualToConstant:kPillSize].active = YES;
    [stack addArrangedSubview:btn];
    [btns addObject:btn];
  }

  [self addSubview:stack];
  [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor].active =
      YES;
  [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor].active = YES;

  _buttons = [btns copy];
  [self updateButtonAppearance];
}

- (void)updateButtonAppearance {
  for (NSInteger i = 0; i < (NSInteger)_buttons.count; i++) {
    NSButton *btn = _buttons[i];
    BOOL active = (i == _selectedIndex);
    btn.image = [self styleImageForIndex:i active:active];
    btn.layer.cornerRadius = kPillCorner;
    if (active) {
      btn.layer.backgroundColor = [NSColor inspectorBackground].CGColor;
      btn.layer.borderColor = [NSColor accentMatchingHost].CGColor;
      btn.layer.borderWidth = 1.0;
    } else {
      btn.layer.backgroundColor =
          [[NSColor inspectorLabel] colorWithAlphaComponent:0.06].CGColor;
      btn.layer.borderColor = [NSColor clearColor].CGColor;
      btn.layer.borderWidth = 0.0;
    }
  }
}

- (void)pillClicked:(NSButton *)sender {
  _selectedIndex = sender.tag;
  [self updateButtonAppearance];
  if (_onSelectionChanged)
    _onSelectionChanged(_selectedIndex);
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
  _selectedIndex = selectedIndex;
  [self updateButtonAppearance];
}

@end
