/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../Style/NSColor+KKColors.h"
#import "../KKChevronView.h"
#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKStageSequencerView (RenderingLabels)

- (NSRect)_groupHeaderRectForRowY:(CGFloat)rowY {
  CGFloat totalWidth = NSWidth(self.bounds);
  return NSMakeRect(kKSSBorderInset, rowY,
                    MAX(0, totalWidth - 2 * kKSSBorderInset),
                    kKSSGroupHeaderHeight);
}

- (void)_renderGroupHeaderRow:(KKSequencerRow *)row
                         rowY:(CGFloat)rowY
                       trackX:(CGFloat)trackX
                   trackWidth:(CGFloat)trackWidth {
  NSRect rect = [self _groupHeaderRectForRowY:rowY];

  // Chevron — reuses KKChevronView's cached rotated images so the icon and
  // its 0→40→90 snap animation match the inspector group headers exactly.
  NSNumber *rotNum = _groupChevronRotation[row.groupKey];
  CGFloat rotation =
      rotNum ? rotNum.doubleValue : (row.groupCollapsed ? 0.0 : 90.0);
  NSImage *chevron =
      [KKChevronView chevronImageAtAngle:rotation
                                   color:[[NSColor inspectorLabel]
                                             colorWithAlphaComponent:0.75]];
  CGFloat chevLeft = NSMinX(rect) + KKPaddingSM;
  CGFloat chevCY = NSMidY(rect);
  NSRect chevRect = NSMakeRect(chevLeft, chevCY - chevron.size.height / 2.0,
                               chevron.size.width, chevron.size.height);
  [chevron drawInRect:chevRect];

  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName : [NSColor inspectorLabel],
  };
  NSString *label = row.groupLabel ?: @"";
  NSSize sz = [label sizeWithAttributes:attrs];
  NSPoint pt = NSMakePoint(chevLeft + chevron.size.width + KKPaddingSM + 2.0,
                           NSMidY(rect) - sz.height / 2.0);
  [label drawAtPoint:pt withAttributes:attrs];

  // Group span bar: union of all segment ranges across lanes in this group,
  // drawn as a single rounded "summary segment" on the track.
  if (trackWidth >= 1 && row.groupKey.length) {
    double minStart = 1.0, maxEnd = 0.0;
    BOOL any = NO;
    for (KKTimingLane *l in self.lanes) {
      if (![l.groupKey isEqualToString:row.groupKey])
        continue;
      for (KKTimingSegment *seg in l.segments) {
        if (seg.start < minStart)
          minStart = seg.start;
        if (seg.end > maxEnd)
          maxEnd = seg.end;
        any = YES;
      }
    }
    if (any && maxEnd > minStart) {
      CGFloat x0 = [self _xForFrac:minStart
                            trackX:trackX
                        trackWidth:trackWidth];
      CGFloat x1 = [self _xForFrac:maxEnd trackX:trackX trackWidth:trackWidth];
      CGFloat barH = NSHeight(rect) - 8.0;
      NSRect barRect =
          NSMakeRect(x0, NSMidY(rect) - barH / 2.0, MAX(2.0, x1 - x0), barH);
      NSBezierPath *bar =
          [NSBezierPath bezierPathWithRoundedRect:barRect
                                          xRadius:kKSSSegmentCornerRadius
                                          yRadius:kKSSSegmentCornerRadius];
      BOOL isSelected = self.selectedGroupKey.length > 0 &&
                        [self.selectedGroupKey isEqualToString:row.groupKey];
      NSColor *fill = isSelected ? [NSColor accentMatchingHost]
                                 : [NSColor colorWithWhite:1.0 alpha:0.10];
      [fill setFill];
      [bar fill];
    }
  }
}

- (void)_animateGroupChevronForKey:(NSString *)groupKey
                         collapsed:(BOOL)collapsed {
  if (groupKey.length == 0)
    return;
  if (!_groupChevronRotation)
    _groupChevronRotation = [NSMutableDictionary dictionary];
  if (!_groupChevronAnimToken)
    _groupChevronAnimToken = [NSMutableDictionary dictionary];
  NSUInteger token = _groupChevronAnimToken[groupKey].unsignedIntegerValue + 1;
  _groupChevronAnimToken[groupKey] = @(token);
  _groupChevronRotation[groupKey] = @(40.0);
  [self renderLanes];

  __weak typeof(self) weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self_ = weakSelf;
        if (!self_)
          return;
        if (self_->_groupChevronAnimToken[groupKey].unsignedIntegerValue !=
            token)
          return;
        self_->_groupChevronRotation[groupKey] = @(collapsed ? 0.0 : 90.0);
        [self_ renderLanes];
      });
}

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
  CGFloat labelRight = kKSSBorderInset + kKSSLabelWidth - kKSSLabelPadding;
  CGFloat labelWidth = MAX(0, labelRight - labelLeft);
  NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
  para.lineBreakMode = NSLineBreakByTruncatingHead;
  NSDictionary *labelAttrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightMedium],
    NSForegroundColorAttributeName : contentColor,
    NSParagraphStyleAttributeName : para,
  };
  NSSize labelSize = [lane.propertyLabel sizeWithAttributes:labelAttrs];
  NSRect labelRect =
      NSMakeRect(labelLeft, laneY + (laneH - labelSize.height) / 2.0,
                 labelWidth, labelSize.height);
  [lane.propertyLabel drawWithRect:labelRect
                           options:NSStringDrawingUsesLineFragmentOrigin
                        attributes:labelAttrs];
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
