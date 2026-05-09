/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
static NSString *const kKeyVisibleInSeq = @"vis";
static NSString *const kKeyPluginVisible = @"pvis";
static NSString *const kKeyLastKnownDur = @"lkd";
static NSString *const kKeyGroupKey = @"gk";
static NSString *const kKeyGroupLabel = @"glab";
static NSString *const kKeyGroupCollapsed = @"gcol";
static NSString *const kKeyValueComponentKinds = @"kinds";

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
  if (typeNum == nil)
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
    s.values = singleVal != nil ? @[ singleVal ] : @[ @(0) ];
  }
  s.easing = (KKEasingCurve)[dict[kKeyEasing] integerValue];
  s.holdEffect = (KKHoldEffect)[dict[kKeyHoldEffect] integerValue];
  s.intensity = [dict[kKeyIntensity] doubleValue];
  s.frequency = [dict[kKeyFrequency] doubleValue];
  s.seed = (uint32_t)[dict[kKeySeed] unsignedIntegerValue];
  NSNumber *linkedNum = dict[kKeyLinked];
  s.linked = linkedNum != nil ? linkedNum.boolValue : YES;
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
    NSMutableDictionary *laneDict = [@{
      kKeyLabel : lane.propertyLabel ?: @"",
      kKeyEnabled : @(lane.enabled),
      kKeySelectedSeg : @(lane.selectedSegment),
      kKeyOscVisible : @(lane.oscVisible),
      @"hasOsc" : @(lane.hasOSC),
      kKeyVisibleInSeq : @(lane.visibleInSequencer),
      kKeyPluginVisible : @(lane.pluginVisible),
      kKeyLastKnownDur : @(lane.lastKnownClipDuration),
      kKeySegments : segsArray,
    } mutableCopy];
    if (lane.groupKey.length)
      laneDict[kKeyGroupKey] = lane.groupKey;
    if (lane.groupLabel.length)
      laneDict[kKeyGroupLabel] = lane.groupLabel;
    if (lane.groupCollapsed)
      laneDict[kKeyGroupCollapsed] = @YES;
    if (lane.valueComponentKinds.count)
      laneDict[kKeyValueComponentKinds] = lane.valueComponentKinds;
    [lanesArray addObject:laneDict];
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
    if (selNum != nil)
      lane.selectedSegment = selNum.integerValue;
    NSNumber *oscNum = laneDict[kKeyOscVisible];
    lane.oscVisible = oscNum != nil ? oscNum.boolValue : YES;
    NSNumber *hasOscNum = laneDict[@"hasOsc"];
    if (hasOscNum != nil)
      lane.hasOSC = hasOscNum.boolValue;
    NSNumber *visNum = laneDict[kKeyVisibleInSeq];
    lane.visibleInSequencer = visNum != nil ? visNum.boolValue : YES;
    NSNumber *pvisNum = laneDict[kKeyPluginVisible];
    lane.pluginVisible = pvisNum != nil ? pvisNum.boolValue : YES;
    lane.lastKnownClipDuration = [laneDict[kKeyLastKnownDur] doubleValue];
    NSString *gkRaw = laneDict[kKeyGroupKey];
    if ([gkRaw isKindOfClass:[NSString class]])
      lane.groupKey = gkRaw;
    NSString *glabRaw = laneDict[kKeyGroupLabel];
    if ([glabRaw isKindOfClass:[NSString class]])
      lane.groupLabel = glabRaw;
    lane.groupCollapsed = [laneDict[kKeyGroupCollapsed] boolValue];
    NSArray *kindsRaw = laneDict[kKeyValueComponentKinds];
    if ([kindsRaw isKindOfClass:[NSArray class]] && kindsRaw.count) {
      NSMutableArray<NSNumber *> *kinds =
          [NSMutableArray arrayWithCapacity:kindsRaw.count];
      for (id v in kindsRaw)
        if ([v isKindOfClass:[NSNumber class]])
          [kinds addObject:v];
      if (kinds.count)
        lane.valueComponentKinds = kinds;
    }
    [result addObject:lane];
  }
  // Return the (possibly empty) result. An empty parsed lanes array is a
  // legitimate state — distinct from nil which signals invalid/unparseable
  // JSON. Returning nil for empty caused KKSyncFromParams to skip its
  // sequencer view push when reconciliation drops the last lane.
  return result;
}

@end

BOOL KKIsHTHTransition(KKTimingLane *lane, NSInteger segIdx) {
  if (!lane || segIdx <= 0 || segIdx >= (NSInteger)lane.segments.count - 1)
    return NO;
  KKTimingSegment *seg = lane.segments[segIdx];
  if (seg.type != KKSegmentTypeTransition)
    return NO;
  return lane.segments[segIdx - 1].type == KKSegmentTypeHold &&
         lane.segments[segIdx + 1].type == KKSegmentTypeHold;
}

/// Expands the lane's slot-level `valueComponentKinds` into a per-scalar
/// kinds array. Color → 3 entries of Color, Point → 2 entries of Point,
/// Gradient → 0 (variable; HTH normalization treats as non-Bool), Bool/
/// Float → 1 each.
static NSArray<NSNumber *> *_KKExpandedLaneKinds(KKTimingLane *lane) {
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (NSNumber *k in lane.valueComponentKinds) {
    NSUInteger n = 1;
    switch ((KKAnimatableParamKind)k.integerValue) {
    case KKAnimatableParamKindColor:
      n = 3;
      break;
    case KKAnimatableParamKindPoint:
      n = 2;
      break;
    case KKAnimatableParamKindGradient:
    case KKAnimatableParamKindMorph:
      n = 0;
      break;
    default:
      n = 1;
      break;
    }
    for (NSUInteger i = 0; i < n; i++)
      [out addObject:k];
  }
  return out;
}

void KKApplyHTHNormalizationInPlace(NSMutableArray<KKTimingLane *> *lanes) {
  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    NSArray<NSNumber *> *kinds = _KKExpandedLaneKinds(lane);
    NSMutableArray<KKTimingSegment *> *mSegs = nil;
    for (NSUInteger si = 1; si + 1 < lane.segments.count; si++) {
      if (!KKIsHTHTransition(lane, (NSInteger)si))
        continue;
      KKTimingSegment *prev = lane.segments[si - 1];
      KKTimingSegment *t = lane.segments[si];

      // Build the merged values array: prev.values for non-Bool scalars,
      // t.values for Bool scalars (so per-segment step toggles persist).
      NSUInteger valCount = MIN(prev.values.count, t.values.count);
      NSMutableArray<NSNumber *> *merged =
          [NSMutableArray arrayWithCapacity:valCount];
      BOOL anyDifferent = NO;
      for (NSUInteger i = 0; i < valCount; i++) {
        BOOL keepOwn = (i < kinds.count &&
                        kinds[i].integerValue == KKAnimatableParamKindBool);
        NSNumber *src = keepOwn ? t.values[i] : prev.values[i];
        [merged addObject:src];
        if (![src isEqualToNumber:t.values[i]])
          anyDifferent = YES;
      }
      // Carry over any extra trailing values from prev (length mismatch
      // shouldn't happen in practice but stay defensive).
      for (NSUInteger i = valCount; i < prev.values.count; i++) {
        [merged addObject:prev.values[i]];
        anyDifferent = YES;
      }
      if (!anyDifferent && t.values.count == prev.values.count)
        continue;

      if (!mSegs)
        mSegs = [lane.segments mutableCopy];
      KKTimingSegment *m = [mSegs[si] copy];
      m.values = [merged copy];
      mSegs[si] = m;
    }
    if (mSegs) {
      KKTimingLane *mLane = [lane copy];
      mLane.segments = mSegs;
      lanes[li] = mLane;
    }
  }
}
