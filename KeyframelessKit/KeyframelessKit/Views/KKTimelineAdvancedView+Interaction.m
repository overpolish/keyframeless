/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKTimelineAdvancedView_Private.h"

#import "../Math/KKTimelineScrubMath.h"
#import <KeyframelessKit/KKTimingEvaluation.h>

@implementation KKTimelineAdvancedView (Interaction)

- (BOOL)_isInScrubBand:(NSPoint)pt {
  NSRect tracks = [self _tracksRect];
  return KKTimelineScrubBandContainsPoint(pt, NSMinX(tracks), NSMaxX(tracks),
                                          NSMaxY([self _graphRect]));
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
  __weak typeof(self) weakSelf = self;
  return KKTimelineSnapFracInPixels(
      x, rawFrac, cands,
      ^CGFloat(double frac) {
        return [weakSelf _xForFrac:frac inTracks:tracks];
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
  [_dragOriginTimes removeAllObjects];
  NSInteger laneIdx = -1, kpIdx = -1;
  BOOL hitPill = [self _pillAtPoint:pt lane:&laneIdx kp:&kpIdx];

  [self.window makeFirstResponder:self];

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
      double frac = [self _fracForX:pt.x inTracks:tracks];
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
    double frac = [self _fracForX:pt.x inTracks:tracks];
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
        _dragOriginFrac = [self _fracForX:_pressPoint.x inTracks:tracks];
      }
    }
    NSRect tracks = [self _tracksRect];
    double newFrac = [self _fracForX:pt.x inTracks:tracks];
    if (_dragOriginTimes.count > 0) {
      double delta = newFrac - _dragOriginFrac;
      [self _moveSelectionByDelta:delta];
    } else {
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
  double frac = [self _snappedScrubFracForX:pt.x inTracks:tracks];
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
}

- (void)_eraserTickAtPoint:(NSPoint)pt {
  if (_eraserLaneRow < 0)
    return;
  NSInteger laneIdx = -1, kpIdx = -1;
  if (![self _pillAtPoint:pt lane:&laneIdx kp:&kpIdx])
    return;
  if (laneIdx != _eraserLaneRow)
    return;
  [self _removeKPInLaneIdx:laneIdx kpIdx:kpIdx];
}

// Opt+click pill: drop that keypose from its lane and write the new timeline.
- (void)_removeKPInLaneIdx:(NSInteger)laneIdx kpIdx:(NSInteger)kpIdx {
  NSArray<KKLane *> *anim = [self _animatableLanes];
  if (laneIdx < 0 || laneIdx >= (NSInteger)anim.count)
    return;
  NSString *label = anim[laneIdx].label;
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].label isEqualToString:label])
      continue;
    if (kpIdx < 0 || kpIdx >= (NSInteger)lanes[i].keyposes.count)
      return;
    KKLane *nl = [lanes[i] copy];
    [nl removeKeyposeAtIndex:kpIdx];
    lanes[i] = nl;
    changed = YES;
    break;
  }
  if (!changed)
    return;
  t.lanes = lanes;
  _timeline = t;
  _topLaneLabel = nil;
  _topKPIdx = -1;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Double-click gap: insert a KP at `frac` (evaluated value so the curve
// stays continuous), then open its value popover.
- (void)_addAndOpenKPForLaneIdx:(NSInteger)laneIdx atFrac:(double)frac {
  NSArray<KKLane *> *anim = [self _animatableLanes];
  if (laneIdx < 0 || laneIdx >= (NSInteger)anim.count)
    return;
  NSString *label = anim[laneIdx].label;
  [self _addKeyposeAtFrac:frac forLabel:label];
  NSArray<KKLane *> *after = [self _animatableLanes];
  NSInteger newLaneIdx = -1, newKPIdx = -1;
  for (NSInteger i = 0; i < (NSInteger)after.count; i++) {
    if (![after[i].label isEqualToString:label])
      continue;
    newLaneIdx = i;
    for (NSInteger j = 0; j < (NSInteger)after[i].keyposes.count; j++)
      if (fabs(after[i].keyposes[j].time - frac) < 1.0e-4) {
        newKPIdx = j;
        break;
      }
    break;
  }
  if (newLaneIdx < 0 || newKPIdx < 0)
    return;
  _topLaneLabel = label;
  _topKPIdx = newKPIdx;
  [self setNeedsDisplay:YES];
  [self _openValuePopoverForLane:newLaneIdx kp:newKPIdx];
}

// Remove the keypose at `frac` for `label` (the value-popover "−" gutter).
// Resolves the lane + keypose by time, then reuses removeKeyposeAtIndex:.
- (void)_removeKeyposeAtFrac:(double)frac forLabel:(NSString *)label {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].label isEqualToString:label])
      continue;
    KKLane *src = lanes[i];
    NSInteger kpIdx = -1;
    for (NSInteger k = 0; k < (NSInteger)src.keyposes.count; k++)
      if (fabs(src.keyposes[k].time - frac) < 1.0e-4) {
        kpIdx = k;
        break;
      }
    if (kpIdx < 0)
      return;
    KKLane *nl = [src copy];
    [nl removeKeyposeAtIndex:kpIdx];
    lanes[i] = nl;
    changed = YES;
    break;
  }
  if (!changed)
    return;
  t.lanes = lanes;
  _timeline = t;
  _topLaneLabel = nil;
  _topKPIdx = -1;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Does any animatable lane in `group` still hold a keypose at `frac`? Drives
// the value popover's refresh-vs-close decision after a remove.
- (BOOL)_anySameGroupKeyposeAtFrac:(double)frac group:(NSString *)group {
  for (KKLane *l in [self _animatableLanes]) {
    BOOL sameGroup =
        (l.groupKey == group) || [l.groupKey isEqualToString:group];
    if (!sameGroup)
      continue;
    for (KKKeyPose *k in l.keyposes)
      if (fabs(k.time - frac) < 1.0e-4)
        return YES;
  }
  return NO;
}

- (void)_addKeyposeAtFrac:(double)frac forLabel:(NSString *)label {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].label isEqualToString:label])
      continue;
    KKLane *src = lanes[i];
    NSArray<NSNumber *> *vals = KKTimelineLaneValueAtFraction(src, frac);
    if (!vals)
      vals = src.keyposes.firstObject.values;
    if (!vals)
      vals = [self _templateDefaultValuesForLabel:src.label];
    KKLane *nl = [src copy];
    [nl insertKeypose:[KKKeyPose keyposeAtTime:frac values:vals]];
    // The user added an independent checkpoint - break any link chain at
    // this insertion point so the first value edit doesn't propagate into
    // the neighbours.
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    NSInteger newIdx = -1;
    for (NSInteger j = 0; j < (NSInteger)kps.count; j++)
      if (fabs(kps[j].time - frac) < 1.0e-4) {
        newIdx = j;
        break;
      }
    if (newIdx >= 0) {
      if (newIdx > 0) {
        KKKeyPose *prev = kps[newIdx - 1];
        KKInterval *iv = [prev.outgoing copy] ?: [[KKInterval alloc] init];
        if (iv.endpointsLinked || iv.curve != KKIntervalCurveLinear) {
          iv.endpointsLinked = NO;
          iv.curve = KKIntervalCurveLinear;
          KKKeyPose *fixed = [KKKeyPose keyposeAtTime:prev.time
                                               values:prev.values];
          fixed.outgoing = iv;
          kps[newIdx - 1] = fixed;
        }
      }
      KKKeyPose *newKP = kps[newIdx];
      KKInterval *outIv = [newKP.outgoing copy] ?: [[KKInterval alloc] init];
      outIv.endpointsLinked = NO;
      outIv.curve = KKIntervalCurveLinear;
      KKKeyPose *fixedNew = [KKKeyPose keyposeAtTime:newKP.time
                                              values:newKP.values];
      fixedNew.outgoing = outIv;
      kps[newIdx] = fixedNew;
      nl.keyposes = kps;
    }
    lanes[i] = nl;
    changed = YES;
    break;
  }
  if (!changed)
    return;
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Opt+drag duplicate: clone the pressed pill's values onto a brand-new KP
// inserted at time + ε so it sits stably right after the original.
- (NSInteger)_insertDuplicateOfKPInLaneLabel:(NSString *)label
                                       kpIdx:(NSInteger)srcIdx {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  NSInteger newIdx = -1;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].label isEqualToString:label])
      continue;
    KKLane *src = lanes[i];
    if (srcIdx < 0 || srcIdx >= (NSInteger)src.keyposes.count)
      return -1;
    KKKeyPose *srcKP = src.keyposes[srcIdx];
    double newTime = MIN(1.0, srcKP.time + 1.0 / 240.0);
    KKKeyPose *dup = [KKKeyPose keyposeAtTime:newTime values:srcKP.values];
    KKLane *nl = [src copy];
    [nl insertKeypose:dup];
    for (NSInteger j = 0; j < (NSInteger)nl.keyposes.count; j++)
      if (fabs(nl.keyposes[j].time - newTime) < 1.0e-6) {
        newIdx = j;
        break;
      }
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

// Duplicate-drag drop-replace: if the duplicate's final time is within snap
// distance of another pill in the same lane, copy the duplicate's values
// onto that pill and delete the duplicate.
- (BOOL)_replaceOnDropForLabel:(NSString *)label dupIdx:(NSInteger)dupIdx {
  NSArray<KKLane *> *lanes = _timeline.lanes;
  NSInteger laneArrIdx = -1;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++)
    if ([lanes[i].label isEqualToString:label]) {
      laneArrIdx = i;
      break;
    }
  if (laneArrIdx < 0)
    return NO;
  KKLane *lane = lanes[laneArrIdx];
  if (dupIdx < 0 || dupIdx >= (NSInteger)lane.keyposes.count)
    return NO;
  KKKeyPose *dup = lane.keyposes[dupIdx];
  NSRect tracks = [self _tracksRect];
  CGFloat dupX = [self _xForFrac:dup.time inTracks:tracks];
  NSInteger targetIdx = -1;
  CGFloat bestDist = kSnapInPx;
  for (NSInteger j = 0; j < (NSInteger)lane.keyposes.count; j++) {
    if (j == dupIdx)
      continue;
    CGFloat x = [self _xForFrac:lane.keyposes[j].time inTracks:tracks];
    CGFloat d = fabs(x - dupX);
    if (d < bestDist) {
      bestDist = d;
      targetIdx = j;
    }
  }
  if (targetIdx < 0)
    return NO;
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *mLanes = [t.lanes mutableCopy];
  KKLane *nl = [lane copy];
  NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
  KKKeyPose *tgt = kps[targetIdx];
  KKKeyPose *fixed = [KKKeyPose keyposeAtTime:tgt.time values:dup.values];
  fixed.outgoing = tgt.outgoing;
  kps[targetIdx] = fixed;
  nl.keyposes = kps;
  [nl removeKeyposeAtIndex:dupIdx];
  mLanes[laneArrIdx] = nl;
  t.lanes = mLanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
  return YES;
}

- (void)_writeValueForLabel:(NSString *)label
                     atFrac:(double)frac
                     values:(NSArray<NSNumber *> *)values {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].label isEqualToString:label])
      continue;
    KKLane *nl = [lanes[i] copy];
    NSMutableArray<KKKeyPose *> *kps = [nl.keyposes mutableCopy];
    NSInteger editIdx = -1;
    for (NSInteger j = 0; j < (NSInteger)kps.count; j++)
      if (fabs(kps[j].time - frac) < 1.0e-4) {
        editIdx = j;
        break;
      }
    if (editIdx < 0)
      break;
    NSMutableIndexSet *toUpdate = [NSMutableIndexSet indexSetWithIndex:editIdx];
    NSInteger k = editIdx;
    while (k > 0 && kps[k - 1].outgoing.endpointsLinked) {
      [toUpdate addIndex:k - 1];
      k--;
    }
    k = editIdx;
    while (k + 1 < (NSInteger)kps.count && kps[k].outgoing.endpointsLinked) {
      [toUpdate addIndex:k + 1];
      k++;
    }
    NSInteger firstChanged = [toUpdate firstIndex];
    NSInteger lastChanged = [toUpdate lastIndex];
    NSArray<NSNumber *> *prevLeft =
        firstChanged > 0 ? kps[firstChanged - 1].values : nil;
    NSArray<NSNumber *> *prevFirstChanged = kps[firstChanged].values;
    NSArray<NSNumber *> *prevLastChanged = kps[lastChanged].values;
    NSArray<NSNumber *> *prevRight = lastChanged + 1 < (NSInteger)kps.count
                                         ? kps[lastChanged + 1].values
                                         : nil;

    [toUpdate enumerateIndexesUsingBlock:^(NSUInteger j, BOOL *stop) {
      KKKeyPose *newKP = [KKKeyPose keyposeAtTime:kps[j].time values:values];
      newKP.outgoing = kps[j].outgoing;
      kps[j] = newKP;
    }];

    // Was-hold → now-drift cleanup: a previously-set Wiggle/Oscillate would
    // stack with the new transition's easing curve (PLAN: modulation is
    // hold-only). Clear modulation on intervals that transitioned hold→drift.
    void (^clearModIfDriftFormed)(NSInteger, NSArray<NSNumber *> *,
                                  NSArray<NSNumber *> *) =
        ^(NSInteger ivIdx, NSArray<NSNumber *> *prevA,
          NSArray<NSNumber *> *prevB) {
          if (ivIdx < 0 || ivIdx + 1 >= (NSInteger)kps.count)
            return;
          if (!prevA || !prevB)
            return;
          BOOL wasEqual = KKAdvValuesEqual(prevA, prevB);
          BOOL nowEqual =
              KKAdvValuesEqual(kps[ivIdx].values, kps[ivIdx + 1].values);
          if (!wasEqual || nowEqual)
            return;
          KKKeyPose *src = kps[ivIdx];
          KKInterval *iv = [src.outgoing copy] ?: [[KKInterval alloc] init];
          iv.modulation = KKIntervalModulationNone;
          KKKeyPose *fix = [KKKeyPose keyposeAtTime:src.time values:src.values];
          fix.outgoing = iv;
          kps[ivIdx] = fix;
        };
    clearModIfDriftFormed(firstChanged - 1, prevLeft, prevFirstChanged);
    clearModIfDriftFormed(lastChanged, prevLastChanged, prevRight);

    nl.keyposes = kps;
    lanes[i] = nl;
    changed = YES;
    break;
  }
  if (!changed)
    return;
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Apply a single time-delta to every selected KP, clamped per-lane between
// its neighbours so within-lane ordering stays stable (PLAN: multi-select
// is "bulk time transform" only).
- (void)_moveSelectionByDelta:(double)delta {
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *src = lanes[i];
    NSMutableArray<KKKeyPose *> *kps = [src.keyposes mutableCopy];
    BOOL touched = NO;
    NSMutableArray<NSNumber *> *selIdx = [NSMutableArray array];
    for (NSString *key in _selection) {
      NSString *kLabel;
      NSInteger kIdx;
      if (![self _decodeSelectionKey:key label:&kLabel kpIdx:&kIdx])
        continue;
      if (![kLabel isEqualToString:src.label])
        continue;
      [selIdx addObject:@(kIdx)];
    }
    if (selIdx.count == 0)
      continue;
    [selIdx sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
      return (delta >= 0) ? [b compare:a] : [a compare:b];
    }];
    for (NSNumber *n in selIdx) {
      NSInteger idx = n.integerValue;
      if (idx < 0 || idx >= (NSInteger)kps.count)
        continue;
      NSString *key = [self _selectionKeyForLabel:src.label kpIdx:idx];
      NSNumber *origN = _dragOriginTimes[key];
      if (!origN)
        continue;
      double target = origN.doubleValue + delta;
      double lo = (idx > 0) ? kps[idx - 1].time + 1.0e-4 : 0.0;
      double hi =
          (idx + 1 < (NSInteger)kps.count) ? kps[idx + 1].time - 1.0e-4 : 1.0;
      if (target < lo)
        target = lo;
      if (target > hi)
        target = hi;
      if (fabs(target - kps[idx].time) < 1.0e-6)
        continue;
      KKKeyPose *newKP = [KKKeyPose keyposeAtTime:target
                                           values:kps[idx].values];
      newKP.outgoing = kps[idx].outgoing;
      kps[idx] = newKP;
      touched = YES;
    }
    if (touched) {
      KKLane *nl = [src copy];
      nl.keyposes = kps;
      lanes[i] = nl;
      changed = YES;
    }
  }
  if (!changed)
    return;
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
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
      CGFloat x = [self _xForFrac:lane.keyposes[j].time inTracks:tracks];
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
      CGFloat xA = [self _xForFrac:lane.keyposes[j].time inTracks:tracks];
      CGFloat xB = [self _xForFrac:lane.keyposes[j + 1].time inTracks:tracks];
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
    KKKeyPose *moved = [KKKeyPose keyposeAtTime:frac values:kps[kpIdx].values];
    moved.outgoing = kps[kpIdx].outgoing;
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
      KKKeyPose *replacement = [KKKeyPose keyposeAtTime:kps[j].time
                                                 values:kps[j].values];
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

- (NSMenu *)menuForEvent:(NSEvent *)event {
  if (_interactionsBlocked)
    return nil;
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  _menuPillLabel = nil;
  _menuPillKPIdx = -1;
  _menuGapLabel = nil;
  _menuGapAIdx = -1;
  _menuGapLaneRow = -1;
  _menuGapFrac = 0.0;
  NSInteger laneIdx = -1, kpIdx = -1;
  BOOL hitPill = [self _pillAtPoint:pt lane:&laneIdx kp:&kpIdx];
  NSArray<KKLane *> *anim = [self _animatableLanes];
  if (hitPill && laneIdx < (NSInteger)anim.count) {
    _menuPillLabel = [anim[laneIdx].label copy];
    _menuPillKPIdx = kpIdx;
  } else {
    NSInteger row = [self _laneRowAtPoint:pt];
    NSRect tracks = [self _tracksRect];
    if (row >= 0 && row < (NSInteger)anim.count && pt.x >= NSMinX(tracks) &&
        pt.x <= NSMaxX(tracks)) {
      double frac = [self _fracForX:pt.x inTracks:tracks];
      NSInteger aIdx = [self _intervalStartKPIdxInLane:anim[row] atFrac:frac];
      _menuGapLabel = [anim[row].label copy];
      _menuGapAIdx = aIdx;
      _menuGapLaneRow = row;
      _menuGapFrac = frac;
    }
  }

  NSMenu *menu = [[NSMenu alloc] init];
  BOOL hasSelection = _selection.count > 0;
  if (hasSelection) {
    [menu addItemWithTitle:KKLoc(@"Reverse", @"Context menu: reverse keyposes.")
                    action:@selector(_menuReverseSelection:)
             keyEquivalent:@""]
        .target = self;
    [menu addItemWithTitle:KKLoc(@"Distribute Evenly",
                                 @"Context menu: space keyposes evenly.")
                    action:@selector(_menuDistributeEvenly:)
             keyEquivalent:@""]
        .target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:KKLoc(@"Delete", @"Context menu: delete.")
                    action:@selector(_menuDeleteSelection:)
             keyEquivalent:@""]
        .target = self;
  } else if (_menuPillLabel) {
    [menu addItemWithTitle:KKLoc(@"Remove Keypose",
                                 @"Context menu: remove keypose.")
                    action:@selector(_menuRemovePill:)
             keyEquivalent:@""]
        .target = self;
  } else if (_menuGapLabel) {
    [menu addItemWithTitle:KKLoc(@"Add Keypose Here",
                                 @"Context menu: add keypose.")
                    action:@selector(_menuAddKeyposeAtGap:)
             keyEquivalent:@""]
        .target = self;
    if (_menuGapAIdx >= 0) {
      KKLane *gapLane = nil;
      for (KKLane *l in anim)
        if ([l.label isEqualToString:_menuGapLabel]) {
          gapLane = l;
          break;
        }
      KKInterval *iv =
          (gapLane && _menuGapAIdx + 1 < (NSInteger)gapLane.keyposes.count)
              ? gapLane.keyposes[_menuGapAIdx].outgoing
              : nil;
      if (iv) {
        [menu addItem:[NSMenuItem separatorItem]];
        NSString *title =
            iv.endpointsLinked
                ? KKLoc(@"Unlink Endpoints", @"Context menu: unlink endpoints.")
                : KKLoc(@"Link Endpoints", @"Context menu: link endpoints.");
        [menu addItemWithTitle:title
                        action:@selector(_menuToggleGapLink:)
                 keyEquivalent:@""]
            .target = self;
      }
    }
  } else {
    return nil;
  }
  return menu;
}

- (void)_menuToggleGapLink:(id)sender {
  if (_menuGapLabel && _menuGapAIdx >= 0)
    [self _toggleLinkForLabel:_menuGapLabel kpIdx:_menuGapAIdx];
}

- (void)_menuRemovePill:(id)sender {
  if (!_menuPillLabel)
    return;
  NSArray<KKLane *> *anim = [self _animatableLanes];
  NSInteger li = -1;
  for (NSInteger i = 0; i < (NSInteger)anim.count; i++)
    if ([anim[i].label isEqualToString:_menuPillLabel]) {
      li = i;
      break;
    }
  if (li >= 0)
    [self _removeKPInLaneIdx:li kpIdx:_menuPillKPIdx];
}

- (void)_menuAddKeyposeAtGap:(id)sender {
  if (_menuGapLaneRow < 0)
    return;
  [self _addAndOpenKPForLaneIdx:_menuGapLaneRow atFrac:_menuGapFrac];
}

- (void)_menuDeleteSelection:(id)sender {
  if (_selection.count > 0)
    [self _deleteSelectedKPs];
}

// Per-lane time-mirror around the lane's selection midpoint. Curves are NOT
// auto-flipped (user can tweak in the gap popover); times reversing alone is
// the natural "undo direction".
- (void)_menuReverseSelection:(id)sender {
  if (_selection.count == 0)
    return;
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *src = lanes[i];
    if (!src.enabled)
      continue;
    NSMutableArray<NSNumber *> *selIdx = [NSMutableArray array];
    for (NSString *key in _selection) {
      NSString *kLabel;
      NSInteger kIdx;
      if (![self _decodeSelectionKey:key label:&kLabel kpIdx:&kIdx])
        continue;
      if (![kLabel isEqualToString:src.label])
        continue;
      [selIdx addObject:@(kIdx)];
    }
    if (selIdx.count < 2)
      continue;
    [selIdx sortUsingSelector:@selector(compare:)];
    NSMutableArray<KKKeyPose *> *kps = [src.keyposes mutableCopy];
    double minT = kps[selIdx.firstObject.integerValue].time;
    double maxT = kps[selIdx.lastObject.integerValue].time;
    double mid = (minT + maxT) * 0.5;
    for (NSNumber *n in selIdx) {
      NSInteger idx = n.integerValue;
      KKKeyPose *kp = kps[idx];
      double newT = 2.0 * mid - kp.time;
      KKKeyPose *moved = [KKKeyPose keyposeAtTime:newT values:kp.values];
      moved.outgoing = kp.outgoing;
      kps[idx] = moved;
    }
    [kps sortUsingComparator:^NSComparisonResult(KKKeyPose *a, KKKeyPose *b) {
      return a.time < b.time   ? NSOrderedAscending
             : a.time > b.time ? NSOrderedDescending
                               : NSOrderedSame;
    }];
    KKLane *nl = [src copy];
    nl.keyposes = kps;
    lanes[i] = nl;
    changed = YES;
  }
  if (!changed)
    return;
  [_selection removeAllObjects];
  [_selectedGaps removeAllObjects];
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

- (void)_menuDistributeEvenly:(id)sender {
  if (_selection.count < 3)
    return;
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *src = lanes[i];
    if (!src.enabled)
      continue;
    NSMutableArray<NSNumber *> *selIdx = [NSMutableArray array];
    for (NSString *key in _selection) {
      NSString *kLabel;
      NSInteger kIdx;
      if (![self _decodeSelectionKey:key label:&kLabel kpIdx:&kIdx])
        continue;
      if (![kLabel isEqualToString:src.label])
        continue;
      [selIdx addObject:@(kIdx)];
    }
    if (selIdx.count < 3)
      continue;
    [selIdx sortUsingSelector:@selector(compare:)];
    NSMutableArray<KKKeyPose *> *kps = [src.keyposes mutableCopy];
    double minT = kps[selIdx.firstObject.integerValue].time;
    double maxT = kps[selIdx.lastObject.integerValue].time;
    NSInteger n = (NSInteger)selIdx.count;
    for (NSInteger k = 1; k + 1 < n; k++) {
      NSInteger idx = selIdx[k].integerValue;
      KKKeyPose *kp = kps[idx];
      double newT = minT + (maxT - minT) * ((double)k / (double)(n - 1));
      KKKeyPose *moved = [KKKeyPose keyposeAtTime:newT values:kp.values];
      moved.outgoing = kp.outgoing;
      kps[idx] = moved;
    }
    [kps sortUsingComparator:^NSComparisonResult(KKKeyPose *a, KKKeyPose *b) {
      return a.time < b.time   ? NSOrderedAscending
             : a.time > b.time ? NSOrderedDescending
                               : NSOrderedSame;
    }];
    KKLane *nl = [src copy];
    nl.keyposes = kps;
    lanes[i] = nl;
    changed = YES;
  }
  if (!changed)
    return;
  [_selection removeAllObjects];
  [_selectedGaps removeAllObjects];
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

@end
