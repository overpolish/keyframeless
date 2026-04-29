/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKTimingStage.h"

NSArray<NSNumber *> *
KKTimingBoundaryBefore(NSUInteger idx, NSArray<KKTimingSegment *> *segments) {
  if (idx == 0 || segments.count == 0)
    return segments.firstObject.values;
  KKTimingSegment *current = segments[idx];
  KKTimingSegment *prev = segments[idx - 1];
  if (current.type == KKSegmentTypeHold)
    return current.values;
  if (prev.type == KKSegmentTypeHold)
    return prev.values;
  return current.values;
}

NSArray<NSNumber *> *
KKTimingBoundaryAfter(NSUInteger idx, NSArray<KKTimingSegment *> *segments) {
  NSUInteger next = idx + 1;
  if (next >= segments.count)
    return segments[idx].values;
  return KKTimingBoundaryBefore(next, segments);
}

/// Minimum segment width in seconds. Matches the sequencer's
/// interactive-drag floor (`kKSSMinSegmentSec`).
static const double kKKTimingMinSegmentSec = 0.1;

NSArray<KKTimingSegment *> *
KKTimingRebalancedSegments(NSArray<KKTimingSegment *> *segments,
                           double oldDuration, double newDuration) {
  if (segments.count == 0 || oldDuration <= 0 || newDuration <= 0 ||
      fabs(oldDuration - newDuration) < 1e-9)
    return segments;

  double rangeStart = segments.firstObject.start;
  double rangeEnd = segments.lastObject.end;
  double rangeFrac = rangeEnd - rangeStart;
  if (rangeFrac <= 0)
    return segments;
  double rangeSecNew = rangeFrac * newDuration;

  double totalLockedSec = 0;
  double totalUnlockedSec = 0;
  for (KKTimingSegment *s in segments) {
    double secOld = (s.end - s.start) * oldDuration;
    if (s.lockedDurationSeconds > 0)
      totalLockedSec += s.lockedDurationSeconds;
    else
      totalUnlockedSec += secOld;
  }

  BOOL lockedFit = totalLockedSec <= rangeSecNew;
  double unlockedScale = 1.0;
  double globalScale = 1.0;
  if (lockedFit) {
    double unlockedSecNew = rangeSecNew - totalLockedSec;
    if (totalUnlockedSec > 0)
      unlockedScale = unlockedSecNew / totalUnlockedSec;
  } else {
    double totalCurrentSec = totalLockedSec + totalUnlockedSec;
    if (totalCurrentSec > 0)
      globalScale = rangeSecNew / totalCurrentSec;
  }

  NSUInteger n = segments.count;
  double *fracs = (double *)malloc(sizeof(double) * n);
  for (NSUInteger i = 0; i < n; i++) {
    KKTimingSegment *orig = segments[i];
    double secNew;
    if (lockedFit) {
      secNew = (orig.lockedDurationSeconds > 0)
                   ? orig.lockedDurationSeconds
                   : (orig.end - orig.start) * oldDuration * unlockedScale;
    } else {
      double secOld = (orig.lockedDurationSeconds > 0)
                          ? orig.lockedDurationSeconds
                          : (orig.end - orig.start) * oldDuration;
      secNew = secOld * globalScale;
    }
    fracs[i] = secNew / newDuration;
  }

  // Enforce per-segment minimum width. When any segment falls below the
  // floor, bump it up and steal the deficit from above-floor segments
  // proportional to their excess. If the clip is too small to honour the
  // floor for every segment, fall back to uniform distribution.
  double minFrac = kKKTimingMinSegmentSec / newDuration;
  if ((double)n * minFrac >= rangeFrac - 1e-9) {
    double uniform = rangeFrac / (double)n;
    for (NSUInteger i = 0; i < n; i++)
      fracs[i] = uniform;
  } else {
    for (int iter = 0; iter < 8; iter++) {
      double deficit = 0;
      for (NSUInteger i = 0; i < n; i++) {
        if (fracs[i] < minFrac) {
          deficit += (minFrac - fracs[i]);
          fracs[i] = minFrac;
        }
      }
      if (deficit < 1e-9)
        break;
      double excess = 0;
      for (NSUInteger i = 0; i < n; i++)
        if (fracs[i] > minFrac)
          excess += (fracs[i] - minFrac);
      if (excess < 1e-9)
        break;
      double ratio = MIN(deficit, excess) / excess;
      for (NSUInteger i = 0; i < n; i++)
        if (fracs[i] > minFrac)
          fracs[i] -= (fracs[i] - minFrac) * ratio;
    }
  }

  NSMutableArray<KKTimingSegment *> *result =
      [NSMutableArray arrayWithCapacity:n];
  double pos = rangeStart;
  for (NSUInteger i = 0; i < n; i++) {
    KKTimingSegment *copy = [segments[i] copy];
    copy.start = pos;
    pos += fracs[i];
    // Last segment pins to rangeEnd to absorb floating-point drift.
    copy.end = (i == n - 1) ? rangeEnd : pos;
    [result addObject:copy];
  }
  free(fracs);
  return result;
}

NSArray<KKTimingLane *> *KKTimingRebalancedLanes(NSArray<KKTimingLane *> *lanes,
                                                 double currentDuration) {
  if (currentDuration <= 0 || lanes.count == 0)
    return lanes;
  NSMutableArray<KKTimingLane *> *out =
      [NSMutableArray arrayWithCapacity:lanes.count];
  for (KKTimingLane *lane in lanes) {
    double last = lane.lastKnownClipDuration;
    if (last <= 0) {
      // First read: baseline at current duration without mutating segments.
      KKTimingLane *copy = [lane copy];
      copy.lastKnownClipDuration = currentDuration;
      [out addObject:copy];
      continue;
    }
    if (fabs(last - currentDuration) < 1e-9) {
      [out addObject:lane];
      continue;
    }
    KKTimingLane *copy = [lane copy];
    copy.segments =
        KKTimingRebalancedSegments(lane.segments, last, currentDuration);
    copy.lastKnownClipDuration = currentDuration;
    [out addObject:copy];
  }
  return out;
}

@implementation KKTimingSegment

+ (instancetype)holdWithValues:(NSArray<NSNumber *> *)values
                         start:(double)start
                           end:(double)end {
  KKTimingSegment *s = [[KKTimingSegment alloc] init];
  s.type = KKSegmentTypeHold;
  s.start = start;
  s.end = end;
  s.values = values;
  s.easing = KKEasingCurveLinear;
  s.holdEffect = KKHoldEffectNone;
  s.intensity = 0.5;
  s.frequency = 0.5;
  s.seed = 0;
  s.linked = YES;
  return s;
}

+ (instancetype)transitionWithStart:(double)start
                                end:(double)end
                             easing:(KKEasingCurve)easing
                          intensity:(double)intensity
                          frequency:(double)frequency
                             values:(NSArray<NSNumber *> *)values {
  KKTimingSegment *s = [[KKTimingSegment alloc] init];
  s.type = KKSegmentTypeTransition;
  s.start = start;
  s.end = end;
  s.values = values;
  s.easing = easing;
  s.holdEffect = KKHoldEffectNone;
  s.intensity = intensity;
  s.frequency = frequency;
  s.seed = 0;
  s.linked = YES;
  return s;
}

- (double)value {
  return _values.count > 0 ? _values[0].doubleValue : 0;
}

- (id)copyWithZone:(NSZone *)zone {
  KKTimingSegment *c = [[KKTimingSegment alloc] init];
  c.type = _type;
  c.start = _start;
  c.end = _end;
  c.values = [_values copy];
  c.easing = _easing;
  c.holdEffect = _holdEffect;
  c.intensity = _intensity;
  c.frequency = _frequency;
  c.seed = _seed;
  c.linked = _linked;
  c.lockedDurationSeconds = _lockedDurationSeconds;
  c.pathData = [_pathData copy];
  return c;
}

@end

@implementation KKTimingLane

+ (instancetype)laneWithLabel:(NSString *)label
                     segments:(NSArray<KKTimingSegment *> *)segments
                      enabled:(BOOL)enabled {
  KKTimingLane *l = [[KKTimingLane alloc] init];
  l.propertyLabel = label;
  l.segments = segments;
  l.enabled = enabled;
  l.oscVisible = YES;
  l.visibleInSequencer = YES;
  // Default: select first hold segment.
  l.selectedSegment = -1;
  for (NSUInteger i = 0; i < segments.count; i++) {
    if (segments[i].type == KKSegmentTypeHold) {
      l.selectedSegment = (NSInteger)i;
      break;
    }
  }
  return l;
}

+ (instancetype)defaultLaneForLabel:(NSString *)label
                         baseValues:(NSArray<NSNumber *> *)baseValues {
  KKTimingSegment *hold = [KKTimingSegment holdWithValues:baseValues
                                                    start:0.0
                                                      end:1.0];
  return [self laneWithLabel:label segments:@[ hold ] enabled:YES];
}

- (void)insertSegment:(KKTimingSegment *)segment atIndex:(NSUInteger)index {
  NSMutableArray *m = [_segments mutableCopy];
  if (index > m.count)
    index = m.count;
  [m insertObject:segment atIndex:index];
  self.segments = [m copy];
}

- (void)removeSegmentAtIndex:(NSUInteger)index {
  if (index >= _segments.count)
    return;
  NSMutableArray *m = [_segments mutableCopy];
  [m removeObjectAtIndex:index];
  self.segments = [m copy];
}

- (id)copyWithZone:(NSZone *)zone {
  NSMutableArray *copied = [NSMutableArray arrayWithCapacity:_segments.count];
  for (KKTimingSegment *s in _segments)
    [copied addObject:[s copy]];
  KKTimingLane *c = [KKTimingLane laneWithLabel:_propertyLabel
                                       segments:copied
                                        enabled:_enabled];
  c.selectedSegment = _selectedSegment;
  c.hasOSC = _hasOSC;
  c.oscVisible = _oscVisible;
  c.visibleInSequencer = _visibleInSequencer;
  c.lastKnownClipDuration = _lastKnownClipDuration;
  return c;
}

@end
