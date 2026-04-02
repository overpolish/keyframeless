/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Math/KKEasing.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKSliderView.h"
#import "KKTimingGraphView_Private.h"
#import <AppKit/AppKit.h>

static const CGFloat kGraphHeight = 60.0;
static const CGFloat kLabelRowHeight = 20.0;
static const CGFloat kTickHeight = 16.0;
static const CGFloat kTickWidth = 22.0;
static const CGFloat kCurvePadding = KKPaddingLG;
static const NSInteger kCurveSegments = 40;
static const NSInteger kTickSegments = 16;
static const NSInteger kGridRows = 4;
static const CGFloat kCheckboxSize = 12.0;
static const NSInteger kIntensityTickCount = 5;
static const NSInteger kFrequencyTickCount = 5;

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
  if (self.midHoldEffect != KKHoldEffectNone) {
    for (NSInteger i = 0; i <= kCurveSegments; i++) {
      CGFloat t = (CGFloat)i / (CGFloat)kCurveSegments;
      CGFloat v = KKApplyHoldEffect(t, self.midHoldEffect, self.midIntensity,
                                    self.midFrequency, self.midSeed);
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
    case KKTimingGraphSectionMid:
      easedT = KKApplyHoldEffect(rawT, self.midHoldEffect, self.midIntensity,
                                 self.midFrequency, self.midSeed);
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
  NSString *labels[] = {@"In", @"Mid", @"Out"};

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

    if (s == KKTimingGraphSectionMid && !self.midSeedStack.hidden)
      continue;

    CGFloat labelX;
    if (s == KKTimingGraphSectionMid) {
      labelX = NSMidX(sRect) - labelSize.width / 2.0;
    } else {
      CGFloat groupWidth = labelSize.width + KKSpacingSM + kCheckboxSize;
      labelX = NSMidX(sRect) - groupWidth / 2.0;
    }
    [labels[s] drawAtPoint:NSMakePoint(labelX, labelY) withAttributes:attrs];
  }
}

- (void)renderTicksToImageView:(NSImageView *)imageView
                     tickCount:(NSInteger)tickCount
                   activeIndex:(NSInteger)activeIndex
                    valueBlock:
                        (CGFloat (^)(NSInteger tickIndex, CGFloat t))block {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat tickPad = kTickWidth / 2.0;
  CGFloat tickAreaWidth = NSWidth(self.bounds) - 2 * inset;
  if (tickAreaWidth < 1)
    return;

  NSImage *image =
      [[NSImage alloc] initWithSize:NSMakeSize(tickAreaWidth, kTickHeight)];
  [image lockFocus];

  CGFloat sliderWidth = tickAreaWidth - 2 * tickPad;
  CGFloat knobInset = 9.5 / 2.0;
  CGFloat usableWidth = sliderWidth - 2 * knobInset;

  for (NSInteger i = 0; i < tickCount; i++) {
    CGFloat frac =
        (tickCount > 1) ? (CGFloat)i / (CGFloat)(tickCount - 1) : 0.5;
    CGFloat centerX = tickPad + knobInset + frac * usableWidth;
    NSRect tickRect =
        NSMakeRect(centerX - kTickWidth / 2.0, 0, kTickWidth, kTickHeight);
    [self renderTickInRect:tickRect
                    active:(i == activeIndex)
                     value:^CGFloat(CGFloat t) {
                       return block(i, t);
                     }];
  }

  [image unlockFocus];
  imageView.image = image;
}

- (void)renderTicks {
  BOOL isMid = self.selectedSection == KKTimingGraphSectionMid;
  BOOL isOut = self.selectedSection == KKTimingGraphSectionOut;
  NSInteger tickCount = isMid ? KKHoldEffectCount : KKEasingCurveCount;
  NSInteger activeVal = lround(self.curveSlider.doubleValue);

  [self
      renderTicksToImageView:self.tickImageView
                   tickCount:tickCount
                 activeIndex:activeVal
                  valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                    if (isMid)
                      return KKApplyHoldEffect(t, (KKHoldEffect)idx,
                                               self.midIntensity,
                                               self.midFrequency, self.midSeed);
                    double inten = isOut ? self.outIntensity : self.inIntensity;
                    double freq = isOut ? self.outFrequency : self.inFrequency;
                    KKEasingCurve curve = (KKEasingCurve)idx;
                    return isOut ? KKApplyEasing(1.0 - t, curve, inten, freq)
                                 : KKApplyEasing(t, curve, inten, freq);
                  }];
}

- (void)renderIntensityTicks {
  BOOL isOut = self.selectedSection == KKTimingGraphSectionOut;
  BOOL isMid = self.selectedSection == KKTimingGraphSectionMid;
  double currentIntensity;
  if (isMid)
    currentIntensity = self.midIntensity;
  else if (isOut)
    currentIntensity = self.outIntensity;
  else
    currentIntensity = self.inIntensity;
  NSInteger nearest = lround(currentIntensity * (kIntensityTickCount - 1));

  if (isMid) {
    KKHoldEffect effect = self.midHoldEffect;
    [self renderTicksToImageView:self.intensityTickImageView
                       tickCount:kIntensityTickCount
                     activeIndex:nearest
                      valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                        double inten =
                            (double)idx / (double)(kIntensityTickCount - 1);
                        return KKApplyHoldEffect(
                            t, effect, inten, self.midFrequency, self.midSeed);
                      }];
  } else {
    KKEasingCurve curve = isOut ? self.outCurve : self.inCurve;
    [self renderTicksToImageView:self.intensityTickImageView
                       tickCount:kIntensityTickCount
                     activeIndex:nearest
                      valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                        double inten =
                            (double)idx / (double)(kIntensityTickCount - 1);
                        double freq =
                            isOut ? self.outFrequency : self.inFrequency;
                        return isOut
                                   ? KKApplyEasing(1.0 - t, curve, inten, freq)
                                   : KKApplyEasing(t, curve, inten, freq);
                      }];
  }
}

- (void)renderFrequencyTicks {
  BOOL isOut = self.selectedSection == KKTimingGraphSectionOut;
  BOOL isMid = self.selectedSection == KKTimingGraphSectionMid;
  double currentFrequency;
  if (isMid)
    currentFrequency = self.midFrequency;
  else if (isOut)
    currentFrequency = self.outFrequency;
  else
    currentFrequency = self.inFrequency;
  NSInteger nearest = lround(currentFrequency * (kFrequencyTickCount - 1));

  if (isMid) {
    KKHoldEffect effect = self.midHoldEffect;
    double inten = self.midIntensity;
    [self renderTicksToImageView:self.frequencyTickImageView
                       tickCount:kFrequencyTickCount
                     activeIndex:nearest
                      valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                        double freq =
                            (double)idx / (double)(kFrequencyTickCount - 1);
                        return KKApplyHoldEffect(t, effect, inten, freq,
                                                 self.midSeed);
                      }];
  } else {
    KKEasingCurve curve = isOut ? self.outCurve : self.inCurve;
    double inten = isOut ? self.outIntensity : self.inIntensity;
    [self renderTicksToImageView:self.frequencyTickImageView
                       tickCount:kFrequencyTickCount
                     activeIndex:nearest
                      valueBlock:^CGFloat(NSInteger idx, CGFloat t) {
                        double freq =
                            (double)idx / (double)(kFrequencyTickCount - 1);
                        return isOut
                                   ? KKApplyEasing(1.0 - t, curve, inten, freq)
                                   : KKApplyEasing(t, curve, inten, freq);
                      }];
  }
}

- (void)renderTickInRect:(NSRect)rect
                  active:(BOOL)active
                   value:(CGFloat (^)(CGFloat t))value {
  NSColor *color =
      active ? [NSColor accentMatchingHost]
             : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  [color setStroke];

  CGFloat pad = 2.0;
  CGFloat x0 = NSMinX(rect) + pad;
  CGFloat x1 = NSMaxX(rect) - pad;
  CGFloat yBot = NSMinY(rect) + pad;
  CGFloat yTop = NSMaxY(rect) - pad;
  CGFloat w = x1 - x0;

  CGFloat minVal = 0.0, maxVal = 1.0;
  for (NSInteger i = 0; i <= kTickSegments; i++) {
    CGFloat t = (CGFloat)i / (CGFloat)kTickSegments;
    CGFloat v = value(t);
    if (v < minVal)
      minVal = v;
    if (v > maxVal)
      maxVal = v;
  }
  CGFloat range = maxVal - minVal;
  CGFloat h = yTop - yBot;

  NSBezierPath *path = [NSBezierPath bezierPath];
  path.lineWidth = active ? 1.5 : 1.0;

  for (NSInteger i = 0; i <= kTickSegments; i++) {
    CGFloat t = (CGFloat)i / (CGFloat)kTickSegments;
    CGFloat v = value(t);
    CGFloat normalized = (range > 0) ? (v - minVal) / range : 0.5;
    CGFloat px = x0 + t * w;
    CGFloat py = yBot + normalized * h;

    if (i == 0)
      [path moveToPoint:NSMakePoint(px, py)];
    else
      [path lineToPoint:NSMakePoint(px, py)];
  }

  [path stroke];
}

@end
