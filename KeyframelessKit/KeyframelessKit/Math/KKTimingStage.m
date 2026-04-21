/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKTimingStage.h"

static NSString *const kKeyType = @"type";
static NSString *const kKeyStart = @"start";
static NSString *const kKeyEnd = @"end";
static NSString *const kKeyValue = @"val";
static NSString *const kKeyEasing = @"ease";
static NSString *const kKeyIntensity = @"int";
static NSString *const kKeyFrequency = @"freq";

static NSString *const kKeyVersion = @"v";
static NSString *const kKeyLanes = @"lanes";
static NSString *const kKeyLabel = @"label";
static NSString *const kKeySegments = @"segs";
static NSString *const kKeyEnabled = @"on";

static const NSInteger kCurrentVersion = 2;

@implementation KKTimingSegment

+ (instancetype)holdWithValue:(double)value
                        start:(double)start
                          end:(double)end {
  KKTimingSegment *s = [[KKTimingSegment alloc] init];
  s.type = KKSegmentTypeHold;
  s.start = start;
  s.end = end;
  s.value = value;
  s.easing = KKEasingCurveLinear;
  s.intensity = 0.5;
  s.frequency = 0.5;
  return s;
}

+ (instancetype)transitionWithStart:(double)start
                                end:(double)end
                             easing:(KKEasingCurve)easing
                          intensity:(double)intensity
                          frequency:(double)frequency {
  KKTimingSegment *s = [[KKTimingSegment alloc] init];
  s.type = KKSegmentTypeTransition;
  s.start = start;
  s.end = end;
  s.value = 0;
  s.easing = easing;
  s.intensity = intensity;
  s.frequency = frequency;
  return s;
}

- (NSDictionary *)toDictionary {
  return @{
    kKeyType : @(_type),
    kKeyStart : @(_start),
    kKeyEnd : @(_end),
    kKeyValue : @(_value),
    kKeyEasing : @(_easing),
    kKeyIntensity : @(_intensity),
    kKeyFrequency : @(_frequency),
  };
}

+ (nullable instancetype)segmentFromDictionary:(NSDictionary *)dict {
  if (![dict isKindOfClass:[NSDictionary class]])
    return nil;
  NSNumber *typeNum = dict[kKeyType];
  if (!typeNum)
    return nil;
  KKTimingSegment *s = [[KKTimingSegment alloc] init];
  s.type = (KKSegmentType)typeNum.integerValue;
  s.start = [dict[kKeyStart] doubleValue];
  s.end = [dict[kKeyEnd] doubleValue];
  s.value = [dict[kKeyValue] doubleValue];
  s.easing = (KKEasingCurve)[dict[kKeyEasing] integerValue];
  s.intensity = [dict[kKeyIntensity] doubleValue];
  s.frequency = [dict[kKeyFrequency] doubleValue];
  return s;
}

- (id)copyWithZone:(NSZone *)zone {
  KKTimingSegment *c = [[KKTimingSegment alloc] init];
  c.type = _type;
  c.start = _start;
  c.end = _end;
  c.value = _value;
  c.easing = _easing;
  c.intensity = _intensity;
  c.frequency = _frequency;
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
  return l;
}

+ (instancetype)defaultLaneForLabel:(NSString *)label
                          baseValue:(double)baseValue {
  KKTimingSegment *transIn =
      [KKTimingSegment transitionWithStart:0.0
                                       end:0.1
                                    easing:KKEasingCurveEaseOut
                                 intensity:0.5
                                 frequency:0.5];
  KKTimingSegment *hold = [KKTimingSegment holdWithValue:baseValue
                                                   start:0.1
                                                     end:0.9];
  KKTimingSegment *transOut =
      [KKTimingSegment transitionWithStart:0.9
                                       end:1.0
                                    easing:KKEasingCurveEaseOut
                                 intensity:0.5
                                 frequency:0.5];
  return [self laneWithLabel:label
                    segments:@[ transIn, hold, transOut ]
                     enabled:YES];
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

- (double)resolvedValueAtIndex:(NSUInteger)index baseValue:(double)baseValue {
  if (index >= _segments.count)
    return baseValue;
  KKTimingSegment *seg = _segments[index];
  if (seg.type == KKSegmentTypeHold)
    return seg.value;
  // Transition: look at adjacent holds
  // Not needed for render (render walks segments), but useful for UI display.
  return baseValue;
}

- (id)copyWithZone:(NSZone *)zone {
  NSMutableArray *copied = [NSMutableArray arrayWithCapacity:_segments.count];
  for (KKTimingSegment *s in _segments)
    [copied addObject:[s copy]];
  return [KKTimingLane laneWithLabel:_propertyLabel
                            segments:copied
                             enabled:_enabled];
}

@end

@implementation KKTimingLane (Serialization)

+ (nullable NSString *)jsonFromLanes:(NSArray<KKTimingLane *> *)lanes {
  NSMutableArray *lanesArray = [NSMutableArray arrayWithCapacity:lanes.count];
  for (KKTimingLane *lane in lanes) {
    NSMutableArray *segsArray =
        [NSMutableArray arrayWithCapacity:lane.segments.count];
    for (KKTimingSegment *seg in lane.segments)
      [segsArray addObject:[seg toDictionary]];
    [lanesArray addObject:@{
      kKeyLabel : lane.propertyLabel ?: @"",
      kKeyEnabled : @(lane.enabled),
      kKeySegments : segsArray,
    }];
  }
  NSDictionary *root = @{
    kKeyVersion : @(kCurrentVersion),
    kKeyLanes : lanesArray,
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                 options:0
                                                   error:nil];
  if (!data)
    return nil;
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (nullable NSArray<KKTimingLane *> *)lanesFromJSON:(NSString *)json {
  if (!json.length)
    return nil;
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  if (!data)
    return nil;
  NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data
                                                       options:0
                                                         error:nil];
  if (![root isKindOfClass:[NSDictionary class]])
    return nil;
  NSArray *lanesArray = root[kKeyLanes];
  if (![lanesArray isKindOfClass:[NSArray class]])
    return nil;
  NSMutableArray<KKTimingLane *> *result =
      [NSMutableArray arrayWithCapacity:lanesArray.count];
  for (NSDictionary *laneDict in lanesArray) {
    if (![laneDict isKindOfClass:[NSDictionary class]])
      continue;
    NSString *label = laneDict[kKeyLabel];
    if (![label isKindOfClass:[NSString class]])
      continue;
    BOOL enabled = [laneDict[kKeyEnabled] boolValue];
    NSArray *segsArray = laneDict[kKeySegments];
    if (![segsArray isKindOfClass:[NSArray class]])
      continue;
    NSMutableArray<KKTimingSegment *> *segments =
        [NSMutableArray arrayWithCapacity:segsArray.count];
    for (NSDictionary *segDict in segsArray) {
      KKTimingSegment *seg = [KKTimingSegment segmentFromDictionary:segDict];
      if (seg)
        [segments addObject:seg];
    }
    if (!segments.count)
      continue;
    [result addObject:[KKTimingLane laneWithLabel:label
                                         segments:segments
                                          enabled:enabled]];
  }
  return result.count ? result : nil;
}

@end
