/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKStageSequencerView_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"

@implementation KKSequencerRow
@end

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

- (void)setSelectedGroupKey:(NSString *)key {
  if (_selectedGroupKey == key || [_selectedGroupKey isEqualToString:key])
    return;
  _selectedGroupKey = [key copy];
  [self renderLanes];
}

- (void)setLanes:(NSArray<KKTimingLane *> *)lanes {
  NSUInteger prevRowCount = _rowPlan.count;
  NSMutableArray<KKTimingLane *> *stamped =
      [NSMutableArray arrayWithCapacity:lanes.count];
  for (KKTimingLane *lane in lanes) {
    KKTimingLane *c = [lane copy];
    // Legacy compat: when `_laneLabelsWithOSC` is provided, override per
    // the dict (matching pre-migration behaviour). When it's nil, trust
    // whatever the plugin baked into the lane.
    if (_laneLabelsWithOSC)
      c.hasOSC = [_laneLabelsWithOSC containsObject:c.propertyLabel];
    [stamped addObject:c];
  }
  _lanes = [stamped copy];
  // Reconcile the chevron-rotation cache: when host undo/redo flips
  // `groupCollapsed` underneath us, the cached rotation (set by user
  // click) lies about the current state and the render path otherwise
  // wins over `row.groupCollapsed`. Drop any cache entry that
  // disagrees with the new lane data so the chevron flips visually.
  if (_groupChevronRotation.count) {
    NSMutableDictionary<NSString *, NSNumber *> *expected =
        [NSMutableDictionary dictionary];
    for (KKTimingLane *l in _lanes) {
      if (!l.groupKey.length || expected[l.groupKey])
        continue;
      expected[l.groupKey] = @(l.groupCollapsed ? 0.0 : 90.0);
    }
    NSArray<NSString *> *keys = [_groupChevronRotation.allKeys copy];
    for (NSString *gk in keys) {
      NSNumber *cached = _groupChevronRotation[gk];
      NSNumber *want = expected[gk];
      if (!want || cached.doubleValue != want.doubleValue)
        [_groupChevronRotation removeObjectForKey:gk];
    }
  }
  [self _rebuildRowPlan];
  if (_rowPlan.count != prevRowCount)
    [self invalidateIntrinsicContentSize];
  if (!_dragging && !_dragMoving && !_dragLaneMoving)
    [self renderLanes];
}

- (void)_rebuildRowPlan {
  NSMutableArray<KKSequencerRow *> *plan =
      [NSMutableArray arrayWithCapacity:_lanes.count];
  NSMutableArray<NSNumber *> *map =
      [NSMutableArray arrayWithCapacity:_lanes.count];
  NSString *currentGroupKey = nil;
  BOOL haveCurrentGroup = NO;
  BOOL groupCollapsed = NO;
  for (NSUInteger i = 0; i < _lanes.count; i++) {
    KKTimingLane *lane = _lanes[i];
    NSString *gk = lane.groupKey.length ? lane.groupKey : nil;
    BOOL groupChanged = !haveCurrentGroup ||
                        ((gk == nil) != (currentGroupKey == nil)) ||
                        (gk != nil && ![gk isEqualToString:currentGroupKey]);
    if (groupChanged) {
      currentGroupKey = gk;
      haveCurrentGroup = YES;
      if (gk) {
        KKSequencerRow *header = [[KKSequencerRow alloc] init];
        header.kind = KKSequencerRowKindHeader;
        header.laneIndex = (NSInteger)i;
        header.groupKey = gk;
        header.groupLabel = lane.groupLabel.length ? lane.groupLabel : gk;
        header.groupCollapsed = lane.groupCollapsed;
        groupCollapsed = lane.groupCollapsed;
        [plan addObject:header];
      } else {
        groupCollapsed = NO;
      }
    }
    if (gk && groupCollapsed) {
      [map addObject:@(-1)];
      continue;
    }
    KKSequencerRow *row = [[KKSequencerRow alloc] init];
    row.kind = KKSequencerRowKindLane;
    row.laneIndex = (NSInteger)i;
    [map addObject:@(plan.count)];
    [plan addObject:row];
  }
  _rowPlan = [plan copy];
  _planRowForLane = [map copy];
}

- (NSArray<NSNumber *> *)_componentKindsForLane:(KKTimingLane *)lane {
  if (lane.valueComponentKinds.count) {
    NSMutableArray<NSNumber *> *expanded = [NSMutableArray array];
    for (NSNumber *k in lane.valueComponentKinds) {
      switch ((KKAnimatableParamKind)k.integerValue) {
      case KKAnimatableParamKindColor:
        for (NSUInteger i = 0; i < 3; i++)
          [expanded addObject:k];
        break;
      case KKAnimatableParamKindPoint:
        for (NSUInteger i = 0; i < 2; i++)
          [expanded addObject:k];
        break;
      case KKAnimatableParamKindGradient:
        // Variable-length; renderer handles separately.
        break;
      default:
        [expanded addObject:k];
        break;
      }
    }
    if (expanded.count)
      return [expanded copy];
  }
  return _laneComponentKindsByLabel[lane.propertyLabel];
}

- (NSNumber *)_slotKindForLane:(KKTimingLane *)lane {
  NSNumber *first = lane.valueComponentKinds.firstObject;
  if (first)
    return first;
  return _laneKindsByLabel[lane.propertyLabel];
}

- (void)setLaneLabelsWithOSC:(NSSet<NSString *> *)labels {
  if ([_laneLabelsWithOSC isEqualToSet:labels])
    return;
  _laneLabelsWithOSC = [labels copy];
  // Re-stamp existing lanes so the icon appears/disappears as appropriate.
  if (_lanes.count)
    self.lanes = _lanes;
}

- (void)setLaneKindsByLabel:
    (NSDictionary<NSString *, NSNumber *> *)laneKindsByLabel {
  if ([_laneKindsByLabel isEqualToDictionary:laneKindsByLabel])
    return;
  _laneKindsByLabel = [laneKindsByLabel copy];
  if (!_dragging && !_dragMoving && !_dragLaneMoving)
    [self renderLanes];
}

- (void)setLaneComponentKindsByLabel:
    (NSDictionary<NSString *, NSArray<NSNumber *> *> *)
        laneComponentKindsByLabel {
  if ([_laneComponentKindsByLabel
          isEqualToDictionary:laneComponentKindsByLabel])
    return;
  _laneComponentKindsByLabel = [laneComponentKindsByLabel copy];
  if (!_dragging && !_dragMoving && !_dragLaneMoving)
    [self renderLanes];
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, [self _intrinsicRowsHeight]);
}

/// Height needed to render every row in the current plan at the minimum
/// lane height, including header rows. Used by `_totalHeight` and the
/// intrinsic content size — when the scroll view is shorter than this the
/// sequencer scrolls vertically.
- (CGFloat)_intrinsicRowsHeight {
  NSUInteger laneRows = 0;
  NSUInteger headerRows = 0;
  for (KKSequencerRow *row in _rowPlan) {
    if (row.kind == KKSequencerRowKindHeader)
      headerRows++;
    else
      laneRows++;
  }
  if (laneRows == 0 && headerRows == 0)
    return 0;
  NSUInteger totalRows = laneRows + headerRows;
  return kKSSBoundaryLabelHeight +
         (CGFloat)laneRows * (kKSSMinLaneHeight + kKSSBoundaryLabelHeight) +
         (CGFloat)headerRows * kKSSGroupHeaderHeight +
         (CGFloat)(totalRows > 0 ? totalRows - 1 : 0) * kKSSLaneSpacing +
         kKSSBorderInset;
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
  if (laneIdx >= _planRowForLane.count)
    return 0;
  NSInteger rowIdx = _planRowForLane[laneIdx].integerValue;
  if (rowIdx < 0)
    return 0; // hidden under collapsed group
  return [self _rowYForPlanIndex:(NSUInteger)rowIdx totalHeight:totalHeight];
}

/// Top-down walk of the row plan, returning the bottom-Y for `rowIdx`.
/// Layout (Y up, frame top is high Y):
/// `topPadding (boundaryLabel) → row 0 → trailing → spacing → row 1 → ...
/// → trailing → borderInset → frame bottom`. Lane rows trail one
/// boundaryLabel; header rows do not.
- (CGFloat)_rowYForPlanIndex:(NSUInteger)rowIdx
                 totalHeight:(CGFloat)totalHeight {
  CGFloat laneH = [self _laneHeight];
  CGFloat y = totalHeight - kKSSBoundaryLabelHeight;
  for (NSUInteger i = 0; i < _rowPlan.count; i++) {
    KKSequencerRow *row = _rowPlan[i];
    CGFloat rowH =
        (row.kind == KKSequencerRowKindHeader) ? kKSSGroupHeaderHeight : laneH;
    y -= rowH;
    if (i == rowIdx)
      return y;
    if (row.kind == KKSequencerRowKindLane)
      y -= kKSSBoundaryLabelHeight;
    y -= kKSSLaneSpacing;
  }
  return y;
}

- (CGFloat)_laneHeight {
  NSUInteger laneRows = 0;
  NSUInteger headerRows = 0;
  for (KKSequencerRow *row in _rowPlan) {
    if (row.kind == KKSequencerRowKindHeader)
      headerRows++;
    else
      laneRows++;
  }
  if (laneRows == 0)
    return kKSSMinLaneHeight;
  NSUInteger totalRows = laneRows + headerRows;
  // Mirrors `_rowYForPlanIndex:` exactly so the math is consistent.
  CGFloat fixedOverhead =
      kKSSBoundaryLabelHeight + (CGFloat)laneRows * kKSSBoundaryLabelHeight +
      (CGFloat)headerRows * kKSSGroupHeaderHeight +
      (CGFloat)(totalRows > 0 ? totalRows - 1 : 0) * kKSSLaneSpacing +
      kKSSBorderInset;
  CGFloat available = [self _totalHeight] - fixedOverhead;
  CGFloat laneH = available / (CGFloat)laneRows;
  return MAX(kKSSMinLaneHeight, laneH);
}

- (CGFloat)_totalHeight {
  return MAX([self _intrinsicRowsHeight], NSHeight(self.bounds));
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
