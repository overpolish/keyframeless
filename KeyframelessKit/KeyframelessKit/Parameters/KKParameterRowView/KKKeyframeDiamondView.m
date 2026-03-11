/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKKeyframeDiamondView.h"
#import "NSColor+KKColors.h"

@implementation KKKeyframeDiamondView

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];

  CGFloat diamondSize = 10;
  CGFloat rightMargin = 2.0;
  CGFloat bottomOffset = 0.5;
  CGFloat x = self.bounds.size.width - rightMargin - diamondSize;
  CGFloat y = (self.bounds.size.height - diamondSize) / 2;
  CGFloat halfSize = diamondSize / 2;

  NSBezierPath *diamond = [self diamondPathWithSize:diamondSize];
  NSBezierPath *symbol = [self symbolPathWithSize:diamondSize];

  NSAffineTransform *transform = [NSAffineTransform transform];
  [transform translateXBy:x yBy:y + halfSize + bottomOffset];
  [diamond transformUsingAffineTransform:transform];
  [symbol transformUsingAffineTransform:transform];

  if (_keyframeExists) {
    [self drawFilledDiamond:diamond withSymbolCutout:symbol];
  } else {
    [self drawStrokedDiamond:diamond withSymbol:symbol];
  }
}

- (NSBezierPath *)diamondPathWithSize:(CGFloat)size {
  NSBezierPath *diamond = [NSBezierPath bezierPath];
  CGFloat halfSize = size / 2;

  // Origin at (0, 0), drawing from left to right for positioning
  [diamond moveToPoint:NSMakePoint(0, 0)];
  [diamond lineToPoint:NSMakePoint(halfSize, halfSize)];
  [diamond lineToPoint:NSMakePoint(size, 0)];
  [diamond lineToPoint:NSMakePoint(halfSize, -halfSize)];
  [diamond closePath];

  return diamond;
}

- (NSBezierPath *)symbolPathWithSize:(CGFloat)diamondSize {
  NSBezierPath *symbol = [NSBezierPath bezierPath];
  CGFloat halfSize = diamondSize / 2;
  CGFloat symbolSize = 2.5;

  if (_keyframeExists) {
    // Dash: remove/update keyframe
    [symbol moveToPoint:NSMakePoint(halfSize - symbolSize, 0)];
    [symbol lineToPoint:NSMakePoint(halfSize + symbolSize, 0)];
  } else {
    // Plus: add keyframe
    [symbol moveToPoint:NSMakePoint(halfSize, -symbolSize)];
    [symbol lineToPoint:NSMakePoint(halfSize, symbolSize)];
    [symbol moveToPoint:NSMakePoint(halfSize - symbolSize, 0)];
    [symbol lineToPoint:NSMakePoint(halfSize + symbolSize, 0)];
  }

  return symbol;
}

- (void)drawStrokedDiamond:(NSBezierPath *)diamond
                withSymbol:(NSBezierPath *)symbol {
  [[NSColor inspectorLabel] set];
  [diamond setLineWidth:1.0];
  [diamond stroke];
  [symbol setLineWidth:1.0];
  [symbol stroke];
}

- (void)drawFilledDiamond:(NSBezierPath *)diamond
         withSymbolCutout:(NSBezierPath *)symbol {
  [[NSColor inspectorLabel] set];
  [diamond fill];
  [diamond setLineWidth:1.0];
  [diamond stroke];

  [[NSColor inspectorBackground] set];
  [symbol setLineWidth:1.0];
  [symbol stroke];
}

@end
