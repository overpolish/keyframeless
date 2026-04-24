/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Style/KKTokens.h"
#import "KKAlertView.h"
#import "KKCheckboxView.h"
#import "KKCurvePillView.h"
#import "KKSliderView.h"
#import "KKTimingGraphView_Private.h"
#import "KKTimingSlot.h"
#import <AppKit/AppKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKTimingGraphView (Layout)

- (NSRect)sectionRectForSection:(KKTimingGraphSection)section
                          width:(CGFloat)totalWidth {
  CGFloat sectionWidth = floor(totalWidth / 3.0);
  CGFloat x = (CGFloat)section * sectionWidth;
  if (section == KKTimingGraphSectionOut)
    sectionWidth = totalWidth - x;
  return NSMakeRect(x, 0, sectionWidth, kGraphHeight);
}

- (NSRect)graphRectForSection:(KKTimingGraphSection)section {
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat graphWidth = NSWidth(self.bounds) - 2 * inset;
  NSRect r = [self sectionRectForSection:section width:graphWidth];
  r.origin.x += inset;
  r.origin.y +=
      kTopPadding + kPillRowHeight + kDurationTickHeight + KKSpacingLG;
  return r;
}

- (void)_layoutSectionCheckboxesAtGraphTop:(CGFloat)graphTop {
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:9.0
                                            weight:NSFontWeightMedium],
  };
  CGFloat cbY =
      graphTop + kGraphHeight + (kLabelRowHeight - kCheckboxSize) / 2.0;

  NSSize inSize = [@"In" sizeWithAttributes:attrs];
  NSRect inRect = [self graphRectForSection:KKTimingGraphSectionIn];
  CGFloat inGroupX =
      NSMidX(inRect) - (inSize.width + KKSpacingSM + kCheckboxSize) / 2.0;
  _inCheckbox.frame = NSMakeRect(inGroupX + inSize.width + KKSpacingSM, cbY,
                                 kCheckboxSize, kCheckboxSize);

  NSSize outSize = [@"Out" sizeWithAttributes:attrs];
  NSRect outRect = [self graphRectForSection:KKTimingGraphSectionOut];
  CGFloat outGroupX =
      NSMidX(outRect) - (outSize.width + KKSpacingSM + kCheckboxSize) / 2.0;
  _outCheckbox.frame = NSMakeRect(outGroupX + outSize.width + KKSpacingSM, cbY,
                                  kCheckboxSize, kCheckboxSize);

  NSRect holdRect = [self graphRectForSection:KKTimingGraphSectionHold];
  CGFloat stackWidth = self.holdSeedStack.fittingSize.width;
  CGFloat stackHeight = self.holdSeedStack.fittingSize.height;
  CGFloat stackX = NSMidX(holdRect) - stackWidth / 2.0;
  CGFloat stackY =
      graphTop + kGraphHeight + (kLabelRowHeight - stackHeight) / 2.0;
  self.holdSeedStack.frame =
      NSMakeRect(stackX, stackY, stackWidth, stackHeight);
}

- (CGFloat)_layoutGlobalSlotsAtY:(CGFloat)slotsY viewWidth:(CGFloat)viewWidth {
  for (NSUInteger i = 0; i < self.globalSlots.count; i++) {
    NSView *v = _globalSlotViews[i];
    CGFloat h = self.globalSlots[i].height;
    v.frame = NSMakeRect(0, slotsY, viewWidth, h);
    slotsY += h + KKSpacingSM;
  }
  return slotsY;
}

- (CGFloat)_layoutHoldPropertyRowAtY:(CGFloat)slotsY
                           viewWidth:(CGFloat)viewWidth {
  if (!self.holdPropertyView)
    return slotsY;
  CGFloat inset = KKInspectorHorizontalInset;
  CGFloat hpH = self.holdPropertyViewHeight > 0 ? self.holdPropertyViewHeight
                                                : KKInspectorRowHeight;
  CGFloat rowH = MAX(hpH, 14.0);
  CGFloat holdY = slotsY - 4.0;
  CGFloat labelY = holdY + (rowH - 14.0) / 2.0;
  CGFloat viewY = holdY + (rowH - hpH) / 2.0;
  _holdPropertyLabel.frame = NSMakeRect(inset, labelY, viewWidth * 0.35, 14.0);
  self.holdPropertyView.frame =
      NSMakeRect(inset, viewY, viewWidth - inset * 2, hpH);
  _holdStaticAlert.frame = NSMakeRect(0, holdY, viewWidth, rowH);
  return holdY + rowH + KKSpacingSM;
}

- (NSArray<KKTimingSlot *> *)_sectionSlotsForCurrentSection {
  switch (self.selectedSection) {
  case KKTimingGraphSectionIn:
    return self.inSectionSlots;
  case KKTimingGraphSectionHold:
    return self.holdSectionSlots;
  case KKTimingGraphSectionOut:
    return self.outSectionSlots;
  }
}

- (void)layout {
  [super layout];

  CGFloat graphTop =
      kTopPadding + kPillRowHeight + kDurationTickHeight + KKSpacingLG;
  [self _layoutSectionCheckboxesAtGraphTop:graphTop];

  CGFloat viewWidth = NSWidth(self.bounds);
  CGFloat slotsY = graphTop + kGraphHeight + kLabelRowHeight +
                   kSliderRowHeight + kTickHeight + KKPaddingSM + 4.0;
  slotsY = [self _layoutGlobalSlotsAtY:slotsY viewWidth:viewWidth];
  slotsY = [self _layoutHoldPropertyRowAtY:slotsY viewWidth:viewWidth];

  NSArray<KKTimingSlot *> *sectionSlots = [self _sectionSlotsForCurrentSection];
  for (NSUInteger i = 0; i < sectionSlots.count; i++) {
    NSView *v = _sectionSlotViews[i];
    CGFloat h = sectionSlots[i].height;
    v.frame = NSMakeRect(0, slotsY, viewWidth, h);
    slotsY += h + KKSpacingSM;
  }

  [self updateControls];
  [self renderGraph];
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
}

#pragma mark - Hit testing

- (NSRect)durationTickHitRectForIndex:(NSInteger)index {
  NSRect sliderFrame = self.durationSlider.frame;
  CGFloat tickY = NSMaxY(self.curvePillView.frame);
  CGFloat tickAreaWidth = NSWidth(sliderFrame);
  CGFloat tickW = tickAreaWidth / kDurationTickCount;
  CGFloat frac = [self durationTickPosition:kDurationTickValues[index]];
  CGFloat centerX = NSMinX(sliderFrame) + frac * tickAreaWidth;
  return NSMakeRect(centerX - tickW / 2.0, tickY, tickW, kDurationTickHeight);
}

- (NSRect)_tickHitRectForIndex:(NSInteger)index
                     tickCount:(NSInteger)tickCount
                     imageView:(NSImageView *)imageView {
  NSRect frame = imageView.frame;
  CGFloat tickW = NSWidth(frame) / tickCount;
  CGFloat frac =
      (tickCount > 1) ? (CGFloat)index / (CGFloat)(tickCount - 1) : 0.5;
  CGFloat centerX = NSMinX(frame) + frac * NSWidth(frame);
  NSRect hitRect =
      NSMakeRect(centerX - tickW / 2.0, NSMinY(frame), tickW, NSHeight(frame));
  return NSIntersectionRect(hitRect, frame);
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (BOOL)_trySnapDurationToTickAtPoint:(NSPoint)loc {
  if (self.durationSlider.hidden)
    return NO;
  for (NSInteger i = 0; i < kDurationTickCount; i++) {
    if (NSPointInRect(loc, [self durationTickHitRectForIndex:i])) {
      self.durationSlider.doubleValue = kDurationTickValues[i];
      [self durationSliderChanged:self.durationSlider];
      return YES;
    }
  }
  return NO;
}

- (BOOL)_trySnapIntensityToTickAtPoint:(NSPoint)loc {
  if (self.intensityTickImageView.hidden)
    return NO;
  for (NSInteger i = 0; i < kIntensityTickCount; i++) {
    NSRect r = [self _tickHitRectForIndex:i
                                tickCount:kIntensityTickCount
                                imageView:self.intensityTickImageView];
    if (NSPointInRect(loc, r)) {
      double val = (double)i / (double)(kIntensityTickCount - 1);
      _intensitySlider.doubleValue = val;
      [self intensitySliderChanged:_intensitySlider];
      return YES;
    }
  }
  return NO;
}

- (BOOL)_trySnapFrequencyToTickAtPoint:(NSPoint)loc {
  if (self.frequencyTickImageView.hidden)
    return NO;
  for (NSInteger i = 0; i < kFrequencyTickCount; i++) {
    NSRect r = [self _tickHitRectForIndex:i
                                tickCount:kFrequencyTickCount
                                imageView:self.frequencyTickImageView];
    if (NSPointInRect(loc, r)) {
      double val = (double)i / (double)(kFrequencyTickCount - 1);
      _frequencySlider.doubleValue = val;
      [self frequencySliderChanged:_frequencySlider];
      return YES;
    }
  }
  return NO;
}

- (BOOL)_trySelectSectionAtPoint:(NSPoint)loc {
  for (KKTimingGraphSection s = KKTimingGraphSectionIn;
       s <= KKTimingGraphSectionOut; s++) {
    if (NSPointInRect(loc, [self graphRectForSection:s])) {
      if (self.onSectionSelected)
        self.onSectionSelected(s);
      return YES;
    }
  }
  return NO;
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  if ([self _trySnapDurationToTickAtPoint:loc])
    return;
  if ([self _trySnapIntensityToTickAtPoint:loc])
    return;
  if ([self _trySnapFrequencyToTickAtPoint:loc])
    return;
  [self _trySelectSectionAtPoint:loc];
}

@end
#pragma clang diagnostic pop
