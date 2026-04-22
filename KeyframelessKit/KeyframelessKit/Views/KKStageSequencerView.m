/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
@implementation KKStageSequencerView

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.wantsLayer = YES;
    self.layer.masksToBounds = YES;
    self.layer.cornerRadius = KKSpacingMD;
    self.layer.borderWidth = KKBorderWidthXS;
    self.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.05].CGColor;

    _zoom = 1.0;
    _panOffset = 0.0;

    _hoverLaneIdx = -1;
    _hoverSegIdx = -1;
    _hoverSegLaneIdx = -1;
    _hoverSegSegIdx = -1;

    NSTrackingArea *trackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                     NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:trackingArea];
  }
  return self;
}

#pragma mark - Public setters

- (void)setLanes:(NSArray<KKTimingLane *> *)lanes {
  _lanes = [lanes copy];
  if (!_dragging && !_dragMoving && !_dragLaneMoving)
    [self renderLanes];
}

- (void)setEffectDuration:(double)effectDuration {
  if (fabs(_effectDuration - effectDuration) < 0.001)
    return;
  _effectDuration = effectDuration;
  [self renderLanes];
}

- (void)setPlayheadFraction:(double)playheadFraction {
  if (fabs(_playheadFraction - playheadFraction) < 0.0001)
    return;
  _playheadFraction = playheadFraction;
  [self renderLanes];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self renderLanes];
}

#pragma mark - Coordinate helpers (shared with category files)

- (void)_trackGeometryForWidth:(CGFloat)viewWidth
                        trackX:(CGFloat *)outTrackX
                    trackWidth:(CGFloat *)outTrackWidth {
  *outTrackX = kKSSBorderInset + kKSSLabelWidth;
  *outTrackWidth =
      viewWidth - 2 * kKSSBorderInset - kKSSLabelWidth - kKSSLabelPadding;
}

- (CGFloat)_xForFrac:(double)frac
              trackX:(CGFloat)trackX
          trackWidth:(CGFloat)trackWidth {
  return trackX + (frac - _panOffset) * _zoom * trackWidth;
}

- (double)_fracForX:(CGFloat)x
             trackX:(CGFloat)trackX
         trackWidth:(CGFloat)trackWidth {
  return _panOffset + (x - trackX) / (_zoom * trackWidth);
}

- (void)_clampPanOffset {
  CGFloat visibleSpan = 1.0 / _zoom;
  _panOffset = MAX(0.0, MIN(1.0 - visibleSpan, _panOffset));
}

- (CGFloat)_laneYForIndex:(NSUInteger)laneIdx totalHeight:(CGFloat)totalHeight {
  return totalHeight - kKSSBorderInset - kKSSRulerHeight -
         (laneIdx + 1) * (kKSSLaneHeight + kKSSBoundaryLabelHeight) -
         laneIdx * kKSSLaneSpacing;
}

- (CGFloat)_totalHeight {
  return kKSSRulerHeight + kKSSBoundaryLabelHeight +
         _lanes.count * (kKSSLaneHeight + kKSSBoundaryLabelHeight) +
         (_lanes.count - 1) * kKSSLaneSpacing + 2 * kKSSBorderInset;
}

@end
#pragma clang diagnostic pop
