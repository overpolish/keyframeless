/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKPillToggleRowView.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import <AppKit/AppKit.h>

static const CGFloat kPillHeight = 18.0;
static const CGFloat kPillSpacing = 2.0;
static const CGFloat kRowSpacing = 2.0;
static const CGFloat kPillPadX = 5.0;

@implementation KKPillToggleRowView {
  NSArray<NSString *> *_labels;
  NSArray<NSImage *> *_icons;
  NSInteger _count;
}

- (instancetype)initWithLabels:(NSArray<NSString *> *)labels {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _labels = [labels copy];
    _count = labels.count;
    [self _initStates];
  }
  return self;
}

- (instancetype)initWithIcons:(NSArray<NSImage *> *)icons {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _icons = [icons copy];
    _count = icons.count;
    [self _initStates];
  }
  return self;
}

- (void)_initStates {
  NSMutableArray *s = [NSMutableArray arrayWithCapacity:_count];
  for (NSInteger i = 0; i < _count; i++)
    [s addObject:@YES];
  _states = [s copy];
}

- (BOOL)isFlipped {
  return YES;
}

- (void)setState:(BOOL)on atIndex:(NSInteger)index {
  if (index < 0 || index >= _count)
    return;
  NSMutableArray *s = [_states mutableCopy];
  s[index] = @(on);
  _states = [s copy];
  [self setNeedsDisplay:YES];
}

- (NSFont *)pillFont {
  return [NSFont systemFontOfSize:8.0 weight:NSFontWeightMedium];
}

- (CGFloat)pillWidthForIndex:(NSInteger)i {
  if (_icons) {
    return 10.0 + 2 * kPillPadX;
  }
  NSFont *font = [self pillFont];
  NSDictionary *attrs = @{NSFontAttributeName : font};
  CGFloat textW = [_labels[i] sizeWithAttributes:attrs].width;
  return textW + 2 * kPillPadX;
}

- (NSArray<NSValue *> *)pillRects {
  CGFloat availableWidth = NSWidth(self.bounds);
  NSMutableArray<NSValue *> *rects = [NSMutableArray array];

  CGFloat totalWidth = 0;
  for (NSInteger i = 0; i < _count; i++)
    totalWidth += [self pillWidthForIndex:i] + (i > 0 ? kPillSpacing : 0);

  CGFloat x = availableWidth - totalWidth;
  for (NSInteger i = 0; i < _count; i++) {
    CGFloat w = [self pillWidthForIndex:i];
    [rects addObject:[NSValue valueWithRect:NSMakeRect(x, 0, w, kPillHeight)]];
    x += w + kPillSpacing;
  }

  return rects;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSArray<NSValue *> *rects = [self pillRects];

  for (NSInteger i = 0; i < _count; i++) {
    NSRect r = rects[i].rectValue;
    BOOL on = _states[i].boolValue;

    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:r
                                                       xRadius:KKRadiusMD
                                                       yRadius:KKRadiusMD];
    if (on) {
      [[[NSColor accentMatchingHost] colorWithAlphaComponent:0.15] setFill];
      [bg fill];
    } else {
      [[[NSColor inspectorLabel] colorWithAlphaComponent:0.06] setFill];
      [bg fill];
    }

    NSColor *tint =
        on ? [NSColor accentMatchingHost]
           : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];

    if (_icons) {
      NSImage *icon =
          [_icons[i] imageWithSymbolConfiguration:
                         [NSImageSymbolConfiguration
                             configurationWithPointSize:10.0
                                                 weight:NSFontWeightMedium]];
      NSImage *tinted = [icon copy];
      [tinted lockFocus];
      [tint set];
      NSRect imgRect = NSMakeRect(0, 0, tinted.size.width, tinted.size.height);
      NSRectFillUsingOperation(imgRect, NSCompositingOperationSourceAtop);
      [tinted unlockFocus];

      CGFloat iconX = NSMidX(r) - tinted.size.width / 2.0;
      CGFloat iconY = NSMidY(r) - tinted.size.height / 2.0;
      [tinted drawAtPoint:NSMakePoint(iconX, iconY)
                 fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver
                 fraction:1.0];
    } else {
      NSDictionary *attrs = @{
        NSFontAttributeName : [self pillFont],
        NSForegroundColorAttributeName : tint,
      };
      NSSize textSize = [_labels[i] sizeWithAttributes:attrs];
      CGFloat textX = NSMidX(r) - textSize.width / 2.0;
      CGFloat textY = NSMidY(r) - textSize.height / 2.0;
      [_labels[i] drawAtPoint:NSMakePoint(textX, textY) withAttributes:attrs];
    }
  }
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  NSArray<NSValue *> *rects = [self pillRects];

  for (NSInteger i = 0; i < (NSInteger)rects.count; i++) {
    if (NSPointInRect(loc, rects[i].rectValue)) {
      BOOL newState = !_states[i].boolValue;
      [self setState:newState atIndex:i];
      if (_onToggled)
        _onToggled(i, newState);
      return;
    }
  }
}

@end
