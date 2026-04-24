/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Math/KKEasing.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKCurvePillView.h"
#import "KKTimingGraphView_Private.h"
#import <AppKit/AppKit.h>

static const CGFloat kCurvePadding = KKPaddingLG;
static const NSInteger kCurveSegments = 100;
static const NSInteger kGridRows = 4;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKTimingGraphView (Rendering)

- (void)renderGraph {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat graphWidth = NSWidth(self.bounds) - 2 * inset;
  if (graphWidth < 1)
    return;

  CGFloat totalHeight = kGraphHeight + kLabelRowHeight;
  NSImage *image =
      [[NSImage alloc] initWithSize:NSMakeSize(graphWidth, totalHeight)];
  [image lockFocus];

  [[NSColor inspectorBackground] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, kLabelRowHeight,
                                                      graphWidth, kGraphHeight)
                                   xRadius:KKRadiusMD
                                   yRadius:KKRadiusMD] fill];

  NSAffineTransform *xform = [NSAffineTransform transform];
  [xform translateXBy:0 yBy:kLabelRowHeight];
  [xform concat];

  [self renderGridWithWidth:graphWidth];

  for (KKTimingGraphSection s = KKTimingGraphSectionIn;
       s <= KKTimingGraphSectionOut; s++) {
    [self renderSection:s width:graphWidth];
  }

  NSAffineTransform *reset = [NSAffineTransform transform];
  [reset translateXBy:0 yBy:-kLabelRowHeight];
  [reset concat];

  [self renderLabelsWithWidth:graphWidth];

  [image unlockFocus];
  self.graphImageView.image = image;
}

- (void)renderGridWithWidth:(CGFloat)totalWidth {
  NSColor *gridColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.08];
  [gridColor setStroke];

  NSBezierPath *grid = [NSBezierPath bezierPath];
  grid.lineWidth = 0.5;

  CGFloat drawHeight = kGraphHeight - 2 * kCurvePadding;
  CGFloat drawWidth = totalWidth - 2 * kCurvePadding;
  CGFloat cellSize = drawHeight / (CGFloat)kGridRows;
  NSInteger cols = (NSInteger)floor(drawWidth / cellSize);
  CGFloat right = kCurvePadding + drawWidth;

  for (NSInteger i = 0; i <= kGridRows; i++) {
    CGFloat y = kCurvePadding + i * cellSize;
    [grid moveToPoint:NSMakePoint(kCurvePadding, y)];
    [grid lineToPoint:NSMakePoint(right, y)];
  }

  for (NSInteger i = 0; i <= cols; i++) {
    CGFloat x = kCurvePadding + i * cellSize;
    if (x > right)
      break;
    [grid moveToPoint:NSMakePoint(x, kCurvePadding)];
    [grid lineToPoint:NSMakePoint(x, kCurvePadding + drawHeight)];
  }

  [grid stroke];
}

- (void)globalCurveRangeMin:(CGFloat *)outMin max:(CGFloat *)outMax {
  CGFloat minVal = 0.0, maxVal = 1.0;
  KKEasingCurve curves[] = {self.inCurve, self.outCurve};
  BOOL enabled[] = {self.inEnabled, self.outEnabled};
  for (int c = 0; c < 2; c++) {
    if (!enabled[c])
      continue;
    for (NSInteger i = 0; i <= kCurveSegments; i++) {
      CGFloat t = (CGFloat)i / (CGFloat)kCurveSegments;
      double inten = (c == 0) ? self.inIntensity : self.outIntensity;
      double freq = (c == 0) ? self.inFrequency : self.outFrequency;
      CGFloat v = (c == 1) ? KKApplyEasing(1.0 - t, curves[c], inten, freq)
                           : KKApplyEasing(t, curves[c], inten, freq);
      if (v < minVal)
        minVal = v;
      if (v > maxVal)
        maxVal = v;
    }
  }
  if (self.holdEffect != KKHoldEffectNone) {
    for (NSInteger i = 0; i <= kCurveSegments; i++) {
      CGFloat t = (CGFloat)i / (CGFloat)kCurveSegments;
      CGFloat v = KKApplyHoldEffect(t, self.holdEffect, self.holdIntensity,
                                    self.holdFrequency, self.holdSeed);
      if (v < minVal)
        minVal = v;
      if (v > maxVal)
        maxVal = v;
    }
  }
  *outMin = minVal;
  *outMax = maxVal;
}

- (void)renderSection:(KKTimingGraphSection)section width:(CGFloat)totalWidth {
  NSRect rect = [self sectionRectForSection:section width:totalWidth];
  BOOL selected = (section == self.selectedSection);

  if (selected) {
    NSColor *selColor =
        [[NSColor accentMatchingHost] colorWithAlphaComponent:0.1];
    [selColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect
                                     xRadius:KKRadiusMD
                                     yRadius:KKRadiusMD] fill];
  }

  BOOL enabled;
  switch (section) {
  case KKTimingGraphSectionIn:
    enabled = self.inEnabled;
    break;
  case KKTimingGraphSectionOut:
    enabled = self.outEnabled;
    break;
  default:
    enabled = YES;
    break;
  }

  NSColor *curveColor =
      enabled ? [NSColor accentMatchingHost]
              : [[NSColor inspectorLabel] colorWithAlphaComponent:0.3];
  [curveColor setStroke];

  NSBezierPath *curve = [NSBezierPath bezierPath];
  curve.lineWidth = enabled ? 2.0 : 1.0;

  if (!enabled) {
    CGFloat pattern[] = {4.0, 3.0};
    [curve setLineDash:pattern count:2 phase:0];
  }

  CGFloat curveLeft = NSMinX(rect);
  CGFloat curveRight = NSMaxX(rect);
  if (section == KKTimingGraphSectionIn)
    curveLeft = kCurvePadding;
  if (section == KKTimingGraphSectionOut)
    curveRight = totalWidth - kCurvePadding;
  CGFloat x0 = curveLeft;
  CGFloat w = curveRight - curveLeft;
  CGFloat yBottom = kCurvePadding;
  CGFloat yTop = kGraphHeight - kCurvePadding;

  CGFloat minVal = 0.0, maxVal = 1.0;
  [self globalCurveRangeMin:&minVal max:&maxVal];
  CGFloat range = maxVal - minVal;

  for (NSInteger i = 0; i <= kCurveSegments; i++) {
    CGFloat rawT = (CGFloat)i / (CGFloat)kCurveSegments;
    CGFloat easedT;

    switch (section) {
    case KKTimingGraphSectionIn:
      easedT = enabled ? KKApplyEasing(rawT, self.inCurve, self.inIntensity,
                                       self.inFrequency)
                       : 1.0;
      break;
    case KKTimingGraphSectionHold:
      easedT = KKApplyHoldEffect(rawT, self.holdEffect, self.holdIntensity,
                                 self.holdFrequency, self.holdSeed);
      break;
    case KKTimingGraphSectionOut:
      easedT = enabled ? KKApplyEasing(1.0 - rawT, self.outCurve,
                                       self.outIntensity, self.outFrequency)
                       : 1.0;
      break;
    }

    CGFloat normalized = (range > 0) ? (easedT - minVal) / range : easedT;
    CGFloat px = x0 + rawT * w;
    CGFloat py = yBottom + normalized * (yTop - yBottom);

    if (i == 0)
      [curve moveToPoint:NSMakePoint(px, py)];
    else
      [curve lineToPoint:NSMakePoint(px, py)];
  }

  [curve stroke];
}

- (void)renderLabelsWithWidth:(CGFloat)totalWidth {
  NSString *labels[] = {@"In", @"Hold", @"Out"};

  for (KKTimingGraphSection s = KKTimingGraphSectionIn;
       s <= KKTimingGraphSectionOut; s++) {
    NSRect sRect = [self sectionRectForSection:s width:totalWidth];
    BOOL selected = (s == self.selectedSection);

    NSDictionary *attrs = @{
      NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                              weight:NSFontWeightMedium],
      NSForegroundColorAttributeName : selected
          ? [NSColor inspectorLabel]
          : [[NSColor inspectorLabel] colorWithAlphaComponent:0.5],
    };
    NSSize labelSize = [labels[s] sizeWithAttributes:attrs];
    CGFloat labelY = (kLabelRowHeight - labelSize.height) / 2.0;

    if (s == KKTimingGraphSectionHold && !self.holdSeedStack.hidden)
      continue;

    CGFloat labelX;
    if (s == KKTimingGraphSectionHold) {
      labelX = NSMidX(sRect) - labelSize.width / 2.0;
    } else {
      CGFloat groupWidth = labelSize.width + KKSpacingSM + kCheckboxSize;
      labelX = NSMidX(sRect) - groupWidth / 2.0;
    }
    [labels[s] drawAtPoint:NSMakePoint(labelX, labelY) withAttributes:attrs];
  }
}

- (void)renderCurvePills {
  BOOL isHold = self.selectedSection == KKTimingGraphSectionHold;
  BOOL isOut = self.selectedSection == KKTimingGraphSectionOut;

  __weak typeof(self) weakSelf = self;
  self.curvePillView.valueBlock = ^CGFloat(NSInteger idx, CGFloat t) {
    __strong typeof(weakSelf) s = weakSelf;
    if (!s)
      return t;
    if (isHold)
      return KKApplyHoldEffect(t, (KKHoldEffect)idx, s.holdIntensity,
                               s.holdFrequency, s.holdSeed);
    double inten = isOut ? s.outIntensity : s.inIntensity;
    double freq = isOut ? s.outFrequency : s.inFrequency;
    KKEasingCurve curve = (KKEasingCurve)idx;
    return isOut ? KKApplyEasing(1.0 - t, curve, inten, freq)
                 : KKApplyEasing(t, curve, inten, freq);
  };
  [self.curvePillView redraw];
}

@end
