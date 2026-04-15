/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "StrokeStyleView.h"
#import <KeyframelessKit/KeyframelessKit.h>

static const CGFloat kPillSpacing = 2.0;
static const CGFloat kPillCorner = 3.0;
static const NSInteger kStyleCount = 3;
static const CGFloat kPillSize = 22.0;
static const CGFloat kTrailingSpacer = 75.0;

@implementation KKStrokeStyleView {
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
        CGFloat s = fmin(rect.size.width, rect.size.height);
        CGFloat ox = NSMinX(rect) + (rect.size.width - s) / 2.0;
        CGFloat oy = NSMinY(rect) + (rect.size.height - s) / 2.0;
        drawStrokeStyle(ox, oy, s / 24.0, index);
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

  // Trailing spacer.
  NSView *spacer = [[NSView alloc] init];
  spacer.translatesAutoresizingMaskIntoConstraints = NO;
  [spacer.widthAnchor constraintEqualToConstant:kTrailingSpacer].active = YES;
  [stack addArrangedSubview:spacer];

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
