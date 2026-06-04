/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimingStage.h"

// ---------------------------------------------------------------------------
// KKInterval
// ---------------------------------------------------------------------------

@implementation KKInterval

- (instancetype)init {
  self = [super init];
  if (self) {
    _curve = KKIntervalCurveEaseInOut;
    _intensity = 1.0;
    _frequency = 0.5;
    _modulation = KKIntervalModulationNone;
    _modulationIntensity = 1.0;
    _modulationFrequency = 1.0;
    _modulationLinked = YES;
    // Default unlinked: an interval freshly created in Advanced (new keypose /
    // property) starts unlinked. Basic explicitly links its Hold pair when it
    // builds the hold (see KKTimelineBasicView+Model `_rebuiltLane`).
    _endpointsLinked = NO;
  }
  return self;
}

- (id)copyWithZone:(NSZone *)zone {
  KKInterval *c = [[[self class] allocWithZone:zone] init];
  c.curve = _curve;
  c.intensity = _intensity;
  c.frequency = _frequency;
  c.modulation = _modulation;
  c.modulationIntensity = _modulationIntensity;
  c.modulationFrequency = _modulationFrequency;
  c.modulationSeed = _modulationSeed;
  c.modulationLinked = _modulationLinked;
  c.modulationComponents = [_modulationComponents copy];
  c.lockedSeconds = _lockedSeconds;
  c.endpointsLinked = _endpointsLinked;
  c.holdsFlat = _holdsFlat;
  c.pathData = _pathData;
  c.userProperties = [_userProperties copy];
  return c;
}

- (BOOL)userBoolForKey:(NSString *)key default:(BOOL)def {
  id v = _userProperties[key];
  return [v isKindOfClass:[NSNumber class]] ? [v boolValue] : def;
}

- (void)setUserBool:(BOOL)value forKey:(NSString *)key {
  [self setUserValue:@(value) forKey:key];
}

- (double)userDoubleForKey:(NSString *)key default:(double)def {
  id v = _userProperties[key];
  return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : def;
}

- (void)setUserDouble:(double)value forKey:(NSString *)key {
  [self setUserValue:@(value) forKey:key];
}

- (id)userValueForKey:(NSString *)key {
  return _userProperties[key];
}

- (void)setUserValue:(id)value forKey:(NSString *)key {
  NSMutableDictionary *m = _userProperties ? [_userProperties mutableCopy]
                                           : [NSMutableDictionary dictionary];
  if (value)
    m[key] = value;
  else
    [m removeObjectForKey:key];
  _userProperties = m.count ? [m copy] : nil;
}

- (NSDictionary *)toDictionary {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  d[@"curve"] = @(_curve);
  d[@"intensity"] = @(_intensity);
  d[@"frequency"] = @(_frequency);
  d[@"modulation"] = @(_modulation);
  d[@"modulation_intensity"] = @(_modulationIntensity);
  d[@"modulation_frequency"] = @(_modulationFrequency);
  d[@"modulation_seed"] = @(_modulationSeed);
  d[@"modulation_linked"] = @(_modulationLinked);
  if (_modulationComponents) {
    NSMutableArray<NSNumber *> *idx =
        [NSMutableArray arrayWithCapacity:_modulationComponents.count];
    [_modulationComponents
        enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
          [idx addObject:@(i)];
        }];
    d[@"modulation_components"] = idx;
  }
  d[@"locked_seconds"] = @(_lockedSeconds);
  d[@"endpoints_linked"] = @(_endpointsLinked);
  if (_holdsFlat)
    d[@"holds_flat"] = @(_holdsFlat);
  if (_pathData) {
    d[@"path_data"] = [_pathData base64EncodedStringWithOptions:0];
  }
  if (_userProperties.count)
    d[@"user_properties"] = _userProperties;
  return d;
}

+ (nullable instancetype)fromDictionary:(NSDictionary *)d {
  if (![d isKindOfClass:[NSDictionary class]])
    return nil;
  KKInterval *i = [[KKInterval alloc] init];
  if (d[@"curve"])
    i.curve = [d[@"curve"] integerValue];
  if (d[@"intensity"])
    i.intensity = [d[@"intensity"] doubleValue];
  if (d[@"frequency"])
    i.frequency = [d[@"frequency"] doubleValue];
  if (d[@"modulation"])
    i.modulation = [d[@"modulation"] integerValue];
  if (d[@"modulation_intensity"])
    i.modulationIntensity = [d[@"modulation_intensity"] doubleValue];
  if (d[@"modulation_frequency"])
    i.modulationFrequency = [d[@"modulation_frequency"] doubleValue];
  if (d[@"modulation_seed"])
    i.modulationSeed = [d[@"modulation_seed"] unsignedIntValue];
  if (d[@"modulation_linked"])
    i.modulationLinked = [d[@"modulation_linked"] boolValue];
  if ([d[@"modulation_components"] isKindOfClass:[NSArray class]]) {
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (NSNumber *n in d[@"modulation_components"])
      if ([n isKindOfClass:[NSNumber class]])
        [set addIndex:n.unsignedIntegerValue];
    i.modulationComponents = set;
  }
  if (d[@"locked_seconds"])
    i.lockedSeconds = [d[@"locked_seconds"] doubleValue];
  if (d[@"endpoints_linked"])
    i.endpointsLinked = [d[@"endpoints_linked"] boolValue];
  if (d[@"holds_flat"])
    i.holdsFlat = [d[@"holds_flat"] boolValue];
  NSString *b64 = d[@"path_data"];
  if (b64)
    i.pathData = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
  id up = d[@"user_properties"];
  if ([up isKindOfClass:[NSDictionary class]])
    i.userProperties = up;
  return i;
}

@end

// ---------------------------------------------------------------------------
// KKKeyPose
// ---------------------------------------------------------------------------

@implementation KKKeyPose

+ (instancetype)keyposeAtTime:(double)time
                       values:(NSArray<NSNumber *> *)values {
  KKKeyPose *kp = [[KKKeyPose alloc] init];
  kp.time = time;
  kp.values = values;
  kp.outgoing = [[KKInterval alloc] init];
  return kp;
}

- (id)copyWithZone:(NSZone *)zone {
  KKKeyPose *c = [[[self class] allocWithZone:zone] init];
  c.time = _time;
  c.values = [_values copy];
  c.outgoing = [_outgoing copy];
  c.spatialSmooth = _spatialSmooth;
  c.inHandle = [_inHandle copy];
  c.outHandle = [_outHandle copy];
  return c;
}

- (instancetype)keyposeBySettingTime:(double)time {
  KKKeyPose *c = [self copy];
  c.time = time;
  return c;
}

- (NSDictionary *)toDictionary {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  d[@"time"] = @(_time);
  d[@"values"] = _values;
  if (_outgoing)
    d[@"outgoing"] = [_outgoing toDictionary];
  // Only serialise spatial-curve fields when set, so legacy blobs (and
  // straight-line lanes) stay byte-identical.
  if (_spatialSmooth)
    d[@"spatial_smooth"] = @YES;
  if (_inHandle)
    d[@"in_handle"] = _inHandle;
  if (_outHandle)
    d[@"out_handle"] = _outHandle;
  return d;
}

+ (nullable instancetype)fromDictionary:(NSDictionary *)d {
  if (![d isKindOfClass:[NSDictionary class]])
    return nil;
  KKKeyPose *kp = [[KKKeyPose alloc] init];
  kp.time = [d[@"time"] doubleValue];
  kp.values = d[@"values"] ?: @[];
  NSDictionary *out = d[@"outgoing"];
  kp.outgoing = out ? [KKInterval fromDictionary:out] : nil;
  kp.spatialSmooth = [d[@"spatial_smooth"] boolValue];
  id ih = d[@"in_handle"];
  if ([ih isKindOfClass:[NSArray class]])
    kp.inHandle = ih;
  id oh = d[@"out_handle"];
  if ([oh isKindOfClass:[NSArray class]])
    kp.outHandle = oh;
  return kp;
}

@end

// ---------------------------------------------------------------------------
// KKLane
// ---------------------------------------------------------------------------

@interface KKLane ()
@property(nonatomic, readwrite) NSUUID *laneID;
@end

@implementation KKLane

+ (instancetype)laneWithLabel:(NSString *)label {
  KKLane *l = [[KKLane alloc] init];
  l.laneID = [NSUUID UUID];
  l.label = label;
  l.enabled = YES;
  l.keyposes = @[];
  return l;
}

- (void)insertKeypose:(KKKeyPose *)keypose {
  NSMutableArray *kps = [_keyposes mutableCopy];
  NSUInteger idx = [kps
      indexOfObjectPassingTest:^BOOL(KKKeyPose *kp, NSUInteger i, BOOL *stop) {
        return kp.time > keypose.time;
      }];
  if (idx == NSNotFound) {
    [kps addObject:keypose];
  } else {
    [kps insertObject:keypose atIndex:idx];
  }
  self.keyposes = kps;
}

- (void)removeKeyposeAtIndex:(NSUInteger)index {
  NSMutableArray *kps = [_keyposes mutableCopy];
  [kps removeObjectAtIndex:index];
  self.keyposes = kps;
}

- (id)copyWithZone:(NSZone *)zone {
  KKLane *c = [[[self class] allocWithZone:zone] init];
  c.laneID = _laneID;
  c.label = [_label copy];
  c.groupKey = [_groupKey copy];
  c.enabled = _enabled;
  c.valueType = _valueType;
  c.componentMin = [_componentMin copy];
  c.componentMax = [_componentMax copy];
  c.componentUnits = [_componentUnits copy];
  c.componentLabels = [_componentLabels copy];
  c.componentLabelColors = [_componentLabelColors copy];
  c.keyposes = [[NSArray alloc] initWithArray:_keyposes copyItems:YES];
  c.lastKnownClipDuration = _lastKnownClipDuration;
  c.holdShape = _holdShape;
  c.spatialCurvable = _spatialCurvable;
  c.aspectLinkable = _aspectLinkable;
  c.aspectLinked = _aspectLinked;
  c.integerValued = _integerValued;
  return c;
}

- (NSDictionary *)toDictionary {
  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  d[@"id"] = _laneID.UUIDString;
  d[@"label"] = _label;
  if (_groupKey)
    d[@"group_key"] = _groupKey;
  d[@"enabled"] = @(_enabled);
  d[@"value_type"] = @(_valueType);
  if (_componentMin)
    d[@"component_min"] = _componentMin;
  if (_componentMax)
    d[@"component_max"] = _componentMax;
  if (_componentUnits)
    d[@"component_units"] = _componentUnits;
  if (_componentLabels)
    d[@"component_labels"] = _componentLabels;
  d[@"keyposes"] = [_keyposes valueForKey:@"toDictionary"];
  d[@"last_known_clip_duration"] = @(_lastKnownClipDuration);
  if (_holdShape != KKLaneHoldShapeAuto)
    d[@"hold_shape"] = @(_holdShape);
  if (_spatialCurvable)
    d[@"spatial_curvable"] = @YES;
  if (_aspectLinkable)
    d[@"aspect_linkable"] = @YES;
  if (_aspectLinked)
    d[@"aspect_linked"] = @YES;
  if (_integerValued)
    d[@"integer_valued"] = @YES;
  return d;
}

+ (nullable instancetype)fromDictionary:(NSDictionary *)d {
  if (![d isKindOfClass:[NSDictionary class]])
    return nil;
  KKLane *l = [[KKLane alloc] init];
  NSString *uuidStr = d[@"id"];
  l.laneID =
      uuidStr ? [[NSUUID alloc] initWithUUIDString:uuidStr] : [NSUUID UUID];
  l.label = d[@"label"] ?: @"";
  l.groupKey = d[@"group_key"];
  l.enabled = d[@"enabled"] ? [d[@"enabled"] boolValue] : YES;
  if (d[@"value_type"])
    l.valueType = (KKLaneValueType)[d[@"value_type"] integerValue];
  if ([d[@"component_min"] isKindOfClass:[NSArray class]])
    l.componentMin = d[@"component_min"];
  if ([d[@"component_max"] isKindOfClass:[NSArray class]])
    l.componentMax = d[@"component_max"];
  if ([d[@"component_units"] isKindOfClass:[NSArray class]])
    l.componentUnits = d[@"component_units"];
  if ([d[@"component_labels"] isKindOfClass:[NSArray class]])
    l.componentLabels = d[@"component_labels"];
  l.lastKnownClipDuration = [d[@"last_known_clip_duration"] doubleValue];
  if (d[@"hold_shape"])
    l.holdShape = (KKLaneHoldShape)[d[@"hold_shape"] integerValue];
  l.spatialCurvable = [d[@"spatial_curvable"] boolValue];
  l.aspectLinkable = [d[@"aspect_linkable"] boolValue];
  l.aspectLinked = [d[@"aspect_linked"] boolValue];
  l.integerValued = [d[@"integer_valued"] boolValue];
  NSArray *rawKps = d[@"keyposes"];
  if ([rawKps isKindOfClass:[NSArray class]]) {
    NSMutableArray *kps = [NSMutableArray arrayWithCapacity:rawKps.count];
    for (NSDictionary *kpd in rawKps) {
      KKKeyPose *kp = [KKKeyPose fromDictionary:kpd];
      if (kp)
        [kps addObject:kp];
    }
    l.keyposes = kps;
  } else {
    l.keyposes = @[];
  }
  return l;
}

@end

KKTimeline *KKTimelineSettingSpatialSmooth(KKTimeline *timeline,
                                           NSString *label, double frac,
                                           BOOL on) {
  KKTimeline *t = [timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].label isEqualToString:label])
      continue;
    KKLane *nl = [lanes[i] copy];
    NSArray<KKKeyPose *> *kps = nl.keyposes;
    if (kps.count == 0)
      return nil;
    NSInteger best = 0;
    double bestDt = fabs(kps[0].time - frac);
    for (NSInteger j = 1; j < (NSInteger)kps.count; j++) {
      double dt = fabs(kps[j].time - frac);
      if (dt < bestDt) {
        bestDt = dt;
        best = j;
      }
    }
    if (kps[best].spatialSmooth == on)
      return nil; // already in that state - no commit, no undo entry
    NSMutableArray<KKKeyPose *> *mkps = [kps mutableCopy];
    KKKeyPose *nk = [mkps[best] copy];
    nk.spatialSmooth = on;
    mkps[best] = nk;
    nl.keyposes = mkps;
    lanes[i] = nl;
    t.lanes = lanes;
    return t;
  }
  return nil;
}

KKTimeline *KKTimelineSettingAspectLinked(KKTimeline *timeline, NSString *label,
                                          BOOL on) {
  KKTimeline *t = [timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].label isEqualToString:label])
      continue;
    if (lanes[i].aspectLinked == on)
      return nil; // already in that state - no commit, no undo entry
    KKLane *nl = [lanes[i] copy];
    nl.aspectLinked = on;
    lanes[i] = nl;
    t.lanes = lanes;
    return t;
  }
  return nil;
}

NSInteger KKLaneNearestKeyposeIndex(KKLane *lane, double frac) {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  if (kps.count == 0)
    return NSNotFound;
  NSInteger best = 0;
  double bestDt = fabs(kps[0].time - frac);
  for (NSInteger j = 1; j < (NSInteger)kps.count; j++) {
    double dt = fabs(kps[j].time - frac);
    if (dt < bestDt) {
      bestDt = dt;
      best = j;
    }
  }
  return best;
}

KKLane *KKLaneBySettingValuesNearestFraction(KKLane *lane, double frac,
                                             NSArray<NSNumber *> *values) {
  KKLane *nl = [lane copy];
  NSArray<KKKeyPose *> *kps = nl.keyposes;
  if (kps.count == 0) {
    nl.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:values] ];
    return nl;
  }
  NSInteger best = KKLaneNearestKeyposeIndex(nl, frac);
  NSMutableArray<KKKeyPose *> *mkps = [kps mutableCopy];
  // Copy-preserve (not rebuild) so spatialSmooth + in/out handles + outgoing
  // survive a value edit - the "edit resets the path to linear" class of bug.
  KKKeyPose *nk = [mkps[best] copy];
  nk.values = values;
  mkps[best] = nk;
  // Hold-link propagation: a hold whose endpoints are linked shares one value,
  // so the linked neighbour on either side has to track the edit too.
  if (best + 1 < (NSInteger)mkps.count && nk.outgoing.endpointsLinked) {
    KKKeyPose *np = [mkps[best + 1] copy];
    np.values = values;
    mkps[best + 1] = np;
  }
  if (best > 0 && mkps[best - 1].outgoing.endpointsLinked) {
    KKKeyPose *np = [mkps[best - 1] copy];
    np.values = values;
    mkps[best - 1] = np;
  }
  nl.keyposes = mkps;
  return nl;
}

KKTimeline *
KKTimelineSettingValuesNearestFraction(KKTimeline *timeline, NSString *label,
                                       double frac,
                                       NSArray<NSNumber *> *values) {
  KKTimeline *t = [timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if (![lanes[i].label isEqualToString:label])
      continue;
    lanes[i] = KKLaneBySettingValuesNearestFraction(lanes[i], frac, values);
    t.lanes = lanes;
    return t;
  }
  return nil;
}

// ---------------------------------------------------------------------------
// KKLaneGroup
// ---------------------------------------------------------------------------

@implementation KKLaneGroup

+ (instancetype)groupWithKey:(NSString *)key label:(NSString *)label {
  KKLaneGroup *g = [[KKLaneGroup alloc] init];
  g.key = key;
  g.label = label;
  return g;
}

- (id)copyWithZone:(NSZone *)zone {
  KKLaneGroup *c = [[[self class] allocWithZone:zone] init];
  c.key = [_key copy];
  c.label = [_label copy];
  return c;
}

- (NSDictionary *)toDictionary {
  return @{@"key" : _key, @"label" : _label};
}

+ (nullable instancetype)fromDictionary:(NSDictionary *)d {
  if (![d isKindOfClass:[NSDictionary class]])
    return nil;
  return [KKLaneGroup groupWithKey:d[@"key"] ?: @"" label:d[@"label"] ?: @""];
}

@end

// ---------------------------------------------------------------------------
// KKTimeline
// ---------------------------------------------------------------------------

@implementation KKTimeline

+ (instancetype)timeline {
  KKTimeline *t = [[KKTimeline alloc] init];
  t.lanes = @[];
  t.groups = @[];
  return t;
}

- (id)copyWithZone:(NSZone *)zone {
  KKTimeline *c = [[[self class] allocWithZone:zone] init];
  c.lanes = [[NSArray alloc] initWithArray:_lanes copyItems:YES];
  c.groups = [[NSArray alloc] initWithArray:_groups copyItems:YES];
  c.paramOrder = _paramOrder;
  return c;
}

@end

// ---------------------------------------------------------------------------
// KKTimelineRebalanced
// ---------------------------------------------------------------------------

KKTimeline *KKTimelineRebalanced(KKTimeline *timeline, double oldDuration,
                                 double newDuration) {
  if (oldDuration <= 0 || newDuration <= 0 || oldDuration == newDuration)
    return timeline;

  KKTimeline *result = [timeline copy];
  NSMutableArray<KKLane *> *newLanes =
      [NSMutableArray arrayWithCapacity:result.lanes.count];

  for (KKLane *lane in result.lanes) {
    KKLane *newLane = [lane copy];
    newLane.lastKnownClipDuration = newDuration;

    NSArray<KKKeyPose *> *kps = lane.keyposes;
    if (kps.count < 2) {
      [newLanes addObject:newLane];
      continue;
    }

    // Compute desired fractional width for each interval.
    NSUInteger intervalCount = kps.count - 1;
    NSMutableArray<NSNumber *> *targetFracs =
        [NSMutableArray arrayWithCapacity:intervalCount];
    double totalLocked = 0.0;
    double totalUnlockedFrac = 0.0;

    for (NSUInteger i = 0; i < intervalCount; i++) {
      KKKeyPose *a = kps[i];
      KKKeyPose *b = kps[i + 1];
      double frac = b.time - a.time;
      double lockedSecs = a.outgoing.lockedSeconds;
      if (lockedSecs > 0) {
        double desiredFrac = lockedSecs / newDuration;
        [targetFracs addObject:@(desiredFrac)];
        totalLocked += desiredFrac;
      } else {
        [targetFracs addObject:@(frac)];
        totalUnlockedFrac += frac;
      }
    }

    // If locked intervals overflow, scale everything proportionally.
    NSMutableArray<NSNumber *> *finalFracs =
        [NSMutableArray arrayWithCapacity:intervalCount];
    double totalSpan = kps.lastObject.time - kps.firstObject.time;
    double available = totalSpan;

    if (totalLocked > available) {
      double scale = available / totalLocked;
      for (NSUInteger i = 0; i < intervalCount; i++) {
        KKKeyPose *a = kps[i];
        if (a.outgoing.lockedSeconds > 0) {
          [finalFracs addObject:@([targetFracs[i] doubleValue] * scale)];
        } else {
          [finalFracs addObject:@(0.0)];
        }
      }
    } else {
      double unlockedAvailable = available - totalLocked;
      for (NSUInteger i = 0; i < intervalCount; i++) {
        KKKeyPose *a = kps[i];
        if (a.outgoing.lockedSeconds > 0) {
          [finalFracs addObject:targetFracs[i]];
        } else {
          double frac = totalUnlockedFrac > 0
                            ? [targetFracs[i] doubleValue] / totalUnlockedFrac *
                                  unlockedAvailable
                            : 0.0;
          [finalFracs addObject:@(frac)];
        }
      }
    }

    // Rebuild keypose times from the first keypose's position.
    NSMutableArray<KKKeyPose *> *newKps =
        [NSMutableArray arrayWithCapacity:kps.count];
    double t = kps.firstObject.time;
    KKKeyPose *firstCopy = [kps.firstObject copy];
    firstCopy.time = t;
    [newKps addObject:firstCopy];
    for (NSUInteger i = 0; i < intervalCount; i++) {
      t += [finalFracs[i] doubleValue];
      KKKeyPose *copy = [kps[i + 1] copy];
      copy.time = MIN(1.0, MAX(0.0, t));
      [newKps addObject:copy];
    }
    newLane.keyposes = newKps;
    [newLanes addObject:newLane];
  }

  result.lanes = newLanes;
  return result;
}

// ---------------------------------------------------------------------------
// Serialization
// ---------------------------------------------------------------------------

@implementation KKTimeline (Serialization)

+ (nullable NSString *)jsonFromTimeline:(KKTimeline *)timeline {
  NSMutableArray *lanesArr =
      [NSMutableArray arrayWithCapacity:timeline.lanes.count];
  for (KKLane *lane in timeline.lanes) {
    [lanesArr addObject:[lane toDictionary]];
  }
  NSMutableArray *groupsArr =
      [NSMutableArray arrayWithCapacity:timeline.groups.count];
  for (KKLaneGroup *group in timeline.groups) {
    [groupsArr addObject:[group toDictionary]];
  }
  NSMutableDictionary *root = [@{
    @"version" : @1,
    @"lanes" : lanesArr,
    @"groups" : groupsArr,
  } mutableCopy];
  if (timeline.paramOrder.count)
    root[@"paramOrder"] = timeline.paramOrder;
  NSError *err;
  NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                 options:0
                                                   error:&err];
  if (!data)
    return nil;
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

+ (nullable KKTimeline *)timelineFromJSON:(NSString *)json {
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  if (!data)
    return nil;
  NSError *err;
  NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data
                                                       options:0
                                                         error:&err];
  if (![root isKindOfClass:[NSDictionary class]])
    return nil;

  KKTimeline *timeline = [KKTimeline timeline];

  NSArray *lanesArr = root[@"lanes"];
  if ([lanesArr isKindOfClass:[NSArray class]]) {
    NSMutableArray *lanes = [NSMutableArray arrayWithCapacity:lanesArr.count];
    for (NSDictionary *d in lanesArr) {
      KKLane *lane = [KKLane fromDictionary:d];
      if (lane)
        [lanes addObject:lane];
    }
    timeline.lanes = lanes;
  }

  NSArray *groupsArr = root[@"groups"];
  if ([groupsArr isKindOfClass:[NSArray class]]) {
    NSMutableArray *groups = [NSMutableArray arrayWithCapacity:groupsArr.count];
    for (NSDictionary *d in groupsArr) {
      KKLaneGroup *group = [KKLaneGroup fromDictionary:d];
      if (group)
        [groups addObject:group];
    }
    timeline.groups = groups;
  }

  NSArray *orderArr = root[@"paramOrder"];
  if ([orderArr isKindOfClass:[NSArray class]]) {
    NSMutableArray<NSString *> *order =
        [NSMutableArray arrayWithCapacity:orderArr.count];
    for (id label in orderArr)
      if ([label isKindOfClass:[NSString class]])
        [order addObject:label];
    timeline.paramOrder = order;
  }

  return timeline;
}

@end

NSArray<NSString *> *KKLaneComponentLabels(KKLane *lane) {
  if (!lane)
    return nil;
  if (lane.componentLabels.count)
    return lane.componentLabels;
  switch (lane.valueType) {
  case KKLaneValueTypeCrop:
    return @[ @"W", @"H", @"X", @"Y" ];
  case KKLaneValueTypeColor:
    return @[ @"R", @"G", @"B", @"A" ];
  case KKLaneValueTypeFloat:
  case KKLaneValueTypeNormalized:
    return nil;
  case KKLaneValueTypeGradient:
  case KKLaneValueTypeGeneric:
  default: {
    NSUInteger n = lane.keyposes.firstObject.values.count;
    if (n <= 1)
      return nil;
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++)
      [out
          addObject:[NSString stringWithFormat:@"%lu", (unsigned long)(i + 1)]];
    return out;
  }
  }
}
