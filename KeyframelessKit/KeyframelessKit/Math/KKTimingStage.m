/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKTimingStage.h"

static NSString *const kKeyType = @"type";
static NSString *const kKeyStart = @"start";
static NSString *const kKeyEnd = @"end";
static NSString *const kKeyValues = @"vals";
static NSString *const kKeyEasing = @"ease";
static NSString *const kKeyIntensity = @"int";
static NSString *const kKeyFrequency = @"freq";

static NSString *const kKeyVersion = @"v";
static NSString *const kKeyLanes = @"lanes";
static NSString *const kKeyLabel = @"label";
static NSString *const kKeySegments = @"segs";
static NSString *const kKeyEnabled = @"on";
static NSString *const kKeySelectedSeg = @"sel";

static const NSInteger kCurrentVersion = 3;

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
  s.intensity = 0.5;
  s.frequency = 0.5;
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
  s.intensity = intensity;
  s.frequency = frequency;
  return s;
}

- (double)value {
  return _values.count > 0 ? _values[0].doubleValue : 0;
}

- (NSDictionary *)toDictionary {
  return @{
    kKeyType : @(_type),
    kKeyStart : @(_start),
    kKeyEnd : @(_end),
    kKeyValues : _values ?: @[],
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
  // Support both v2 ("val": single) and v3 ("vals": array).
  NSArray *vals = dict[kKeyValues];
  if ([vals isKindOfClass:[NSArray class]]) {
    s.values = vals;
  } else {
    NSNumber *singleVal = dict[@"val"];
    s.values = singleVal ? @[ singleVal ] : @[ @(0) ];
  }
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
  c.values = [_values copy];
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
  NSMutableArray *zeroVals =
      [NSMutableArray arrayWithCapacity:baseValues.count];
  for (NSUInteger i = 0; i < baseValues.count; i++)
    [zeroVals addObject:@(0)];

  KKTimingSegment *transIn =
      [KKTimingSegment transitionWithStart:0.0
                                       end:0.1
                                    easing:KKEasingCurveEaseOut
                                 intensity:0.5
                                 frequency:0.5
                                    values:zeroVals];
  KKTimingSegment *hold = [KKTimingSegment holdWithValues:baseValues
                                                    start:0.1
                                                      end:0.9];
  KKTimingSegment *transOut =
      [KKTimingSegment transitionWithStart:0.9
                                       end:1.0
                                    easing:KKEasingCurveEaseOut
                                 intensity:0.5
                                 frequency:0.5
                                    values:zeroVals];
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

- (id)copyWithZone:(NSZone *)zone {
  NSMutableArray *copied = [NSMutableArray arrayWithCapacity:_segments.count];
  for (KKTimingSegment *s in _segments)
    [copied addObject:[s copy]];
  KKTimingLane *c = [KKTimingLane laneWithLabel:_propertyLabel
                                       segments:copied
                                        enabled:_enabled];
  c.selectedSegment = _selectedSegment;
  return c;
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
      kKeySelectedSeg : @(lane.selectedSegment),
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
    KKTimingLane *lane = [KKTimingLane laneWithLabel:label
                                            segments:segments
                                             enabled:enabled];
    NSNumber *selNum = laneDict[kKeySelectedSeg];
    if (selNum)
      lane.selectedSegment = selNum.integerValue;
    [result addObject:lane];
  }
  return result.count ? result : nil;
}

@end
