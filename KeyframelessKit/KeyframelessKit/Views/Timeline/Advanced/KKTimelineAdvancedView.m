/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneCategoryNav.h" // KKLaneLayerKeysWithKeyposeNearFraction
#import "KKPopoverKeepAlive.h"
#import "KKTimelineAdvancedView_Private.h"
#import "KKViewHelpers.h" // KKTrackingAreaMatches
#import <KeyframelessKit/KKLog.h>

// Global user preference (not per-clip): the Dynamic display warp is a viewing
// aid, so it persists across sessions and clips like a UI setting, never in the
// timeline blob.
static NSString *const kKKAdvancedDynamicDisplayDefaultsKey =
    @"KKAdvancedDynamicDisplay";

@implementation KKTimelineAdvancedView

- (void)updateAvailableLanes:(NSArray<KKLane *> *)availableLanes {
  _availableLanes = [availableLanes copy];
  [self setNeedsDisplay:YES];
}

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
    _headerToggleRects = [NSMutableDictionary dictionary];
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
  [_modifierPollTimer invalidate];
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
  // An owner with no keypose at the open time has nothing for this popover to
  // edit, so the popover stays where it is rather than re-scoping to an empty
  // editor. The host's own switcher is expected to gray that owner
  // (KKLaneLayerKeysWithKeyposeNearFraction, the set Canvas grays its layer
  // list with); this is the backstop for the paths that reach us anyway.
  if (layerKey.length &&
      ![KKLaneLayerKeysWithKeyposeNearFraction(
          _timeline.lanes, _currentPopoverFrac) containsObject:layerKey]) {
    KKLogDebug(@"[Keypose] retarget to %@ refused: no keypose at %.4f",
               layerKey, _currentPopoverFrac);
    return;
  }
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
  if (!_interactionsBlocked &&
      KKTrackingAreaMatches(_hoverTrackingArea, self.bounds))
    return;
  if (_hoverTrackingArea) {
    [self removeTrackingArea:_hoverTrackingArea];
    _hoverTrackingArea = nil;
  }
  if (_interactionsBlocked)
    return;
  _hoverTrackingArea = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:(NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved |
                    NSTrackingCursorUpdate | NSTrackingActiveInKeyWindow |
                    NSTrackingInVisibleRect)
             owner:self
          userInfo:nil];
  [self addTrackingArea:_hoverTrackingArea];
}

- (void)setInteractionsBlocked:(BOOL)blocked {
  if (_interactionsBlocked == blocked)
    return;
  _interactionsBlocked = blocked;
  if (blocked)
    [self _clearModifierCursor];
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
    NSArray<KKAdvancedRow *> *anim = [self _rows];
    NSRect tracks = [self _tracksRect];
    // Gate on the cursor being inside the tracks rect - left of it is the
    // lane-label gutter (frac would clamp to 0 and falsely register a hit
    // on the first interval).
    if (row < (NSInteger)anim.count && pt.x >= NSMinX(tracks) &&
        pt.x <= NSMaxX(tracks)) {
      KKLane *lane = anim[row].lane;
      double frac = [self _fracForX:pt.x inLane:lane inTracks:tracks];
      NSInteger aIdx = [self _intervalStartKPIdxInLane:lane atFrac:frac];
      if (aIdx >= 0) {
        gapLabel = lane.key;
        gapAIdx = aIdx;
      } else if (lane.keyposes.count >= 1) {
        // Before the first / after the last pill: a non-editable hold region.
        if (frac < lane.keyposes.firstObject.time) {
          edgeLabel = lane.key;
          edgeLeading = YES;
        } else if (frac > lane.keyposes.lastObject.time) {
          edgeLabel = lane.key;
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

// The add/delete affordance the modifiers currently held would apply at `pt`,
// or nil for the plain arrow. Mirrors -mouseDown: gesture-for-gesture (same
// order, same guards) so the cursor can never promise an edit the click won't
// perform. Reads the HID flag state rather than the event's, for the same
// reason -mouseDown: does: FCP synthesizes clicks into this process with the
// modifiers stripped, so the event's flags and the click's flags disagree.
- (NSCursor *)_modifierCursorAtPoint:(NSPoint)pt {
  if (_interactionsBlocked)
    return nil;
  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optKey = (flags & kCGEventFlagMaskAlternate) != 0;
  BOOL cmdKey = (flags & kCGEventFlagMaskCommand) != 0;
  // cmd+opt is the scrub gesture, which edits nothing.
  if (!(optKey ^ cmdKey))
    return nil;
  NSInteger laneIdx = -1, kpIdx = -1;
  BOOL hitPill = [self _pillAtPoint:pt lane:&laneIdx kp:&kpIdx];
  NSInteger row =
      (hitPill && laneIdx >= 0) ? laneIdx : [self _laneRowAtPoint:pt];
  NSArray<KKAdvancedRow *> *rows = [self _rows];
  if (row < 0 || row >= (NSInteger)rows.count)
    return nil;
  // A header row's click toggles its collapse; a locked layer rejects every
  // modifier edit. Neither adds or deletes.
  if (rows[row].isHeader || rows[row].lane.locked)
    return nil;
  // Opt drops the keypose under the pointer, so the affordance is strictly the
  // pill: Opt over empty track also arms the sweep-eraser, but a click there
  // deletes nothing, so it stays the plain arrow.
  if (optKey)
    return hitPill ? [NSCursor operationNotAllowedCursor] : nil;
  // Cmd inserts, but only off a pill - on one it falls through to the plain
  // press that opens the value popover.
  return hitPill ? nil : [NSCursor dragCopyCursor];
}

- (void)_refreshModifierCursorAtPoint:(NSPoint)pt {
  NSCursor *target = [self _modifierCursorAtPoint:pt] ?: [NSCursor arrowCursor];
  BOOL changed = _resolvedCursor != target;
  _resolvedCursor = target;
  if (changed && self.window)
    [self.window invalidateCursorRectsForView:self];
  [target set];
}

- (void)_refreshModifierCursorAtCurrentMouse {
  if (!self.window) {
    [self _clearModifierCursor];
    return;
  }
  NSPoint pt = [self convertPoint:self.window.mouseLocationOutsideOfEventStream
                         fromView:nil];
  if (!NSPointInRect(pt, self.bounds)) {
    [self _clearModifierCursor];
    return;
  }
  [self _refreshModifierCursorAtPoint:pt];
}

// Poll, don't only listen: this view sits in FCP's ViewBridge inspector, where
// flagsChanged: arrives only while we hold first responder - which a pointer
// that has hovered but never clicked does not. Sample the system-wide HID state
// while the pointer is over us (the same source -mouseDown: trusts) and stop
// the moment it leaves. Mirrors KKCodeEditorView's option-modifier poll.
- (void)_startModifierPolling {
  if (_modifierPollTimer)
    return;
  __weak typeof(self) weakSelf = self;
  _modifierPollTimer = [NSTimer
      scheduledTimerWithTimeInterval:0.1
                             repeats:YES
                               block:^(NSTimer *t) {
                                 [weakSelf
                                     _refreshModifierCursorAtCurrentMouse];
                               }];
  [NSRunLoop.currentRunLoop addTimer:_modifierPollTimer
                             forMode:NSRunLoopCommonModes];
}

- (void)_stopModifierPolling {
  [_modifierPollTimer invalidate];
  _modifierPollTimer = nil;
}

- (void)_clearModifierCursor {
  [self _stopModifierPolling];
  if (!_resolvedCursor)
    return;
  _resolvedCursor = nil;
  if (self.window)
    [self.window invalidateCursorRectsForView:self];
  [[NSCursor arrowCursor] set];
}

- (void)resetCursorRects {
  [super resetCursorRects];
  [self addCursorRect:self.bounds
               cursor:(_resolvedCursor ?: [NSCursor arrowCursor])];
}

- (void)mouseMoved:(NSEvent *)event {
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  [self _updateHoverFromPoint:pt];
  [self _refreshModifierCursorAtPoint:pt];
  [self _startModifierPolling];
}

// AppKit runs its own cursor-update pass after mouseMoved: returns; resolve
// from the same hit test there too rather than trying to out-time it.
- (void)cursorUpdate:(NSEvent *)event {
  [self _refreshModifierCursorAtPoint:[self convertPoint:event.locationInWindow
                                                fromView:nil]];
}

// The modifier can go down or up while the pointer sits perfectly still, so the
// cursor has to re-resolve against the last known mouse position, not the
// event's (a flagsChanged carries the location it was posted at, which for a
// stationary pointer is the same, but this also covers key-repeat and the
// window regaining focus mid-hold).
- (void)flagsChanged:(NSEvent *)event {
  [super flagsChanged:event];
  [self _refreshModifierCursorAtCurrentMouse];
}

- (void)mouseEntered:(NSEvent *)event {
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  [self _updateHoverFromPoint:pt];
  [self _refreshModifierCursorAtPoint:pt];
  [self _startModifierPolling];
}

- (void)mouseExited:(NSEvent *)event {
  [self _clearModifierCursor];
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
