/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "JoinStyleView.h"
#import <KeyframelessKit/KeyframelessKit.h>

static const CGFloat kPillSpacing = 2.0;
static const CGFloat kPillCorner = 3.0;
static const NSInteger kJoinCount = 3;
static const CGFloat kKappa = 0.5522847498f;
static const CGFloat kPillSize = 22.0;

@implementation KKJoinStyleView {
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
  // Start at bottom-left.
  [p moveToPoint:NSMakePoint(ox + 2 * k, oy + 22 * k)];

  // Up the left edge — destination depends on join style.
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
  // Left to connector start.
  [p lineToPoint:NSMakePoint(ox + 8 * k, oy + 7.055 * k)];
  // Small arc connector (same as cap view's arc).
  [p curveToPoint:NSMakePoint(ox + 7.055 * k, oy + 8 * k)
      controlPoint1:NSMakePoint(ox + (8 - 0.945 * kKappa) * k, oy + 7.055 * k)
      controlPoint2:NSMakePoint(ox + 7.055 * k, oy + (8 - 0.945 * kKappa) * k)];
  // Down to bottom.
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

- (NSImage *)joinImageForIndex:(NSInteger)index active:(BOOL)active {
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

- (void)buildButtons {
  NSMutableArray<NSButton *> *btns = [NSMutableArray array];

  NSStackView *stack = [NSStackView stackViewWithViews:@[]];
  stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  stack.spacing = kPillSpacing;
  stack.translatesAutoresizingMaskIntoConstraints = NO;

  for (NSInteger i = 0; i < kJoinCount; i++) {
    BOOL active = (i == _selectedIndex);
    NSButton *btn = [NSButton buttonWithImage:[self joinImageForIndex:i
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
    btn.image = [self joinImageForIndex:i active:active];
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
