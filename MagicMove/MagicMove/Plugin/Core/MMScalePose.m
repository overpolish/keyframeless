/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMScalePose.h"
#import "Constants.h"
#import <math.h>

@implementation MMScalePose
- (instancetype)poseByReplacingTiming:(MMPoseTiming *)timing {
  if (!timing) return nil;
  MMScalePose *copy=[[MMScalePose alloc] initWithX:self.x y:self.y authored:self.authored easing:self.easing addedMotion:self.addedMotion];
  copy->_timing=timing;
  return copy;
}
+ (BOOL)supportsSecureCoding {
  return YES;
}
- (instancetype)initWithX:(double)x y:(double)y authored:(BOOL)authored {
  return [self initWithX:x
                       y:y
                authored:authored
                  easing:MTEasingSmooth
             addedMotion:MTAddedMotionNone];
}
- (instancetype)initWithX:(double)x
                        y:(double)y
                 authored:(BOOL)authored
                   easing:(MTEasing)easing
              addedMotion:(MTAddedMotion)motion {
  if (!isfinite(x) || !isfinite(y) || easing < MTEasingSmooth ||
      easing > MTEasingEaseOut || motion < MTAddedMotionNone ||
      motion > MTAddedMotionHandheld)
    return nil;
  if ((self = [super init])) {
    _x = x;
    _y = y;
    _authored = authored; _timing=[MMPoseTiming new];
    _easing = easing;
    _addedMotion = motion;
  }
  return self;
}
- (instancetype)initWithCoder:(NSCoder *)c {
  self = [self initWithX:[c decodeDoubleForKey:@"x"]
                       y:[c decodeDoubleForKey:@"y"]
                authored:[c decodeBoolForKey:@"authored"]
                  easing:(MTEasing)[c decodeIntegerForKey:@"easing"]
             addedMotion:(MTAddedMotion)[c decodeIntegerForKey:@"addedMotion"]];
  if (!self) return nil;
  if ([c containsValueForKey:@"timing"]) {
    MMPoseTiming *timing=[c decodeObjectOfClass:MMPoseTiming.class forKey:@"timing"];
    if (!timing) return nil;
    _timing=timing;
  }
  return self;
}
- (void)encodeWithCoder:(NSCoder *)c {
  [c encodeObject:self.timing forKey:@"timing"];
  [c encodeDouble:_x forKey:@"x"];
  [c encodeDouble:_y forKey:@"y"];
  [c encodeBool:_authored forKey:@"authored"];
  [c encodeInteger:_easing forKey:@"easing"];
  [c encodeInteger:_addedMotion forKey:@"addedMotion"];
}
- (id)copyWithZone:(NSZone *)zone {
  return self;
}
- (BOOL)isEqual:(id)o {
  return [o isKindOfClass:MMScalePose.class] && [self.timing isEqual:[o timing]] && _x == [o x] && _y == [o y] &&
         _authored == [o authored] && _easing == [o easing] &&
         _addedMotion == [o addedMotion];
}
- (NSUInteger)hash {
  return self.timing.hash ^ @(_x).hash ^ @(_y).hash ^ (NSUInteger)_authored ^
         ((NSUInteger)_easing << 8) ^ ((NSUInteger)_addedMotion << 16);
}
- (NSObject<NSSecureCoding, NSCopying> *)
    interpolateBetween:(NSObject<NSSecureCoding, NSCopying> *)rightValue
            withWeight:(float)weight {
  if (![rightValue isKindOfClass:MMScalePose.class] || !isfinite(weight))
    return self;
  MMScalePose *r = (MMScalePose *)rightValue;
  double w = fmax(0, fmin(1, weight));
  return [[[MMScalePose alloc] initWithX:_x + (r.x - _x) * w
                                      y:_y + (r.y - _y) * w
                               authored:_authored || r.authored
                                 easing:w >= 1 ? r.easing : _easing
                            addedMotion:w >= 1 ? r.addedMotion : _addedMotion] poseByReplacingTiming:(w>0 && w<1) ? [self.timing timingByReplacingLinkID:@""]:(w>=1 ? r.timing:self.timing)];
}
@end

static NSError *MMScaleError(NSError **error) {
  NSError *e = [NSError errorWithDomain:FxPlugErrorDomain
                                   code:kFxError_InvalidParameter
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to read scale pose keyframes"
                               }];
  if (error)
    *error = e;
  return e;
}
static MMScalePose *MMScaleValue(id<FxParameterRetrievalAPI_v6> get, CMTime t,
                                 BOOL *missing) {
  NSObject<NSSecureCoding, NSCopying> *v = nil;
  BOOL ok = [get getCustomParameterValue:&v
                           fromParameter:MMScaleControls
                                  atTime:t];
  if (!ok)
    return nil;
  if (!v) {
    if (missing)
      *missing = YES;
    return missing ? [[MMScalePose alloc] initWithX:100 y:100 authored:NO]
                   : nil;
  }
  if ([v isKindOfClass:MMScalePose.class])
    return (MMScalePose *)v;
  return nil;
}
static NSArray *MMScaleEntries(id<PROAPIAccessing> manager, CMTime time,
                               NSError **error) {
  if (!CMTIME_IS_NUMERIC(time)) {
    MMScaleError(error);
    return nil;
  }
  id<FxParameterRetrievalAPI_v6> get =
      [manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxKeyframeAPI_v3> keys =
      [manager apiForProtocol:@protocol(FxKeyframeAPI_v3)];
  if (!get || !keys) {
    MMScaleError(error);
    return nil;
  }
  // Older effect instances have no custom scale blob. Probe the value first so
  // they remain on the legacy scalar path without enumerating a new lane.
  BOOL missing = NO;
  MMScalePose *probe = MMScaleValue(get, time, &missing);
  if (!probe) {
    MMScaleError(error);
    return nil;
  }
  if (missing)
    return @[ @{@"pose" : probe} ];
  NSUInteger n = 0;
  NSError *e = [keys keyframeCount:&n
                      forParameter:MMScaleControls
                        andChannel:0];
  if (e) {
    if (error)
      *error = e;
    return nil;
  }
  if (!n)
    return @[ @{@"pose" : probe} ];
  NSMutableArray *a = [NSMutableArray arrayWithCapacity:n];
  for (NSUInteger i = 0; i < n; i++) {
    FxKeyframe k;
    FxInitKeyframe(k, kFxKeyframe_CurrentVersion);
    e = [keys keyframe:&k forParameter:MMScaleControls channel:0 andIndex:i];
    if (e) {
      if (error)
        *error = e;
      return nil;
    }
    MMScalePose *p = MMScaleValue(get, k.time, NULL);
    if (!p || !CMTIME_IS_NUMERIC(k.time)) {
      MMScaleError(error);
      return nil;
    }
    [a addObject:@{
      @"time" : @(CMTimeGetSeconds(k.time)),
      @"pose" : p,
      @"nativeTime" : [NSValue valueWithBytes:&k.time objCType:@encode(CMTime)],
      @"nativeKey" : [NSValue valueWithBytes:&k objCType:@encode(FxKeyframe)]
    }];
  }
  [a sortUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
    return [x[@"time"] compare:y[@"time"]];
  }];
  return [a copy];
}
static MMScalePose *MMScaleSample(NSArray *e, CMTime t, BOOL *active,
                                  NSError **error) {
  *active = NO;
  if (!e.count || !CMTIME_IS_NUMERIC(t)) {
    MMScaleError(error);
    return nil;
  }
  if (e.count == 1 && !e[0][@"time"]) {
    MMScalePose *p = e[0][@"pose"];
    *active = p.authored;
    return p;
  }
  NSUInteger n = e.count;
  NSMutableData *valueStorage =
      [NSMutableData dataWithLength:n * 2 * sizeof(double)];
  NSMutableData *destinationStorage =
      [NSMutableData dataWithLength:n * sizeof(MTDestination)];
  double *vals = valueStorage.mutableBytes;
  MTDestination *ds = destinationStorage.mutableBytes;
  double mins[] = {0, 0}, maxs[] = {400, 400};
  double start = [e[0][@"time"] doubleValue];
  for (NSUInteger i = 0; i < n; i++) {
    MMScalePose *p = e[i][@"pose"];
    vals[i * 2] = p.x;
    vals[i * 2 + 1] = p.y;
    ds[i] = (MTDestination){
        .arrival = [e[i][@"time"] doubleValue] - start,
        .duration = (p.timing.available && i > 0
                         ? [e[i][@"time"] doubleValue] - [e[i-1][@"time"] doubleValue]
                         : p.timing.duration),
        .values = &vals[i * 2], .easing = p.easing,
        .addedMotion = p.addedMotion, .modulationMins = mins,
        .modulationMaxs = maxs, .modulationRangeCount = 2,
        .customMotion = true, .customMotionComponents = true, .motionAmount = p.timing.amount,
        .motionSpeed = p.timing.speed, .motionSeed = p.timing.motionSeed,
        .motionLinked = p.timing.motionLinked,
        .motionComponentMask = p.timing.motionComponentMask};
  }
  double out[2];
  if (!MTSample(ds, n, 2, CMTimeGetSeconds(t) - start, out)) {
    MMScaleError(error);
    return nil;
  }
  *active = YES;
  return [[MMScalePose alloc] initWithX:out[0] y:out[1] authored:YES];
}
@interface MMScalePoseCache ()
@property(nonatomic) NSString *token;
@property(nonatomic) NSArray *entries;
@property(nonatomic) NSUInteger generation;
- (void)publishPose:(MMScalePose *)pose atTime:(CMTime)time;
- (MMScalePose *)poseForEditingAtTime:(CMTime)time latest:(MMScalePose *)latest;
@end
@implementation MMScalePoseCache
- (void)publishEntries:(NSArray<NSDictionary *> *)entries {
  @synchronized(self) { self.generation++; self.entries=[entries copy]; }
}
- (void)publishConstantPose:(MMScalePose *)pose {
  @synchronized(self) { self.generation++; self.entries=@[@{@"pose":pose}]; }
}

- (void)publishPose:(MMScalePose *)pose atTime:(CMTime)time
        inSnapshot:(NSArray<NSDictionary *> *)snapshot {
  if (!pose || !CMTIME_IS_NUMERIC(time)) return;
  @synchronized(self) {
    NSArray *entries=self.entries ?: snapshot;
    for (NSUInteger i=0;i<entries.count;i++) {
      NSDictionary *entry=entries[i];
      if (!entry[@"nativeTime"] || fabs([entry[@"time"] doubleValue]-CMTimeGetSeconds(time))>=1e-6) continue;
      NSMutableArray *updated=[entries mutableCopy];
      NSMutableDictionary *key=[entry mutableCopy];
      key[@"pose"]=pose; updated[i]=[key copy];
      // An older render/refresh cannot overwrite this successful write.
      self.generation++;
      self.entries=[updated copy];
      return;
    }
    // A newer snapshot removed/moved the key: do not resurrect it.
  }
}
- (NSArray<NSDictionary *> *)snapshotEntries { @synchronized(self) { return self.entries; } }
- (MMScalePose *)sampleAtTime:(CMTime)t {
  NSArray *e;
  @synchronized(self) {
    e = _entries;
  }
  BOOL a = NO;
  return e ? MMScaleSample(e, t, &a, nil) : nil;
}
- (MMScalePose *)poseForEditingAtTime:(CMTime)time
                               latest:(MMScalePose *)latest {
  if (!latest || !CMTIME_IS_NUMERIC(time))
    return nil;
  NSArray *entries;
  @synchronized(self) {
    entries = self.entries;
  }
  if (!entries)
    return nil;
  for (NSDictionary *entry in entries)
    if (!entry[@"time"] ||
        fabs([entry[@"time"] doubleValue] - CMTimeGetSeconds(time)) < 1e-6)
      return latest;
  BOOL active = NO;
  return MMScaleSample(entries, time, &active, nil);
}
- (BOOL)valueTargetAtTime:(CMTime)t targetTime:(CMTime *)target {
  NSArray *e;
  @synchronized(self) {
    e = _entries;
  }
  if (!CMTIME_IS_NUMERIC(t) || !e.count || !e[0][@"nativeTime"])
    return NO;
  double s = CMTimeGetSeconds(t);
  NSDictionary *c = e.lastObject;
  for (NSDictionary *x in e)
    if (s <= [x[@"time"] doubleValue] + 1e-6) {
      c = x;
      break;
    }
  [c[@"nativeTime"] getValue:target];
  return YES;
}
- (void)publishPose:(MMScalePose *)pose atTime:(CMTime)time {
  @synchronized(self) {
    NSMutableArray *copy = [self.entries mutableCopy];
    if (!copy.count)
      copy = [NSMutableArray arrayWithObject:@{@"pose" : pose}];
    BOOL replaced = NO;
    double s = CMTimeGetSeconds(time);
    for (NSUInteger i = 0; i < copy.count; i++) {
      NSDictionary *entry = copy[i];
      if (!entry[@"time"] || fabs([entry[@"time"] doubleValue] - s) < 1e-6) {
        NSMutableDictionary *updated = [entry mutableCopy];
        updated[@"pose"] = pose;
        copy[i] = updated;
        replaced = YES;
        break;
      }
    }
    if (!replaced) {
      [copy addObject:@{
        @"time" : @(s),
        @"pose" : pose,
        @"nativeTime" : [NSValue valueWithBytes:&time objCType:@encode(CMTime)]
      }];
      [copy sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                    NSDictionary *b) {
        return [a[@"time"] compare:b[@"time"]];
      }];
    }
    self.generation++;
    self.entries = [copy copy];
  }
}
@end
static NSMapTable *MMScaleCaches(void) {
  static NSMapTable *m;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    m = [NSMapTable strongToWeakObjectsMapTable];
  });
  return m;
}
MMScalePoseCache *MMCreateScalePoseCache(void) {
  MMScalePoseCache *c = [MMScalePoseCache new];
  c.token = NSUUID.UUID.UUIDString;
  @synchronized(MMScaleCaches()) {
    [MMScaleCaches() setObject:c forKey:c.token];
  }
  return c;
}
MMScalePoseCache *MMScaleCacheForManager(id<PROAPIAccessing> m) {
  id<FxParameterRetrievalAPI_v6> g =
      [m apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *t = nil;
  if (![g getStringParameterValue:&t fromParameter:MMScaleCacheToken] ||
      !t.length)
    return nil;
  @synchronized(MMScaleCaches()) {
    return [MMScaleCaches() objectForKey:t];
  }
}
void MMRefreshScalePoseCache(id<PROAPIAccessing> m, CMTime t) {
  MMScalePoseCache *c = MMScaleCacheForManager(m);
  if (!c)
    return;
  NSUInteger gen;
  @synchronized(c) {
    gen = ++c.generation;
    // Keep the last complete snapshot until this read succeeds or fails.
  }
  NSArray *e = MMScaleEntries(m, t, nil);
  @synchronized(c) {
    if (c.generation == gen)
      c.entries = e;
  }
}
MMScalePose *MMReadScaleValue(id<PROAPIAccessing> m, CMTime t) {
  return MMScaleValue([m apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)],
                      t, NULL);
}
NSArray *MMReadScalePoseSamples(id<PROAPIAccessing> m,
                                NSArray<NSValue *> *times, BOOL *active,
                                NSError **error) {
  if (active)
    *active = NO;
  if (!times.count) {
    MMScaleError(error);
    return nil;
  }
  CMTime t;
  [times[0] getValue:&t];
  MMScalePoseCache *c = MMScaleCacheForManager(m);
  NSUInteger generation;
  @synchronized(c) {
    generation = c.generation;
  }
  NSArray *e = MMScaleEntries(m, t, error);
  if (c) {
    @synchronized(c) {
      if (c.generation == generation)
        c.entries = e;
    }
  }
  NSMutableArray *out = [NSMutableArray array];
  for (NSValue *v in times) {
    [v getValue:&t];
    BOOL a = NO;
    MMScalePose *p = MMScaleSample(e, t, &a, error);
    if (!p)
      return nil;
    if (active)
      *active |= a;
    [out addObject:p];
  }
  return out;
}
MMScalePose *MMReadScalePose(id<PROAPIAccessing> m, CMTime t, BOOL *a,
                             NSError **e) {
  return MMReadScalePoseSamples(
             m, @[ [NSValue valueWithBytes:&t objCType:@encode(CMTime)] ], a, e)
      .firstObject;
}
BOOL MMWriteScaleComponent(id<PROAPIAccessing> m, MMScalePoseCache *c,
                           UInt32 component, double value, CMTime t) {
  if ((component != MMScaleX && component != MMScaleY) || !isfinite(value))
    return NO;
  id<FxParameterRetrievalAPI_v6> g =
      [m apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> s =
      [m apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  BOOL explicit = NO;
  if (![g getBoolValue:&explicit fromParameter:MMExplicitCreation atTime:t])
    return NO;
  CMTime target = t;
  if (explicit && (!c || ![c valueTargetAtTime:t targetTime:&target]))
    return NO;
  MMScalePose *latest = MMScaleValue(g, target, NULL);
  MMScalePose *old =
      explicit ? latest : [c poseForEditingAtTime:t latest:latest];
  if (!old)
    return NO;
  double x = component == MMScaleX ? value : old.x,
         y = component == MMScaleY ? value : old.y;
  BOOL proportional = YES;
  if (![g getBoolValue:&proportional
          fromParameter:MMScaleProportional
                 atTime:t])
    return NO;
  if (proportional) {
    if (component == MMScaleX) {
      y = old.x == 0 ? old.y + (value - old.x) : old.y * (value / old.x);
    } else {
      x = old.y == 0 ? old.x + (value - old.y) : old.x * (value / old.y);
    }
    double factor = 1;
    if (x > 400)
      factor = fmin(factor, 400 / x);
    if (y > 400)
      factor = fmin(factor, 400 / y);
    if (x < 0 || y < 0) {
      x = 0;
      y = 0;
    } else if (factor < 1) {
      x *= factor;
      y *= factor;
    }
  }
  x = fmax(0, fmin(400, x));
  y = fmax(0, fmin(400, y));
  MMScalePose *p = [[MMScalePose alloc] initWithX:x
                                                y:y
                                         authored:YES
                                           easing:old.easing
                                      addedMotion:old.addedMotion];
  p=[p poseByReplacingTiming:old.timing];
  BOOL ok = p && [s setCustomParameterValue:p
                                toParameter:MMScaleControls
                                     atTime:target];
  if (ok && c)
    [c publishPose:p atTime:target];
  return ok;
}

MMScalePose *MMSampleScaleSnapshot(NSArray<NSDictionary *> *entries, CMTime time) { BOOL active=NO; return MMScaleSample(entries,time,&active,nil); }
