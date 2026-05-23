/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineAdvancedView_Private.h"

@implementation KKTimelineAdvancedView

- (instancetype)initWithAvailableLanes:(NSArray<KKLane *> *)availableLanes
                              timeline:(KKTimeline *)timeline {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _availableLanes = [availableLanes copy];
    _timeline = timeline;
    _playheadFraction = -1.0;
    _snappedScrubFrac = NAN;
    _dragSnapFrac = NAN;
    _selection = [NSMutableSet set];
    _selectedGaps = [NSMutableSet set];
    _dragOriginTimes = [NSMutableDictionary dictionary];
    _hoverLaneRow = -1;
    _hoverGapAIdx = -1;
    _zp = [[KKTimelineZoomPan alloc] init];
  }
  return self;
}

- (void)resetZoom {
  if (![_zp reset])
    return;
  [self setNeedsDisplay:YES];
  [self _notifyZoomChanged];
}

- (void)_notifyZoomChanged {
  BOOL zoomed = _zp.isZoomed;
  if (zoomed == _zoomedNotified)
    return;
  _zoomedNotified = zoomed;
  if (self.onZoomChanged)
    self.onZoomChanged(zoomed);
}

- (void)magnifyWithEvent:(NSEvent *)event {
  if (_interactionsBlocked)
    return;
  NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
  NSRect tracks = [self _tracksRect];
  if (![_zp magnifyBy:event.magnification atX:loc.x inRect:tracks])
    return;
  [self setNeedsDisplay:YES];
  [self _notifyZoomChanged];
}

// Forward to super first so any enclosing scroll view sees a coherent phase
// stream (see project_scrollwheel_momentum).
- (void)scrollWheel:(NSEvent *)event {
  [super scrollWheel:event];
  if (_interactionsBlocked)
    return;
  CGFloat dx = event.scrollingDeltaX;
  CGFloat dy = event.scrollingDeltaY;
  if (fabs(dx) <= fabs(dy) * 1.2 || (dx == 0 && dy == 0))
    return;
  NSRect tracks = [self _tracksRect];
  if (![_zp panByScrollDeltaX:dx
                      precise:event.hasPreciseScrollingDeltas
                       inRect:tracks])
    return;
  [self setNeedsDisplay:YES];
  [self _notifyZoomChanged];
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_hoverTrackingArea) {
    [self removeTrackingArea:_hoverTrackingArea];
    _hoverTrackingArea = nil;
  }
  if (_interactionsBlocked)
    return;
  _hoverTrackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                    NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_hoverTrackingArea];
}

- (void)setInteractionsBlocked:(BOOL)blocked {
  if (_interactionsBlocked == blocked)
    return;
  _interactionsBlocked = blocked;
  if (blocked && _hoverLaneRow != -1) {
    _hoverLaneRow = -1;
    [self setNeedsDisplay:YES];
  }
  [self updateTrackingAreas];
}

- (NSView *)hitTest:(NSPoint)point {
  if (_interactionsBlocked)
    return nil;
  return [super hitTest:point];
}

- (void)_updateHoverFromPoint:(NSPoint)pt {
  NSInteger row = [self _laneRowAtPoint:pt];
  NSString *gapLabel = nil;
  NSInteger gapAIdx = -1;
  if (row >= 0) {
    NSArray<KKLane *> *anim = [self _animatableLanes];
    NSRect tracks = [self _tracksRect];
    // Gate on the cursor being inside the tracks rect — left of it is the
    // lane-label gutter (frac would clamp to 0 and falsely register a hit
    // on the first interval).
    if (row < (NSInteger)anim.count && pt.x >= NSMinX(tracks) &&
        pt.x <= NSMaxX(tracks)) {
      KKLane *lane = anim[row];
      double frac = [self _fracForX:pt.x inTracks:tracks];
      NSInteger aIdx = [self _intervalStartKPIdxInLane:lane atFrac:frac];
      if (aIdx >= 0) {
        gapLabel = lane.label;
        gapAIdx = aIdx;
      }
    }
  }
  BOOL gapChanged =
      ![gapLabel isEqualToString:_hoverGapLabel] || gapAIdx != _hoverGapAIdx;
  if (row == _hoverLaneRow && !gapChanged)
    return;
  _hoverLaneRow = row;
  _hoverGapLabel = gapLabel;
  _hoverGapAIdx = gapAIdx;
  [self setNeedsDisplay:YES];
}

- (void)mouseMoved:(NSEvent *)event {
  [self _updateHoverFromPoint:[self convertPoint:event.locationInWindow
                                        fromView:nil]];
}

- (void)mouseEntered:(NSEvent *)event {
  [self _updateHoverFromPoint:[self convertPoint:event.locationInWindow
                                        fromView:nil]];
}

- (void)mouseExited:(NSEvent *)event {
  if (_hoverLaneRow == -1 && _hoverGapAIdx == -1)
    return;
  _hoverLaneRow = -1;
  _hoverGapLabel = nil;
  _hoverGapAIdx = -1;
  [self setNeedsDisplay:YES];
}

- (NSInteger)selectionCount {
  return (NSInteger)(_selection.count + _selectedGaps.count);
}

- (NSSet<NSString *> *)selectedPillKeys {
  return [_selection copy];
}

- (NSSet<NSString *> *)selectedGapKeys {
  return [_selectedGaps copy];
}

- (void)applySelectionPillKeys:(NSSet<NSString *> *)pillKeys
                       gapKeys:(NSSet<NSString *> *)gapKeys {
  NSSet *pk = pillKeys ?: [NSSet set];
  NSSet *gk = gapKeys ?: [NSSet set];
  if ([_selection isEqualToSet:pk] && [_selectedGaps isEqualToSet:gk])
    return;
  [_selection setSet:pk];
  [_selectedGaps setSet:gk];
  [self setNeedsDisplay:YES];
}

- (void)clearSelection {
  if (_selection.count == 0 && _selectedGaps.count == 0)
    return;
  [_selection removeAllObjects];
  [_selectedGaps removeAllObjects];
  [self setNeedsDisplay:YES];
}

- (void)setNeedsDisplay:(BOOL)flag {
  [super setNeedsDisplay:flag];
  NSInteger c = self.selectionCount;
  if (c != _lastEmittedSelectionCount) {
    _lastEmittedSelectionCount = c;
    if (_onSelectionChanged)
      _onSelectionChanged();
  }
}

- (void)applyTimeline:(KKTimeline *)timeline {
  // While a pill drag is active the view owns the timeline optimistically —
  // ignoring the host's parameterChanged echo round-trip prevents the curve
  // from flickering between the live drag state and the previous tick.
  if (_dragActive)
    return;
  _timeline = timeline;
  [self setNeedsDisplay:YES];
}

- (void)setClipDurationSeconds:(double)seconds {
  if (_clipDurationSeconds == seconds)
    return;
  _clipDurationSeconds = seconds;
  [self setNeedsDisplay:YES];
}

- (void)setFrameDurationSeconds:(double)seconds {
  _frameDurationSeconds = seconds;
}

- (void)setPlayheadFraction:(double)frac {
  if (_playheadFraction == frac)
    return;
  _playheadFraction = frac;
  [self setNeedsDisplay:YES];
}

- (NSString *)primaryLaneLabel {
  return [_topLaneLabel copy];
}

@end
