/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Math/KKEasing.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKCurvePillView.h"
#import "KKSliderView.h"
#import "KKTimingGraphView_Private.h"
#import <AppKit/AppKit.h>

static const CGFloat kCurvePadding = KKPaddingLG;
static const NSInteger kCurveSegments = 100;
static const NSInteger kGridRows = 4;
static const double kTickEpsilon = 0.01;

static NSInteger KKExactTickIndex(double value, NSInteger tickCount) {
  for (NSInteger i = 0; i < tickCount; i++) {
    double tickVal = (double)i / (double)(tickCount - 1);
    if (fabs(value - tickVal) < kTickEpsilon)
      return i;
  }
  return -1;
}

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

- (void)renderDurationTicks {
  static NSString *const labels[] = {@"0s", @"1.0s", @"2.0s"};
  static const double values[] = {0.0, 1.0, 2.0};
  static const NSInteger count = 3;

  CGFloat tickAreaWidth = NSWidth(self.durationTickImageView.bounds);
  if (tickAreaWidth < 1)
    return;

  NSImage *image = [[NSImage alloc]
      initWithSize:NSMakeSize(tickAreaWidth, kDurationTickHeight)];
  [image lockFocus];

  double currentVal = self.durationSlider.doubleValue;
  NSInteger exact = -1;
  for (NSInteger i = 0; i < count; i++) {
    if (fabs(currentVal - values[i]) < kTickEpsilon) {
      exact = i;
      break;
    }
  }

  for (NSInteger i = 0; i < count; i++) {
    CGFloat frac = (CGFloat)i / (CGFloat)(count - 1);
    CGFloat centerX = frac * tickAreaWidth;
    BOOL active = (i == exact);

    NSDictionary *attrs = @{
      NSFontAttributeName : [NSFont systemFontOfSize:8.0
                                              weight:NSFontWeightMedium],
      NSForegroundColorAttributeName : active
          ? [NSColor accentMatchingHost]
          : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35],
    };
    NSSize labelSize = [labels[i] sizeWithAttributes:attrs];
    CGFloat labelX = centerX - labelSize.width / 2.0;
    labelX = MAX(0, MIN(labelX, tickAreaWidth - labelSize.width));
    CGFloat labelY = (kDurationTickHeight - labelSize.height) / 2.0;
    [labels[i] drawAtPoint:NSMakePoint(labelX, labelY) withAttributes:attrs];
  }

  [image unlockFocus];
  self.durationTickImageView.image = image;
}

- (void)renderHalfWidthTicksToImageView:(NSImageView *)imageView
                              tickCount:(NSInteger)tickCount
                            activeIndex:(NSInteger)activeIndex
                            activeColor:(NSColor *)activeColor
                             valueBlock:(CGFloat (^)(NSInteger tickIndex,
                                                     CGFloat t))block {
  CGFloat tickAreaWidth = NSWidth(imageView.bounds);
  if (tickAreaWidth < 1)
    return;

  static const CGFloat kHalfTickWidth = 18.0;
  static const NSInteger kTickSegments = 60;

  NSImage *image =
      [[NSImage alloc] initWithSize:NSMakeSize(tickAreaWidth, kTickHeight)];
  [image lockFocus];

  CGFloat tickPad = kHalfTickWidth / 2.0;
  CGFloat usableWidth = tickAreaWidth - 2 * tickPad;

  for (NSInteger i = 0; i < tickCount; i++) {
    CGFloat frac =
        (tickCount > 1) ? (CGFloat)i / (CGFloat)(tickCount - 1) : 0.5;
    CGFloat centerX = tickPad + frac * usableWidth;
    NSRect tickRect = NSMakeRect(centerX - kHalfTickWidth / 2.0, 0,
                                 kHalfTickWidth, kTickHeight);
    BOOL active = (i == activeIndex);

    NSColor *color =
        active ? activeColor
               : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
    [color setStroke];

    CGFloat pad = 2.0;
    CGFloat x0 = NSMinX(tickRect) + pad;
    CGFloat x1 = NSMaxX(tickRect) - pad;
    CGFloat yBot = NSMinY(tickRect) + pad;
    CGFloat yTop = NSMaxY(tickRect) - pad;
    CGFloat w = x1 - x0;
    CGFloat h = yTop - yBot;

    CGFloat minVal = 0.0, maxVal = 1.0;
    for (NSInteger j = 0; j <= kTickSegments; j++) {
      CGFloat t = (CGFloat)j / (CGFloat)kTickSegments;
      CGFloat v = block(i, t);
      if (v < minVal)
        minVal = v;
      if (v > maxVal)
        maxVal = v;
    }
    CGFloat range = maxVal - minVal;

    NSBezierPath *path = [NSBezierPath bezierPath];
    path.lineWidth = active ? 1.5 : 1.0;

    for (NSInteger j = 0; j <= kTickSegments; j++) {
      CGFloat t = (CGFloat)j / (CGFloat)kTickSegments;
      CGFloat v = block(i, t);
      CGFloat normalized = (range > 0) ? (v - minVal) / range : 0.5;
      CGFloat px = x0 + t * w;
      CGFloat py = yBot + normalized * h;

      if (j == 0)
        [path moveToPoint:NSMakePoint(px, py)];
      else
        [path lineToPoint:NSMakePoint(px, py)];
    }

    [path stroke];
  }

  [image unlockFocus];
  imageView.image = image;
}

- (void)renderIntensityTicks {
  BOOL isOut = self.selectedSection == KKTimingGraphSectionOut;
  BOOL isHold = self.selectedSection == KKTimingGraphSectionHold;
  double currentIntensity;
  if (isHold)
    currentIntensity = self.holdIntensity;
  else if (isOut)
    currentIntensity = self.outIntensity;
  else
    currentIntensity = self.inIntensity;
  NSInteger exact = KKExactTickIndex(currentIntensity, kIntensityTickCount);

  if (isHold) {
    KKHoldEffect effect = self.holdEffect;
    [self renderHalfWidthTicksToImageView:self.intensityTickImageView
                                tickCount:kIntensityTickCount
                              activeIndex:exact
                              activeColor:[NSColor accentMatchingHost]
                               valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                                 double inten =
                                     (double)idx /
                                     (double)(kIntensityTickCount - 1);
                                 return KKApplyHoldEffect(t, effect, inten,
                                                          self.holdFrequency,
                                                          self.holdSeed);
                               }];
  } else {
    KKEasingCurve curve = isOut ? self.outCurve : self.inCurve;
    [self renderHalfWidthTicksToImageView:self.intensityTickImageView
                                tickCount:kIntensityTickCount
                              activeIndex:exact
                              activeColor:[NSColor accentMatchingHost]
                               valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                                 double inten =
                                     (double)idx /
                                     (double)(kIntensityTickCount - 1);
                                 double freq = isOut ? self.outFrequency
                                                     : self.inFrequency;
                                 return isOut ? KKApplyEasing(1.0 - t, curve,
                                                              inten, freq)
                                              : KKApplyEasing(t, curve, inten,
                                                              freq);
                               }];
  }
}

- (void)renderFrequencyTicks {
  BOOL isOut = self.selectedSection == KKTimingGraphSectionOut;
  BOOL isHold = self.selectedSection == KKTimingGraphSectionHold;
  double currentFrequency;
  if (isHold)
    currentFrequency = self.holdFrequency;
  else if (isOut)
    currentFrequency = self.outFrequency;
  else
    currentFrequency = self.inFrequency;
  NSInteger exact = KKExactTickIndex(currentFrequency, kFrequencyTickCount);

  if (isHold) {
    KKHoldEffect effect = self.holdEffect;
    double inten = self.holdIntensity;
    [self renderHalfWidthTicksToImageView:self.frequencyTickImageView
                                tickCount:kFrequencyTickCount
                              activeIndex:exact
                              activeColor:[NSColor warning]
                               valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                                 double freq =
                                     (double)idx /
                                     (double)(kFrequencyTickCount - 1);
                                 return KKApplyHoldEffect(t, effect, inten,
                                                          freq, self.holdSeed);
                               }];
  } else {
    KKEasingCurve curve = isOut ? self.outCurve : self.inCurve;
    double inten = isOut ? self.outIntensity : self.inIntensity;
    [self renderHalfWidthTicksToImageView:self.frequencyTickImageView
                                tickCount:kFrequencyTickCount
                              activeIndex:exact
                              activeColor:[NSColor warning]
                               valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                                 double freq =
                                     (double)idx /
                                     (double)(kFrequencyTickCount - 1);
                                 return isOut ? KKApplyEasing(1.0 - t, curve,
                                                              inten, freq)
                                              : KKApplyEasing(t, curve, inten,
                                                              freq);
                               }];
  }
}

@end
