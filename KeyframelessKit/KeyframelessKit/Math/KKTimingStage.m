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
  return c;
}

@end
