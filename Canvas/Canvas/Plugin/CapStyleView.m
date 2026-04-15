/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "CapStyleView.h"
#import <KeyframelessKit/KeyframelessKit.h>

static const CGFloat kPillPad = 3.0;
static const CGFloat kPillSpacing = 2.0;
static const CGFloat kPillCorner = 3.0;
static const NSInteger kCapCount = 3;
static const CGFloat kKappa = 0.5522847498f;

@implementation KKCapStyleView {
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

// All three SVG paths share a common left side:
//   M 2,4 → V 11 → h 10.874 → arc(bump right) → arc(bump left) → H 2 → v 6.996
// Then differ on the right edge closing back to (*, 4).
// The arcs form a small rounded connector between the two bars.

static void drawCapPath(CGFloat ox, CGFloat oy, CGFloat k, NSInteger cap) {
  NSBezierPath *p = [NSBezierPath bezierPath];

  // SVG: M 2,4
  [p moveToPoint:NSMakePoint(ox + 2 * k, oy + 4 * k)];
  // SVG: V 11
  [p lineToPoint:NSMakePoint(ox + 2 * k, oy + 11 * k)];
  // SVG: h 10.874 → (12.874, 11)
  [p lineToPoint:NSMakePoint(ox + 12.874 * k, oy + 11 * k)];
  // SVG: a 0.911,1.004 0 0 1 0.912,1.004 → quarter arc to (13.786, 12.004)
  [p curveToPoint:NSMakePoint(ox + 13.786 * k, oy + 12.004 * k)
      controlPoint1:NSMakePoint(ox + (12.874 + 0.911 * kKappa) * k, oy + 11 * k)
      controlPoint2:NSMakePoint(ox + 13.786 * k,
                                oy + (12.004 - 1.004 * kKappa) * k)];
  // SVG: a 0.911,1.004 0 0 1 -0.912,1.004 → quarter arc to (12.874, 13.008)
  [p curveToPoint:NSMakePoint(ox + 12.874 * k, oy + 13.008 * k)
      controlPoint1:NSMakePoint(ox + 13.786 * k,
                                oy + (12.004 + 1.004 * kKappa) * k)
      controlPoint2:NSMakePoint(ox + (12.874 + 0.911 * kKappa) * k,
                                oy + 13.008 * k)];
  // SVG: H 2
  [p lineToPoint:NSMakePoint(ox + 2 * k, oy + 13.008 * k)];
  // SVG: v 6.996 → (2, 20.004)
  [p lineToPoint:NSMakePoint(ox + 2 * k, oy + 20 * k)];

  // Right edge + close — differs per cap style.
  switch (cap) {
  case 0: // Butt: H 14 V 4 Z
    [p lineToPoint:NSMakePoint(ox + 14 * k, oy + 20 * k)];
    [p lineToPoint:NSMakePoint(ox + 14 * k, oy + 4 * k)];
    break;
  case 1: { // Round: h 11.805, arc(8.195,8) right-up, arc back to top
    // SVG: h 11.805 → (13.805, 20)
    // SVG: a 8.195,8 0 0 0 8.195,-8 → to (22, 12)
    // SVG: a 8.195,8 0 0 0 -8.195,-8 → to (13.805, 4)
    CGFloat cx = 13.805;
    CGFloat ry = 8.0;
    CGFloat rx = 8.195;
    [p lineToPoint:NSMakePoint(ox + cx * k, oy + 20 * k)];
    // Quarter ellipse: (cx,20) → (cx+rx,12), tangent starts right
    [p curveToPoint:NSMakePoint(ox + (cx + rx) * k, oy + 12 * k)
        controlPoint1:NSMakePoint(ox + (cx + rx * kKappa) * k, oy + 20 * k)
        controlPoint2:NSMakePoint(ox + (cx + rx) * k,
                                  oy + (12 + ry * kKappa) * k)];
    // Quarter ellipse: (cx+rx,12) → (cx,4), tangent starts up
    [p curveToPoint:NSMakePoint(ox + cx * k, oy + 4 * k)
        controlPoint1:NSMakePoint(ox + (cx + rx) * k,
                                  oy + (12 - ry * kKappa) * k)
        controlPoint2:NSMakePoint(ox + (cx + rx * kKappa) * k, oy + 4 * k)];
    break;
  }
  default: // Square: H 22 V 4 Z
    [p lineToPoint:NSMakePoint(ox + 22 * k, oy + 20 * k)];
    [p lineToPoint:NSMakePoint(ox + 22 * k, oy + 4 * k)];
    break;
  }

  [p closePath];
  [p fill];
}

- (NSImage *)capImageForIndex:(NSInteger)index active:(BOOL)active {
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

- (void)buildButtons {
  NSMutableArray<NSButton *> *btns = [NSMutableArray array];
  for (NSInteger i = 0; i < kCapCount; i++) {
    BOOL active = (i == _selectedIndex);
    NSButton *btn = [NSButton buttonWithImage:[self capImageForIndex:i
                                                              active:active]
                                       target:self
                                       action:@selector(pillClicked:)];
    btn.bezelStyle = NSBezelStyleSmallSquare;
    btn.bordered = NO;
    btn.tag = i;
    btn.wantsLayer = YES;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:btn];
    [btns addObject:btn];
  }
  _buttons = [btns copy];
  [self updateButtonAppearance];
  [self setNeedsLayout:YES];
}

- (void)updateButtonAppearance {
  for (NSInteger i = 0; i < (NSInteger)_buttons.count; i++) {
    NSButton *btn = _buttons[i];
    BOOL active = (i == _selectedIndex);
    btn.image = [self capImageForIndex:i active:active];
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

- (void)layout {
  [super layout];
  CGFloat h = NSHeight(self.bounds);
  CGFloat pillH = h - kPillPad * 2;
  if (pillH < 8)
    pillH = 8;
  CGFloat pillW = pillH * 1.3;
  CGFloat x = NSWidth(self.bounds) - 75.0;
  CGFloat y = (h - pillH) / 2.0;

  for (NSInteger i = 0; i < (NSInteger)_buttons.count; i++) {
    _buttons[i].frame =
        NSMakeRect(x + i * (pillW + kPillSpacing), y, pillW, pillH);
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
