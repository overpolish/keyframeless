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
static NSString *const kKeyHoldEffect = @"he";
static NSString *const kKeyIntensity = @"int";
static NSString *const kKeyFrequency = @"freq";
static NSString *const kKeySeed = @"seed";
static NSString *const kKeyLinked = @"link";
static NSString *const kKeyLockedSec = @"lock";
static NSString *const kKeyPathData = @"path";

static NSString *const kKeyVersion = @"v";
static NSString *const kKeyLanes = @"lanes";
static NSString *const kKeyLabel = @"label";
static NSString *const kKeySegments = @"segs";
static NSString *const kKeyEnabled = @"on";
static NSString *const kKeySelectedSeg = @"sel";
static NSString *const kKeyOscVisible = @"osc";
static NSString *const kKeyLastKnownDur = @"lkd";

static const NSInteger kCurrentVersion = 3;

@implementation KKTimingSegment (Serialization)

- (NSDictionary *)toDictionary {
  NSMutableDictionary *d = [NSMutableDictionary dictionaryWithDictionary:@{
    kKeyType : @(self.type),
    kKeyStart : @(self.start),
    kKeyEnd : @(self.end),
    kKeyValues : self.values ?: @[],
    kKeyEasing : @(self.easing),
    kKeyHoldEffect : @(self.holdEffect),
    kKeyIntensity : @(self.intensity),
    kKeyFrequency : @(self.frequency),
    kKeySeed : @(self.seed),
    kKeyLinked : @(self.linked),
    kKeyLockedSec : @(self.lockedDurationSeconds),
  }];
  if (self.pathData.length > 0)
    d[kKeyPathData] = [self.pathData base64EncodedStringWithOptions:0];
  return d;
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
  s.holdEffect = (KKHoldEffect)[dict[kKeyHoldEffect] integerValue];
  s.intensity = [dict[kKeyIntensity] doubleValue];
  s.frequency = [dict[kKeyFrequency] doubleValue];
  s.seed = (uint32_t)[dict[kKeySeed] unsignedIntegerValue];
  NSNumber *linkedNum = dict[kKeyLinked];
  s.linked = linkedNum ? linkedNum.boolValue : YES;
  s.lockedDurationSeconds = [dict[kKeyLockedSec] doubleValue];
  NSString *pathStr = dict[kKeyPathData];
  if ([pathStr isKindOfClass:[NSString class]] && pathStr.length > 0) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:pathStr
                                                       options:0];
    if (data.length > 0)
      s.pathData = data;
  }
  return s;
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
      kKeyOscVisible : @(lane.oscVisible),
      kKeyLastKnownDur : @(lane.lastKnownClipDuration),
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
    NSNumber *oscNum = laneDict[kKeyOscVisible];
    lane.oscVisible = oscNum ? oscNum.boolValue : YES;
    lane.lastKnownClipDuration = [laneDict[kKeyLastKnownDur] doubleValue];
    [result addObject:lane];
  }
  return result.count ? result : nil;
}

@end
