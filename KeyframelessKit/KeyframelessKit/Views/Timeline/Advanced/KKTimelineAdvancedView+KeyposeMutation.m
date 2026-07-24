/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKTimelineAdvancedView_Private.h"

#import "KKTimelineScrubMath.h"
#import <KeyframelessKit/KKTimingEvaluation.h>

@implementation KKTimelineAdvancedView (KeyposeMutation)

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
  NSArray<KKAdvancedRow *> *anim = [self _rows];
  if (laneIdx < 0 || laneIdx >= (NSInteger)anim.count)
    return;
  NSString *label = anim[laneIdx].lane.key;
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].key isEqualToString:label])
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
  NSArray<KKAdvancedRow *> *anim = [self _rows];
  if (laneIdx < 0 || laneIdx >= (NSInteger)anim.count)
    return;
  NSString *label = anim[laneIdx].lane.key;
  [self _addKeyposeAtFrac:frac forLabel:label];
  // _addKeyposeAtFrac: snaps the time to the nearest frame, so look up the
  // keypose by the SNAPPED time - searching the raw frac misses it for any
  // click between frames, and the value popover then silently never opens.
  double snapped =
      KKSnapFracToFrame(frac, [self _clipDuration], _frameDurationSeconds);
  NSArray<KKAdvancedRow *> *after = [self _rows];
  NSInteger newLaneIdx = -1, newKPIdx = -1;
  for (NSInteger i = 0; i < (NSInteger)after.count; i++) {
    KKLane *al = after[i].lane;
    if (![al.key isEqualToString:label])
      continue;
    newLaneIdx = i;
    for (NSInteger j = 0; j < (NSInteger)al.keyposes.count; j++)
      if (fabs(al.keyposes[j].time - snapped) < 1.0e-4) {
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
    if (![lanes[i].key isEqualToString:label])
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
  // Only clear the popover's primary-lane anchor when the removed KP was
  // FROM that primary lane. Clearing it for a sibling lane's removal
  // dropped scope back to "all animatable lanes" and made the filmstrip
  // pick up unrelated lanes' KPs (cell count would grow after removing a
  // sibling lane's KP). Preserving the anchor keeps the strip stable.
  if ([label isEqualToString:_topLaneLabel]) {
    _topLaneLabel = nil;
    _topKPIdx = -1;
  }
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

// Does any animatable lane in `group` still hold a keypose at `frac`? Drives
// the value popover's refresh-vs-close decision after a remove.
- (BOOL)_anySameGroupKeyposeAtFrac:(double)frac group:(NSString *)group {
  for (KKAdvancedRow *r in [self _rows]) {
    KKLane *l = r.lane;
    if (!l)
      continue;
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
  frac = KKSnapFracToFrame(frac, [self _clipDuration], _frameDurationSeconds);
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].key isEqualToString:label])
      continue;
    KKLane *src = lanes[i];
    NSArray<NSNumber *> *vals = KKTimelineLaneValueAtFraction(src, frac);
    if (!vals)
      vals = src.keyposes.firstObject.values;
    if (!vals)
      vals = [self _templateDefaultValuesForLabel:src.key];
    KKLane *nl = [src copy];
    KKKeyPose *inserted = [KKKeyPose keyposeAtTime:frac values:vals];
    // Geometry lane: capture the shape shown at this fraction so splitting a
    // hold yields an identical keypose (no phantom transition) instead of a
    // snapshot-less keypose that falls back to the base shape.
    if (src.oscEditedOnly)
      inserted.geometrySnapshot = KKLaneGeometrySnapshotAtFraction(src, frac);
    [nl insertKeypose:inserted];
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
          KKKeyPose *fixed = [prev keyposeBySettingTime:prev.time];
          fixed.outgoing = iv;
          kps[newIdx - 1] = fixed;
        }
      }
      KKKeyPose *newKP = kps[newIdx];
      KKInterval *outIv = [newKP.outgoing copy] ?: [[KKInterval alloc] init];
      outIv.endpointsLinked = NO;
      outIv.curve = KKIntervalCurveLinear;
      KKKeyPose *fixedNew = [newKP keyposeBySettingTime:newKP.time];
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
    if (![lanes[i].key isEqualToString:label])
      continue;
    KKLane *src = lanes[i];
    if (srcIdx < 0 || srcIdx >= (NSInteger)src.keyposes.count)
      return -1;
    KKKeyPose *srcKP = src.keyposes[srcIdx];
    double newTime = KKSnapFracToFrame(
        srcKP.time + 1.0 / 240.0, [self _clipDuration], _frameDurationSeconds);
    if (newTime <= srcKP.time)
      newTime = srcKP.time;
    KKKeyPose *dup = [srcKP keyposeBySettingTime:newTime];
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
    if ([lanes[i].key isEqualToString:label]) {
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
  CGFloat dupX = [self _xForFrac:dup.time inLane:lane inTracks:tracks];
  NSInteger targetIdx = -1;
  CGFloat bestDist = kSnapInPx;
  for (NSInteger j = 0; j < (NSInteger)lane.keyposes.count; j++) {
    if (j == dupIdx)
      continue;
    CGFloat x = [self _xForFrac:lane.keyposes[j].time
                         inLane:lane
                       inTracks:tracks];
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
  KKKeyPose *fixed = [tgt keyposeBySettingTime:tgt.time];
  fixed.values = dup.values;
  fixed.geometrySnapshot = dup.geometrySnapshot; // geometry lane: carry the shape
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
    // Exact label match, OR (multi-owner) the ACTIVE owner's lane whose plain
    // label matches. The mini-viewer point handle commits the PLAIN label
    // ("Position") from the selected owner's timeline, while a merged Advanced
    // timeline tags lanes "Position\x1f<ownerID>" - so the exact match misses
    // and the graph didn't update for the active keypose's OSC drag (field
    // edits pass the tagged label; path-anchor drags persist the whole blob).
    // layerKey==_activeLayerKey keeps it scoped to one owner. Single-owner
    // timelines have no tag / active key, so only the exact branch fires.
    BOOL match = [lanes[i].key isEqualToString:label];
    if (!match && _activeLayerKey.length && lanes[i].layerKey.length &&
        [lanes[i].layerKey isEqualToString:_activeLayerKey] &&
        [KKPlainLaneLabel(lanes[i].key)
            isEqualToString:KKPlainLaneLabel(label)])
      match = YES;
    if (!match)
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
      // Copy-and-update rather than reconstruct, so per-keypose fields beyond
      // time/values/outgoing (spatialSmooth, in/out handles) survive a value
      // edit instead of being silently reset to defaults.
      KKKeyPose *newKP = [kps[j] copy];
      newKP.values = values;
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
          KKKeyPose *fix = [src copy];
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
      if (![kLabel isEqualToString:src.key])
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
      NSString *key = [self _selectionKeyForLabel:src.key kpIdx:idx];
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
      target = KKSnapFracToFrame(target, [self _clipDuration],
                                 _frameDurationSeconds);
      if (target < lo)
        target = lo;
      if (target > hi)
        target = hi;
      if (fabs(target - kps[idx].time) < 1.0e-6)
        continue;
      KKKeyPose *newKP = [kps[idx] keyposeBySettingTime:target];
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

@end
