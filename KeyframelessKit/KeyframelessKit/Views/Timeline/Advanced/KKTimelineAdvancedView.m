/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPopoverKeepAlive.h"
#import "KKTimelineAdvancedView_Private.h"

// Global user preference (not per-clip): the Dynamic display warp is a viewing
// aid, so it persists across sessions and clips like a UI setting, never in the
// timeline blob.
static NSString *const kKKAdvancedDynamicDisplayDefaultsKey =
    @"KKAdvancedDynamicDisplay";

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
    _collapsedLayerKeys = [NSMutableSet set];
    _collapsedCategoryKeys = [NSMutableSet set];
    _dragOriginTimes = [NSMutableDictionary dictionary];
    _hoverLaneRow = -1;
    _hoverGapAIdx = -1;
    _zp = [[KKTimelineZoomPan alloc] init];
    _dynamicDisplay = [[NSUserDefaults standardUserDefaults]
        boolForKey:kKKAdvancedDynamicDisplayDefaultsKey];
    // Clear the active-keypose highlight when the shared value popover closes.
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(_valuePopoverDidClose:)
               name:KKStaticValuesPopoverDidCloseNotification
             object:nil];
  }
  return self;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)_valuePopoverDidClose:(NSNotification *)note {
  [self clearPopoverHighlights];
}

- (void)clearPopoverHighlights {
  if (!_valuePopoverShowing && !_gapPopoverShowing)
    return;
  _valuePopoverShowing = NO;
  _gapPopoverShowing = NO;
  [self setNeedsDisplay:YES];
}

- (void)setActiveLayerKey:(NSString *)activeLayerKey {
  _activeLayerKey = [activeLayerKey copy];
}

- (NSString *)activeLayerKey {
  return _activeLayerKey;
}

- (void)retargetKeyposePopoverToLayerKey:(NSString *)layerKey {
  if (layerKey == _activeLayerKey || [layerKey isEqualToString:_activeLayerKey])
    return;
  _activeLayerKey = [layerKey copy];
  // Re-point the open keypose popover at this layer's keypose at the same time.
  // Selection already moved here (this IS the response to it), so don't fire
  // the activation callback back at the host - that's the ping-pong.
  [self requestValuePopoverAtFraction:_currentPopoverFrac fireActivation:NO];
}

- (void)setDynamicDisplay:(BOOL)dynamicDisplay {
  if (_dynamicDisplay == dynamicDisplay)
    return;
  _dynamicDisplay = dynamicDisplay;
  [[NSUserDefaults standardUserDefaults]
      setBool:dynamicDisplay
       forKey:kKKAdvancedDynamicDisplayDefaultsKey];
  [self setNeedsDisplay:YES];
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
  // IMPORTANT: only forward to super (which bubbles up the responder chain to
  // FCP's inspector scroll view) when WE don't handle the gesture. Forwarding
  // a gesture we also act on makes the whole inspector scroll along with our
  // rows - the "double scroll". So super is called only on the no-op paths.
  if (_interactionsBlocked) {
    [super scrollWheel:event];
    return;
  }
  CGFloat dx = event.scrollingDeltaX;
  CGFloat dy = event.scrollingDeltaY;
  if (dx == 0 && dy == 0) {
    [super scrollWheel:event];
    return;
  }
  // Horizontal-dominant gestures pan the time axis; vertical-dominant ones
  // scroll the lane rows (only when they overflow the tracks viewport).
  if (fabs(dx) > fabs(dy) * 1.2) {
    NSRect tracks = [self _tracksRect];
    if ([_zp panByScrollDeltaX:dx
                       precise:event.hasPreciseScrollingDeltas
                        inRect:tracks]) {
      [self setNeedsDisplay:YES];
      [self _notifyZoomChanged];
      return;
    }
    [super scrollWheel:event];
    return;
  }
  CGFloat maxY = [self _maxScrollY];
  if (maxY <= 0.0) {
    // Nothing to scroll here - let the inspector have it.
    [super scrollWheel:event];
    return;
  }
  // Consume vertical scrolling even at the limit so the inspector doesn't
  // lurch when our rows bottom out mid-gesture.
  CGFloat newY = MAX(0.0, MIN(maxY, _scrollY - dy));
  if (newY != _scrollY) {
    _scrollY = newY;
    [self setNeedsDisplay:YES];
  }
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
  NSString *edgeLabel = nil;
  BOOL edgeLeading = NO;
  if (row >= 0) {
    NSArray<KKLane *> *anim = [self _animatableLanes];
    NSRect tracks = [self _tracksRect];
    // Gate on the cursor being inside the tracks rect - left of it is the
    // lane-label gutter (frac would clamp to 0 and falsely register a hit
    // on the first interval).
    if (row < (NSInteger)anim.count && pt.x >= NSMinX(tracks) &&
        pt.x <= NSMaxX(tracks)) {
      KKLane *lane = anim[row];
      double frac = [self _fracForX:pt.x inLane:lane inTracks:tracks];
      NSInteger aIdx = [self _intervalStartKPIdxInLane:lane atFrac:frac];
      if (aIdx >= 0) {
        gapLabel = lane.label;
        gapAIdx = aIdx;
      } else if (lane.keyposes.count >= 1) {
        // Before the first / after the last pill: a non-editable hold region.
        if (frac < lane.keyposes.firstObject.time) {
          edgeLabel = lane.label;
          edgeLeading = YES;
        } else if (frac > lane.keyposes.lastObject.time) {
          edgeLabel = lane.label;
          edgeLeading = NO;
        }
      }
    }
  }
  BOOL gapChanged =
      ![gapLabel isEqualToString:_hoverGapLabel] || gapAIdx != _hoverGapAIdx;
  BOOL edgeChanged = (edgeLabel != nil) != (_hoverEdgeLabel != nil) ||
                     ![edgeLabel isEqualToString:_hoverEdgeLabel] ||
                     (edgeLabel != nil && edgeLeading != _hoverEdgeLeading);
  if (row == _hoverLaneRow && !gapChanged && !edgeChanged)
    return;
  _hoverLaneRow = row;
  _hoverGapLabel = gapLabel;
  _hoverGapAIdx = gapAIdx;
  _hoverEdgeLabel = edgeLabel;
  _hoverEdgeLeading = edgeLeading;
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
  if (_hoverLaneRow == -1 && _hoverGapAIdx == -1 && !_hoverEdgeLabel)
    return;
  _hoverLaneRow = -1;
  _hoverGapLabel = nil;
  _hoverGapAIdx = -1;
  _hoverEdgeLabel = nil;
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
  // While a pill drag is active the view owns the timeline optimistically -
  // ignoring the host's parameterChanged echo round-trip prevents the curve
  // from flickering between the live drag state and the previous tick.
  if (_dragActive)
    return;
  _timeline = timeline;
  [self _clampScroll];
  [self setNeedsDisplay:YES];
}

- (void)applyHiddenLaneLabels:(NSSet<NSString *> *)labels {
  NSSet<NSString *> *next = labels.count ? [labels copy] : nil;
  if (next == _hiddenLaneLabels || [next isEqualToSet:_hiddenLaneLabels])
    return;
  _hiddenLaneLabels = next;
  [self _clampScroll];
  [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self _clampScroll];
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

- (void)setEmptyMessage:(NSString *)emptyMessage {
  if (_emptyMessage == emptyMessage || [_emptyMessage isEqual:emptyMessage])
    return;
  _emptyMessage = [emptyMessage copy];
  [self setNeedsDisplay:YES];
}

- (NSString *)primaryLaneLabel {
  return [_topLaneLabel copy];
}

@end
