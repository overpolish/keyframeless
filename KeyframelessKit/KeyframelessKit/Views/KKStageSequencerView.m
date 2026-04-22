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

- (CGFloat)zoom {
  return _zoom;
}

- (void)setZoom:(CGFloat)zoom {
  if (fabs(_zoom - zoom) < 0.0001)
    return;
  _zoom = zoom;
  [self _clampPanOffset];
  [self renderLanes];
}

- (CGFloat)panOffset {
  return _panOffset;
}

- (void)setPanOffset:(CGFloat)panOffset {
  if (fabs(_panOffset - panOffset) < 0.0001)
    return;
  _panOffset = panOffset;
  [self _clampPanOffset];
  [self renderLanes];
}

- (void)setFrameSize:(NSSize)newSize {
  BOOL wasZero = self.bounds.size.width < 1.0 || self.bounds.size.height < 1.0;
  [super setFrameSize:newSize];
  [self renderLanes];
  if (wasZero && newSize.width > 0.5 && newSize.height > 0.5) {
    // First time we have a real size — scroll the enclosing scroll view to
    // the visual top of the document (high Y in unflipped doc coords).
    NSScrollView *sv = [self enclosingScrollView];
    if (sv) {
      CGFloat topY = newSize.height - sv.contentView.bounds.size.height;
      [sv.contentView scrollToPoint:NSMakePoint(0, MAX(0, topY))];
      [sv reflectScrolledClipView:sv.contentView];
    }
  }
}

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
  CGFloat laneH = [self _laneHeight];
  return totalHeight - kKSSBoundaryLabelHeight - (laneIdx + 1) * laneH -
         laneIdx * (kKSSBoundaryLabelHeight + kKSSLaneSpacing);
}

- (CGFloat)_laneHeight {
  NSUInteger count = _lanes.count;
  if (count == 0)
    return kKSSMinLaneHeight;
  CGFloat fixedOverhead = (CGFloat)(count + 1) * kKSSBoundaryLabelHeight +
                          (CGFloat)(count - 1) * kKSSLaneSpacing +
                          kKSSBorderInset;
  CGFloat available = [self _totalHeight] - fixedOverhead;
  CGFloat laneH = available / (CGFloat)count;
  return MAX(kKSSMinLaneHeight, laneH);
}

- (CGFloat)_totalHeight {
  CGFloat minH = [KKStageSequencerView heightForLaneCount:_lanes.count];
  return MAX(minH, NSHeight(self.bounds));
}

+ (CGFloat)heightForLaneCount:(NSUInteger)laneCount {
  if (laneCount == 0)
    return 0;
  CGFloat block = kKSSMinLaneHeight + kKSSBoundaryLabelHeight;
  return kKSSBoundaryLabelHeight + laneCount * block +
         (laneCount - 1) * kKSSLaneSpacing + kKSSBorderInset;
}

@end
#pragma clang diagnostic pop
