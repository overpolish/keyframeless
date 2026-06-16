/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKTimelineAdvancedView_Private.h"

#import "KKTimelineScrubMath.h"
#import <KeyframelessKit/KKTimingEvaluation.h>

@implementation KKTimelineAdvancedView (Interaction)

- (BOOL)_isInScrubBand:(NSPoint)pt {
  NSRect g = [self _graphRect];
  NSRect tracks = [self _tracksRect];
  // Right edge runs out to the container edge, not NSMaxX(tracks), so the right
  // gutter where the last-frame pill draws stays scrubbable like the rest of
  // the ruler; _fracForX clamps those clicks to lastFrameFrac (the last pill).
  return KKTimelineScrubBandContainsPoint(pt, NSMinX(tracks), NSMaxX(g),
                                          NSMaxY(g));
}

// Drag snap: every animatable KP time (across all lanes) is a candidate,
// minus the KP being dragged. Stores the snap target in `_dragSnapFrac` for
// the guide line.
- (double)_snappedDragFracForX:(CGFloat)x
                          frac:(double)rawFrac
                      inTracks:(NSRect)tracks
                      skipLane:(NSString *)skipLane
                        skipKP:(NSInteger)skipKP {
  NSMutableArray<NSNumber *> *cands = [NSMutableArray array];
  for (KKLane *l in _timeline.lanes) {
    if (!l.enabled)
      continue;
    BOOL isSkipLane = [l.label isEqualToString:skipLane];
    for (NSInteger j = 0; j < (NSInteger)l.keyposes.count; j++) {
      if (isSkipLane && j == skipKP)
        continue;
      [cands addObject:@(l.keyposes[j].time)];
    }
  }
  // Under the warp, snap is measured in the DRAGGED lane's visual space (other
  // lanes' pills sit at different x, so cross-lane snapping aligns times, not
  // pixels). Project candidates through that lane's warp; linear otherwise.
  KKLane *dragLane =
      _dynamicDisplay ? [self _animatableLaneForLabel:skipLane] : nil;
  __weak typeof(self) weakSelf = self;
  return KKTimelineSnapFracInPixels(
      x, rawFrac, cands,
      ^CGFloat(double frac) {
        __strong typeof(weakSelf) s = weakSelf;
        if (dragLane)
          return [s _xForFrac:frac inLane:dragLane inTracks:tracks];
        return [s _xForFrac:frac inTracks:tracks];
      },
      kSnapInPx, &_dragSnapFrac);
}

- (double)_snappedScrubFracForX:(CGFloat)x inTracks:(NSRect)tracks {
  __weak typeof(self) weakSelf = self;
  return KKTimelineSnapFracInPixels(
      x, [self _fracForX:x inTracks:tracks], [self _snapCandidates],
      ^CGFloat(double frac) {
        return [weakSelf _xForFrac:frac inTracks:tracks];
      },
      kSnapInPx, &_snappedScrubFrac);
}

- (double)_deliveredScrubFracFromVisual:(double)visualFrac {
  return KKTimelineScrubFracDelivered(visualFrac, [self _clipDuration],
                                      _frameDurationSeconds);
}

- (void)mouseDown:(NSEvent *)event {
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optKey = (flags & kCGEventFlagMaskAlternate) != 0;
  BOOL cmdKey = (flags & kCGEventFlagMaskCommand) != 0;
  BOOL ctrlKey = (flags & kCGEventFlagMaskControl) != 0;
  BOOL shiftKey = (flags & kCGEventFlagMaskShift) != 0;
  _pressLaneLabel = nil;
  _pressKPIdx = -1;
  _dragActive = NO;
  _gapPressActive = NO;
  _marqueeActive = NO;
  _optPressOnPill = NO;
  _optPressOnEmpty = NO;
  _eraserActive = NO;
  _eraserLaneRow = -1;
  _scrubLaneLabel = nil;
  [_dragOriginTimes removeAllObjects];
  _dragFrozenLaneTimes = nil;
  NSInteger laneIdx = -1, kpIdx = -1;
  BOOL hitPill = [self _pillAtPoint:pt lane:&laneIdx kp:&kpIdx];

  [self.window makeFirstResponder:self];

  // A click on a layer HEADER row toggles that layer's collapse (hides/shows
  // its lanes); the header row itself stays. No edit gesture below applies.
  {
    NSArray<KKLane *> *anim = [self _animatableLanes];
    NSInteger row = [self _laneRowAtPoint:pt];
    if (row >= 0 && row < (NSInteger)anim.count && anim[row].headerPlaceholder) {
      NSString *lk = anim[row].layerKey ?: @"";
      if ([_collapsedLayerKeys containsObject:lk])
        [_collapsedLayerKeys removeObject:lk];
      else
        [_collapsedLayerKeys addObject:lk];
      [self _clampScroll];
      [self setNeedsDisplay:YES];
      return;
    }
  }

  // cmd+opt anywhere (even on a pill) = "scrub to here" for quick preview.
  // Checked before the other opt/cmd gestures so it always wins. Lane-aware so
  // the time lands where the cursor sits under the warp; drags keep scrubbing.
  if (cmdKey && optKey) {
    NSRect tracks = [self _tracksRect];
    NSInteger row = [self _laneRowAtPoint:pt];
    NSArray<KKLane *> *anim = [self _animatableLanes];
    KKLane *lane = (row >= 0 && row < (NSInteger)anim.count) ? anim[row] : nil;
    double frac = lane ? [self _fracForX:pt.x inLane:lane inTracks:tracks]
                       : [self _fracForX:pt.x inTracks:tracks];
    _scrubbing = YES;
    _scrubLaneLabel = lane ? [lane.label copy] : nil;
    _playheadFraction = frac;
    [self setNeedsDisplay:YES];
    if (self.onScrub)
      self.onScrub([self _deliveredScrubFracFromVisual:frac]);
    return;
  }

  if (optKey && hitPill) {
    KKLane *lane = [self _animatableLanes][laneIdx];
    _pressLaneLabel = [lane.label copy];
    _pressKPIdx = kpIdx;
    _pressPoint = pt;
    _optPressOnPill = YES;
    return;
  }
  if (optKey && !hitPill) {
    NSInteger row = [self _laneRowAtPoint:pt];
    if (row >= 0) {
      _optPressOnEmpty = YES;
      _eraserLaneRow = row;
      _pressPoint = pt;
      return;
    }
  }

  if (shiftKey && hitPill) {
    KKLane *lane = [self _animatableLanes][laneIdx];
    NSString *key = [self _selectionKeyForLabel:lane.label kpIdx:kpIdx];
    if ([_selection containsObject:key])
      [_selection removeObject:key];
    else
      [_selection addObject:key];
    [self setNeedsDisplay:YES];
    return;
  }

  if (cmdKey && !hitPill) {
    NSInteger row = [self _laneRowAtPoint:pt];
    if (row >= 0) {
      NSRect tracks = [self _tracksRect];
      NSArray<KKLane *> *anim = [self _animatableLanes];
      KKLane *lane = (row < (NSInteger)anim.count) ? anim[row] : nil;
      double frac = lane ? [self _fracForX:pt.x inLane:lane inTracks:tracks]
                         : [self _fracForX:pt.x inTracks:tracks];
      [self _addAndOpenKPForLaneIdx:row atFrac:frac];
      return;
    }
  }

  (void)ctrlKey; // link toggle moved to the right-click gap context menu

  if (hitPill) {
    KKLane *lane = [self _animatableLanes][laneIdx];
    _pressLaneLabel = [lane.label copy];
    _pressKPIdx = kpIdx;
    _pressPoint = pt;
    _topLaneLabel = _pressLaneLabel;
    _topKPIdx = kpIdx;
    [self setNeedsDisplay:YES];
    return;
  }

  NSInteger gapLane = [self _laneRowAtPoint:pt];
  NSRect tracksForGap = [self _tracksRect];
  if (gapLane >= 0 && pt.x >= NSMinX(tracksForGap) &&
      pt.x <= NSMaxX(tracksForGap)) {
    NSArray<KKLane *> *anim = [self _animatableLanes];
    NSRect tracks = tracksForGap;
    double frac = [self _fracForX:pt.x inLane:anim[gapLane] inTracks:tracks];
    NSInteger aIdx = [self _intervalStartKPIdxInLane:anim[gapLane] atFrac:frac];
    if (shiftKey && aIdx >= 0) {
      NSString *gKey = [self _gapKeyForLabel:anim[gapLane].label aIdx:aIdx];
      if ([_selectedGaps containsObject:gKey])
        [_selectedGaps removeObject:gKey];
      else
        [_selectedGaps addObject:gKey];
      [self setNeedsDisplay:YES];
      return;
    }
    _gapPressActive = YES;
    _gapPressLabel = (aIdx >= 0) ? [anim[gapLane].label copy] : nil;
    _gapPressAIdx = aIdx;
    _pressPoint = pt;
    _marqueeShift = shiftKey;
    return;
  }

  _scrubbing = [self _isInScrubBand:pt];
  if (!_scrubbing)
    return;
  _snappedScrubFrac = NAN;
  NSRect tracks = [self _tracksRect];
  double frac = [self _snappedScrubFracForX:pt.x inTracks:tracks];
  _playheadFraction = frac;
  [self setNeedsDisplay:YES];
  if (self.onScrub)
    self.onScrub([self _deliveredScrubFracFromVisual:frac]);
}

- (void)mouseDragged:(NSEvent *)event {
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];

  if (_optPressOnEmpty && !_eraserActive) {
    if (hypot(pt.x - _pressPoint.x, pt.y - _pressPoint.y) < kDragThresholdPx)
      return;
    _eraserActive = YES;
    if (self.onDragBegin)
      self.onDragBegin();
  }
  if (_eraserActive) {
    [self _eraserTickAtPoint:pt];
    return;
  }

  if (_optPressOnPill && !_dragActive) {
    if (hypot(pt.x - _pressPoint.x, pt.y - _pressPoint.y) < kDragThresholdPx)
      return;
    NSInteger dupIdx = [self _insertDuplicateOfKPInLaneLabel:_pressLaneLabel
                                                       kpIdx:_pressKPIdx];
    if (dupIdx < 0) {
      _optPressOnPill = NO;
      return;
    }
    _pressKPIdx = dupIdx;
    _topLaneLabel = _pressLaneLabel;
    _topKPIdx = dupIdx;
    _optPressOnPill = NO;
    _wasDuplicateDrag = YES;
  }

  if (_pressLaneLabel) {
    if (!_dragActive) {
      if (hypot(pt.x - _pressPoint.x, pt.y - _pressPoint.y) < kDragThresholdPx)
        return;
      _dragActive = YES;
      if (self.onDragBegin)
        self.onDragBegin();
      NSString *pressedKey = [self _selectionKeyForLabel:_pressLaneLabel
                                                   kpIdx:_pressKPIdx];
      if ([_selection containsObject:pressedKey]) {
        [_dragOriginTimes removeAllObjects];
        for (NSString *k in _selection) {
          NSString *label;
          NSInteger idx;
          if (![self _decodeSelectionKey:k label:&label kpIdx:&idx])
            continue;
          for (KKLane *l in _timeline.lanes) {
            if (![l.label isEqualToString:label])
              continue;
            if (idx >= 0 && idx < (NSInteger)l.keyposes.count)
              _dragOriginTimes[k] = @(l.keyposes[idx].time);
            break;
          }
        }
        NSRect tracks = [self _tracksRect];
        if (_dynamicDisplay) {
          KKLane *pressLane = [self _animatableLaneForLabel:_pressLaneLabel];
          _dragFrozenLaneTimes =
              pressLane ? [self _laneKeyposeTimes:pressLane] : nil;
          _dragOriginFrac = [self _frozenDragFracForX:_pressPoint.x
                                             inTracks:tracks];
        } else {
          _dragOriginFrac = [self _fracForX:_pressPoint.x inTracks:tracks];
        }
      }
    }
    NSRect tracks = [self _tracksRect];
    if (_dragOriginTimes.count > 0) {
      // Selection drag: invert through the frozen warp so the group doesn't
      // creep as its members move (the live warp depends on their positions).
      double cur = _dynamicDisplay
                       ? [self _frozenDragFracForX:pt.x inTracks:tracks]
                       : [self _fracForX:pt.x inTracks:tracks];
      double delta = cur - _dragOriginFrac;
      [self _moveSelectionByDelta:delta];
    } else {
      double newFrac;
      if (_dynamicDisplay) {
        KKLane *pressLane = [self _animatableLaneForLabel:_pressLaneLabel];
        newFrac = [self _dragFracForX:pt.x
                               inLane:pressLane
                        draggingKPIdx:_pressKPIdx
                             inTracks:tracks];
      } else {
        newFrac = [self _fracForX:pt.x inTracks:tracks];
      }
      newFrac = [self _snappedDragFracForX:pt.x
                                      frac:newFrac
                                  inTracks:tracks
                                  skipLane:_pressLaneLabel
                                    skipKP:_pressKPIdx];
      NSInteger after = [self _moveKPInLaneLabel:_pressLaneLabel
                                           kpIdx:_pressKPIdx
                                          toFrac:newFrac];
      if (after >= 0 && after != _pressKPIdx) {
        _pressKPIdx = after;
        _topKPIdx = after;
      }
    }
    return;
  }
  if (_gapPressActive) {
    if (!_marqueeActive) {
      if (hypot(pt.x - _pressPoint.x, pt.y - _pressPoint.y) < kDragThresholdPx)
        return;
      _marqueeActive = YES;
      _marqueeAnchor = _pressPoint;
    }
    _marqueeCurrent = pt;
    [self setNeedsDisplay:YES];
    return;
  }
  if (!_scrubbing)
    return;
  NSRect tracks = [self _tracksRect];
  double frac;
  if (_scrubLaneLabel) {
    // cmd+opt lane scrub: invert through the lane's warp (free, no snap) so the
    // time follows the cursor where the user is looking.
    KKLane *lane = [self _animatableLaneForLabel:_scrubLaneLabel];
    frac = lane ? [self _fracForX:pt.x inLane:lane inTracks:tracks]
                : [self _snappedScrubFracForX:pt.x inTracks:tracks];
  } else {
    frac = [self _snappedScrubFracForX:pt.x inTracks:tracks];
  }
  _playheadFraction = frac;
  [self setNeedsDisplay:YES];
  if (self.onScrub)
    self.onScrub([self _deliveredScrubFracFromVisual:frac]);
}

- (void)mouseUp:(NSEvent *)event {
  if (_eraserActive) {
    _eraserActive = NO;
    _eraserLaneRow = -1;
    _optPressOnEmpty = NO;
    if (self.onDragEnd)
      self.onDragEnd();
    return;
  }
  if (_optPressOnEmpty) {
    _optPressOnEmpty = NO;
    _eraserLaneRow = -1;
    return;
  }
  if (_optPressOnPill && !_dragActive) {
    NSArray<KKLane *> *lanes = [self _animatableLanes];
    NSInteger li = -1;
    for (NSInteger i = 0; i < (NSInteger)lanes.count; i++)
      if ([lanes[i].label isEqualToString:_pressLaneLabel]) {
        li = i;
        break;
      }
    if (li >= 0)
      [self _removeKPInLaneIdx:li kpIdx:_pressKPIdx];
    _optPressOnPill = NO;
    _pressLaneLabel = nil;
    _pressKPIdx = -1;
    return;
  }
  if (_pressLaneLabel) {
    if (_dragActive) {
      BOOL wasDuplicate = _wasDuplicateDrag;
      NSString *dupLabel = nil;
      NSInteger dupIdx = -1;
      _wasDuplicateDrag = NO;
      if (wasDuplicate) {
        dupLabel = [_pressLaneLabel copy];
        dupIdx = _pressKPIdx;
      }
      _dragActive = NO;
      _dragSnapFrac = NAN;
      [_dragOriginTimes removeAllObjects];
      _dragFrozenLaneTimes = nil;
      [self setNeedsDisplay:YES];
      if (self.onDragEnd)
        self.onDragEnd();
      if (wasDuplicate && dupLabel && dupIdx >= 0)
        [self _replaceOnDropForLabel:dupLabel dupIdx:dupIdx];
    } else {
      [_selection removeAllObjects];
      [self setNeedsDisplay:YES];
      NSArray<KKLane *> *lanes = [self _animatableLanes];
      NSInteger li = -1;
      for (NSInteger i = 0; i < (NSInteger)lanes.count; i++)
        if ([lanes[i].label isEqualToString:_pressLaneLabel]) {
          li = i;
          break;
        }
      if (li >= 0)
        [self _openValuePopoverForLane:li kp:_pressKPIdx];
    }
    _pressLaneLabel = nil;
    _pressKPIdx = -1;
    return;
  }
  if (_gapPressActive) {
    if (_marqueeActive) {
      NSRect r = NSMakeRect(MIN(_marqueeAnchor.x, _marqueeCurrent.x),
                            MIN(_marqueeAnchor.y, _marqueeCurrent.y),
                            fabs(_marqueeAnchor.x - _marqueeCurrent.x),
                            fabs(_marqueeAnchor.y - _marqueeCurrent.y));
      if (!_marqueeShift) {
        [_selection removeAllObjects];
        [_selectedGaps removeAllObjects];
      }
      [self _addPillsInRect:r toSelection:_selection];
      [self _addGapsInRect:r toSelection:_selectedGaps];
      _marqueeActive = NO;
    } else {
      BOOL clickedSelected = NO;
      if (_gapPressLabel && _gapPressAIdx >= 0) {
        NSString *key = [self _gapKeyForLabel:_gapPressLabel
                                         aIdx:_gapPressAIdx];
        clickedSelected = [_selectedGaps containsObject:key];
      }
      if (!clickedSelected) {
        [_selection removeAllObjects];
        [_selectedGaps removeAllObjects];
      }
      if (_gapPressLabel && _gapPressAIdx >= 0)
        [self _openGapPopoverForLabel:_gapPressLabel kpIdx:_gapPressAIdx];
    }
    _gapPressActive = NO;
    _gapPressLabel = nil;
    [self setNeedsDisplay:YES];
    return;
  }
  _scrubbing = NO;
  _scrubLaneLabel = nil;
}

- (void)_addPillsInRect:(NSRect)rect
            toSelection:(NSMutableSet<NSString *> *)sel {
  NSArray<KKLane *> *anim = [self _animatableLanes];
  NSRect tracks = [self _tracksRect];
  for (NSInteger i = 0; i < (NSInteger)anim.count; i++) {
    NSRect row = [self _rowRectForIndex:i count:anim.count];
    NSRect ix = NSIntersectionRect(rect, row);
    if (NSIsEmptyRect(ix))
      continue;
    KKLane *lane = anim[i];
    for (NSInteger j = 0; j < (NSInteger)lane.keyposes.count; j++) {
      CGFloat x = [self _xForFrac:lane.keyposes[j].time
                           inLane:lane
                         inTracks:tracks];
      if (x >= NSMinX(rect) && x <= NSMaxX(rect))
        [sel addObject:[self _selectionKeyForLabel:lane.label kpIdx:j]];
    }
  }
}

- (void)_addGapsInRect:(NSRect)rect
           toSelection:(NSMutableSet<NSString *> *)sel {
  NSArray<KKLane *> *anim = [self _animatableLanes];
  NSRect tracks = [self _tracksRect];
  for (NSInteger i = 0; i < (NSInteger)anim.count; i++) {
    NSRect row = [self _rowRectForIndex:i count:anim.count];
    NSRect ix = NSIntersectionRect(rect, row);
    if (NSIsEmptyRect(ix))
      continue;
    KKLane *lane = anim[i];
    for (NSInteger j = 0; j + 1 < (NSInteger)lane.keyposes.count; j++) {
      CGFloat xA = [self _xForFrac:lane.keyposes[j].time
                            inLane:lane
                          inTracks:tracks];
      CGFloat xB = [self _xForFrac:lane.keyposes[j + 1].time
                            inLane:lane
                          inTracks:tracks];
      CGFloat mid = (xA + xB) * 0.5;
      if (mid >= NSMinX(rect) && mid <= NSMaxX(rect))
        [sel addObject:[self _gapKeyForLabel:lane.label aIdx:j]];
    }
  }
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)keyDown:(NSEvent *)event {
  if ((event.keyCode == 51 || event.keyCode == 117) && _selection.count > 0) {
    [self _deleteSelectedKPs];
    return;
  }
  if (event.keyCode == 53 &&
      (_selection.count > 0 || _selectedGaps.count > 0)) {
    [self clearSelection];
    return;
  }
  [super keyDown:event];
}

- (void)_deleteSelectedKPs {
  NSMutableDictionary<NSString *, NSMutableArray<NSNumber *> *> *byLabel =
      [NSMutableDictionary dictionary];
  for (NSString *key in _selection) {
    NSString *label;
    NSInteger idx;
    if (![self _decodeSelectionKey:key label:&label kpIdx:&idx])
      continue;
    NSMutableArray *arr = byLabel[label];
    if (!arr) {
      arr = [NSMutableArray array];
      byLabel[label] = arr;
    }
    [arr addObject:@(idx)];
  }

  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    NSMutableArray<NSNumber *> *toRemove = byLabel[lanes[i].label];
    if (toRemove.count == 0)
      continue;
    [toRemove
        sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
          return [b compare:a];
        }];
    KKLane *nl = [lanes[i] copy];
    for (NSNumber *n in toRemove) {
      NSInteger idx = n.integerValue;
      if (idx >= 0 && idx < (NSInteger)nl.keyposes.count)
        [nl removeKeyposeAtIndex:idx];
    }
    lanes[i] = nl;
    changed = YES;
  }
  if (!changed)
    return;
  [_selection removeAllObjects];
  [_selectedGaps removeAllObjects];
  _topLaneLabel = nil;
  _topKPIdx = -1;
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Move the keypose at (label, kpIdx) to `frac`. Crossing neighbours allowed;
// lane re-sorts by time and the KP's identity (values + outgoing interval)
// follows. Returns the post-sort index so the caller can update its press
// handle; -1 on no-op / failure.
- (NSInteger)_moveKPInLaneLabel:(NSString *)label
                          kpIdx:(NSInteger)kpIdx
                         toFrac:(double)frac {
  if (frac < 0.0)
    frac = 0.0;
  if (frac > 1.0)
    frac = 1.0;
  frac = KKSnapFracToFrame(frac, [self _clipDuration], _frameDurationSeconds);
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  NSInteger newIdx = -1;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].label isEqualToString:label])
      continue;
    KKLane *nl = [lanes[i] copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    if (kpIdx < 0 || kpIdx >= (NSInteger)kps.count)
      return -1;
    if (fabs(frac - kps[kpIdx].time) < 1.0e-6)
      return kpIdx;
    KKKeyPose *moved = [kps[kpIdx] keyposeBySettingTime:frac];
    kps[kpIdx] = moved;
    [kps sortUsingComparator:^NSComparisonResult(KKKeyPose *a, KKKeyPose *b) {
      if (a.time < b.time)
        return NSOrderedAscending;
      if (a.time > b.time)
        return NSOrderedDescending;
      return NSOrderedSame;
    }];
    for (NSInteger j = 0; j < (NSInteger)kps.count; j++)
      if (kps[j] == moved) {
        newIdx = j;
        break;
      }
    // Reorder may put a differently-valued pill between two linked endpoints,
    // breaking the "matching values" semantic the link depends on. Unlink any
    // interval whose endpoints no longer agree.
    for (NSInteger j = 0; j + 1 < (NSInteger)kps.count; j++) {
      KKInterval *iv = kps[j].outgoing;
      if (!iv.endpointsLinked)
        continue;
      if (KKAdvValuesEqual(kps[j].values, kps[j + 1].values))
        continue;
      KKInterval *unlinked = [iv copy];
      unlinked.endpointsLinked = NO;
      unlinked.curve = KKIntervalCurveLinear;
      KKKeyPose *replacement = [kps[j] keyposeBySettingTime:kps[j].time];
      replacement.outgoing = unlinked;
      if (kps[j] == moved)
        moved = replacement;
      kps[j] = replacement;
    }
    for (NSInteger j = 0; j < (NSInteger)kps.count; j++)
      if (kps[j] == moved) {
        newIdx = j;
        break;
      }
    nl.keyposes = kps;
    lanes[i] = nl;
    break;
  }
  if (newIdx < 0)
    return -1;
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
  return newIdx;
}

@end
