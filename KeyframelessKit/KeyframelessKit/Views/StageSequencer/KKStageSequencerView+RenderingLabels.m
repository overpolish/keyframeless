/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../../Style/NSColor+KKColors.h"
#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKStageSequencerView (RenderingLabels)

- (void)_renderLaneLabel:(KKTimingLane *)lane laneY:(CGFloat)laneY {
  NSColor *contentColor =
      lane.enabled ? [NSColor inspectorLabel]
                   : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  CGFloat laneH = [self _laneHeight];
  CGFloat iconSlotLeft = kKSSBorderInset + kKSSLabelPadding;

  if (lane.hasOSC) {
    NSString *name = lane.oscVisible ? @"arcade.stick.console.fill"
                                     : @"arcade.stick.console";
    NSImage *symbol = [NSImage imageWithSystemSymbolName:name
                                accessibilityDescription:nil];
    if (symbol) {
      NSImageSymbolConfiguration *sizeCfg = [NSImageSymbolConfiguration
          configurationWithPointSize:kKSSOSCIconSize
                              weight:NSFontWeightRegular];
      NSImageSymbolConfiguration *colorCfg = [NSImageSymbolConfiguration
          configurationWithPaletteColors:@[ contentColor ]];
      NSImage *icon =
          [symbol imageWithSymbolConfiguration:
                      [sizeCfg configurationByApplyingConfiguration:colorCfg]];
      NSRect iconRect =
          NSMakeRect(iconSlotLeft + (kKSSOSCIconSize - icon.size.width) / 2.0,
                     laneY + (laneH - icon.size.height) / 2.0, icon.size.width,
                     icon.size.height);
      [icon drawInRect:iconRect];
    }
  }

  CGFloat labelLeft = iconSlotLeft + kKSSOSCIconSize + kKSSOSCIconGap;
  NSDictionary *labelAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName : contentColor,
  };
  NSSize labelSize = [lane.propertyLabel sizeWithAttributes:labelAttrs];
  NSPoint labelPoint =
      NSMakePoint(labelLeft, laneY + (laneH - labelSize.height) / 2.0);
  [lane.propertyLabel drawAtPoint:labelPoint withAttributes:labelAttrs];
}

static NSString *_boundaryTimeLabel(double fraction, double duration) {
  double sec = fraction * duration;
  if (sec < 0.01)
    return @"0s";
  if (sec < 10.0)
    return [NSString stringWithFormat:@"%.1fs", sec];
  int totalSec = (int)sec;
  int m = totalSec / 60;
  int s = totalSec % 60;
  if (m > 0)
    return [NSString stringWithFormat:@"%d:%02d", m, s];
  return [NSString stringWithFormat:@"%ds", s];
}

- (void)_renderBoundaryLabelsForLane:(KKTimingLane *)lane
                           laneIndex:(NSUInteger)laneIdx
                              trackX:(CGFloat)trackX
                          trackWidth:(CGFloat)trackWidth
                               laneY:(CGFloat)laneY {
  if (self.effectDuration <= 0)
    return;

  CGFloat labelRowY = laneY - kKSSBoundaryLabelHeight;

  NSDictionary *dimAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:8.0
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName :
        [[NSColor inspectorLabel] colorWithAlphaComponent:0.35],
  };

  CGFloat durLabelLeft = -999, durLabelRight = -999;
  BOOL isHovered =
      (_hoverSegLaneIdx == (NSInteger)laneIdx && _hoverSegSegIdx >= 0 &&
       (NSUInteger)_hoverSegSegIdx < lane.segments.count);
  NSString *durLabel = nil;
  NSDictionary *durAttrs = nil;
  CGFloat durX = 0, durY = 0;

  if (isHovered) {
    KKTimingSegment *hSeg = lane.segments[_hoverSegSegIdx];
    double durSec = (hSeg.end - hSeg.start) * self.effectDuration;
    if (durSec < 10.0)
      durLabel = [NSString stringWithFormat:@"%.1fs", durSec];
    else
      durLabel = [NSString stringWithFormat:@"%.0fs", durSec];

    durAttrs = @{
      NSFontAttributeName : [NSFont systemFontOfSize:8.0
                                              weight:NSFontWeightMedium],
      NSForegroundColorAttributeName : (hSeg.type == KKSegmentTypeHold)
          ? [NSColor accentMatchingHost]
          : [NSColor warning],
    };
    NSSize durSize = [durLabel sizeWithAttributes:durAttrs];
    CGFloat segMidX = [self _xForFrac:(hSeg.start + hSeg.end) / 2.0
                               trackX:trackX
                           trackWidth:trackWidth];
    durX = segMidX - durSize.width / 2.0;
    durX = MAX(trackX, MIN(trackX + trackWidth - durSize.width, durX));
    durY = labelRowY + (kKSSBoundaryLabelHeight - durSize.height) / 2.0;
    durLabelLeft = durX;
    durLabelRight = durX + durSize.width;
  }

  NSMutableArray<NSNumber *> *boundaries = [NSMutableArray array];
  for (KKTimingSegment *seg in lane.segments) {
    [boundaries addObject:@(seg.start)];
  }
  KKTimingSegment *last = lane.segments.lastObject;
  if (last)
    [boundaries addObject:@(last.end)];

  CGFloat lastLabelRight = -999;
  static const CGFloat kLabelGap = 4.0;

  for (NSNumber *bNum in boundaries) {
    double frac = bNum.doubleValue;
    CGFloat bx = [self _xForFrac:frac trackX:trackX trackWidth:trackWidth];
    if (bx < trackX - 0.5 || bx > trackX + trackWidth + 0.5)
      continue;
    NSString *label = _boundaryTimeLabel(frac, self.effectDuration);
    NSSize labelSize = [label sizeWithAttributes:dimAttrs];
    CGFloat labelX = bx - labelSize.width / 2.0;
    labelX = MAX(trackX, MIN(trackX + trackWidth - labelSize.width, labelX));

    if (labelX < lastLabelRight + kLabelGap)
      continue;

    if (isHovered && labelX + labelSize.width + kLabelGap > durLabelLeft &&
        labelX < durLabelRight + kLabelGap)
      continue;

    CGFloat labelY =
        labelRowY + (kKSSBoundaryLabelHeight - labelSize.height) / 2.0;
    [label drawAtPoint:NSMakePoint(labelX, labelY) withAttributes:dimAttrs];
    lastLabelRight = labelX + labelSize.width;
  }

  if (isHovered && durLabel)
    [durLabel drawAtPoint:NSMakePoint(durX, durY) withAttributes:durAttrs];
}

@end
#pragma clang diagnostic pop
