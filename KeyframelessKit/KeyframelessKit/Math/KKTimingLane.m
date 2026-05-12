/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimingLane.h"

BOOL KKLaneIsHiddenByCollapsedGroup(NSArray<KKTimingLane *> *lanes,
                                    NSUInteger idx) {
  if (idx >= lanes.count)
    return NO;
  NSString *key = lanes[idx].groupKey;
  if (!key)
    return NO;
  NSUInteger head = idx;
  while (head > 0 && [lanes[head - 1].groupKey isEqualToString:key])
    head--;
  return lanes[head].groupCollapsed;
}

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
  l.pluginVisible = YES;
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

- (BOOL)effectivelyVisibleInSequencer {
  return _visibleInSequencer && _pluginVisible;
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
  c.pluginVisible = _pluginVisible;
  c.lastKnownClipDuration = _lastKnownClipDuration;
  c.groupKey = [_groupKey copy];
  c.groupLabel = [_groupLabel copy];
  c.groupCollapsed = _groupCollapsed;
  c.valueComponentKinds = [_valueComponentKinds copy];
  return c;
}

@end

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
  if (!typeNum)
    return nil;
  KKTimingSegment *s = [[KKTimingSegment alloc] init];
  s.type = (KKSegmentType)typeNum.integerValue;
  s.start = [dict[kKeyStart] doubleValue];
  s.end = [dict[kKeyEnd] doubleValue];
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
    if (selNum)
      lane.selectedSegment = selNum.integerValue;
    NSNumber *oscNum = laneDict[kKeyOscVisible];
    lane.oscVisible = oscNum ? oscNum.boolValue : YES;
    NSNumber *hasOscNum = laneDict[@"hasOsc"];
    if (hasOscNum)
      lane.hasOSC = hasOscNum.boolValue;
    NSNumber *visNum = laneDict[kKeyVisibleInSeq];
    lane.visibleInSequencer = visNum ? visNum.boolValue : YES;
    NSNumber *pvisNum = laneDict[kKeyPluginVisible];
    lane.pluginVisible = pvisNum ? pvisNum.boolValue : YES;
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
