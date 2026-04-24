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
@implementation KKTimingGraphView (TickRendering)

- (CGFloat)durationTickPosition:(double)value {
  double lo = self.durationSlider.minValue;
  double bp = self.durationSlider.scaleBreakPosition;
  double bv = self.durationSlider.scaleBreakValue;
  double hi = self.durationSlider.maxValue;
  if (bv > 0 && bp > 0) {
    if (value <= bv)
      return bp * (value - lo) / (bv - lo);
    return bp + (1.0 - bp) * (value - bv) / (hi - bv);
  }
  return (value - lo) / (hi - lo);
}

- (void)renderDurationTicks {
  CGFloat tickAreaWidth = NSWidth(self.durationTickImageView.bounds);
  if (tickAreaWidth < 1)
    return;

  double currentVal = self.durationSlider.doubleValue;
  CGFloat currentFrac = [self durationTickPosition:currentVal];
  CGFloat currentCenterX = currentFrac * tickAreaWidth;

  static const NSInteger count = 4;
  double values[] = {0.0, 1.0, 2.0, 10.0};
  NSString *labels[4] = {@"0s", @"1.0s", @"2.0s", @"10s"};

  NSDictionary *dimAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:8.0
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName :
        [[NSColor inspectorLabel] colorWithAlphaComponent:0.35],
  };
  NSDictionary *activeAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:8.0
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName : [NSColor accentMatchingHost],
  };

  NSString *currentLabel = [NSString stringWithFormat:@"%.1fs", currentVal];
  NSSize currentLabelSize = [currentLabel sizeWithAttributes:activeAttrs];
  static const CGFloat kHideThreshold = 6.0;

  NSImage *image = [[NSImage alloc]
      initWithSize:NSMakeSize(tickAreaWidth, kDurationTickHeight)];
  [image lockFocus];

  CGFloat curLabelX = currentCenterX - currentLabelSize.width / 2.0;
  curLabelX = MAX(0, MIN(curLabelX, tickAreaWidth - currentLabelSize.width));
  CGFloat curLabelRight = curLabelX + currentLabelSize.width;

  for (NSInteger i = 0; i < count; i++) {
    CGFloat frac = [self durationTickPosition:values[i]];
    CGFloat centerX = frac * tickAreaWidth;

    NSSize labelSize = [labels[i] sizeWithAttributes:dimAttrs];
    CGFloat labelX = centerX - labelSize.width / 2.0;
    labelX = MAX(0, MIN(labelX, tickAreaWidth - labelSize.width));
    CGFloat labelRight = labelX + labelSize.width;

    BOOL overlaps = labelX < curLabelRight + kHideThreshold &&
                    labelRight > curLabelX - kHideThreshold;
    if (overlaps)
      continue;

    CGFloat labelY = (kDurationTickHeight - labelSize.height) / 2.0;
    [labels[i] drawAtPoint:NSMakePoint(labelX, labelY) withAttributes:dimAttrs];
  }
  CGFloat curLabelY = (kDurationTickHeight - currentLabelSize.height) / 2.0;
  [currentLabel drawAtPoint:NSMakePoint(curLabelX, curLabelY)
             withAttributes:activeAttrs];

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
#pragma clang diagnostic pop
