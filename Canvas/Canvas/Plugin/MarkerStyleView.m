/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "MarkerStyleView.h"
#import <KeyframelessKit/KeyframelessKit.h>

static const CGFloat kPillSpacing = 2.0;
static const CGFloat kPillCorner = 3.0;
static const NSInteger kMarkerCount = 6;
static const CGFloat kPillSize = 22.0;

@implementation KKMarkerStyleView {
  NSArray<NSButton *> *_buttons;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _selectedIndex = 0;
    _isStart = NO;
    [self buildButtons];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

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

- (NSImage *)markerImageForIndex:(NSInteger)index active:(BOOL)active {
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

- (void)buildButtons {
  NSMutableArray<NSButton *> *btns = [NSMutableArray array];

  NSStackView *stack = [NSStackView stackViewWithViews:@[]];
  stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  stack.spacing = kPillSpacing;
  stack.translatesAutoresizingMaskIntoConstraints = NO;

  for (NSInteger i = 0; i < kMarkerCount; i++) {
    BOOL active = (i == _selectedIndex);
    NSButton *btn = [NSButton buttonWithImage:[self markerImageForIndex:i
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
    btn.image = [self markerImageForIndex:i active:active];
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
