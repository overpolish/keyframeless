/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKLaneVisibilityBar.h"
#import "../../Style/KKTokens.h"
#import "../../Style/NSColor+KKColors.h"

static const CGFloat kBarHeight = 22.0;
static const CGFloat kPillHeight = 18.0;
static const CGFloat kPillSpacing = 4.0;
static const CGFloat kPillPadX = 6.0;

@implementation KKLaneVisibilityBar

+ (CGFloat)preferredHeight {
  return kBarHeight;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    _labels = @[];
    _visibleStates = @[];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)setLabels:(NSArray<NSString *> *)labels {
  _labels = [labels copy];
  [self setNeedsDisplay:YES];
}

- (void)setVisibleStates:(NSArray<NSNumber *> *)visibleStates {
  _visibleStates = [visibleStates copy];
  [self setNeedsDisplay:YES];
}

- (NSFont *)pillFont {
  return [NSFont systemFontOfSize:8.0 weight:NSFontWeightMedium];
}

- (CGFloat)pillWidthForIndex:(NSInteger)i {
  if (i < 0 || (NSUInteger)i >= _labels.count)
    return 0;
  NSDictionary *attrs = @{NSFontAttributeName : [self pillFont]};
  CGFloat textW = [_labels[i] sizeWithAttributes:attrs].width;
  return textW + 2 * kPillPadX;
}

- (NSArray<NSValue *> *)pillRects {
  NSMutableArray<NSValue *> *rects =
      [NSMutableArray arrayWithCapacity:_labels.count];
  CGFloat x = 0;
  CGFloat y = (kBarHeight - kPillHeight) / 2.0;
  for (NSInteger i = 0; i < (NSInteger)_labels.count; i++) {
    CGFloat w = [self pillWidthForIndex:i];
    [rects addObject:[NSValue valueWithRect:NSMakeRect(x, y, w, kPillHeight)]];
    x += w + kPillSpacing;
  }
  return rects;
}

- (BOOL)_isSoloed:(NSInteger)i {
  if (i < 0 || (NSUInteger)i >= _visibleStates.count)
    return NO;
  if (!_visibleStates[i].boolValue)
    return NO;
  NSInteger onCount = 0;
  for (NSNumber *n in _visibleStates)
    if (n.boolValue)
      onCount++;
  return onCount == 1 && _labels.count > 1;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSArray<NSValue *> *rects = [self pillRects];
  for (NSInteger i = 0; i < (NSInteger)rects.count; i++) {
    NSRect r = rects[i].rectValue;
    BOOL on =
        (i < (NSInteger)_visibleStates.count) && _visibleStates[i].boolValue;
    BOOL solo = [self _isSoloed:i];

    NSColor *bgColor;
    NSColor *tint;
    if (solo) {
      bgColor = [[NSColor warning] colorWithAlphaComponent:0.18];
      tint = [NSColor warning];
    } else if (on) {
      bgColor = [[NSColor accentMatchingHost] colorWithAlphaComponent:0.15];
      tint = [NSColor accentMatchingHost];
    } else {
      bgColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.06];
      tint = [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
    }

    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:r
                                                       xRadius:KKRadiusMD
                                                       yRadius:KKRadiusMD];
    [bgColor setFill];
    [bg fill];

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

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  NSArray<NSValue *> *rects = [self pillRects];
  BOOL optDown = (event.modifierFlags & NSEventModifierFlagOption) != 0;
  for (NSInteger i = 0; i < (NSInteger)rects.count; i++) {
    if (NSPointInRect(loc, rects[i].rectValue)) {
      if (_onPillClicked)
        _onPillClicked(i, optDown);
      return;
    }
  }
}

@end
