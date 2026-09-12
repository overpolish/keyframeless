/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMCombinedPose.h"
#import "Constants.h"
#import <math.h>
@import MotionTiming;

@implementation MMCombinedPose
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithPositionX:(double)x scale:(double)scale authored:(BOOL)authored {
  return [self initWithPositionX:x scale:scale authored:authored easing:MTEasingSmooth];
}
- (instancetype)initWithPositionX:(double)x scale:(double)scale authored:(BOOL)authored easing:(MTEasing)easing {
  if (!isfinite(x) || !isfinite(scale) || easing < MTEasingSmooth || easing > MTEasingEaseOut) return nil;
  if ((self = [super init])) { _positionX = x; _scale = scale; _authored = authored; _easing = easing; }
  return self;
}
- (instancetype)initWithCoder:(NSCoder *)coder {
  return [self initWithPositionX:[coder decodeDoubleForKey:@"x"]
                          scale:[coder decodeDoubleForKey:@"scale"]
                       authored:[coder decodeBoolForKey:@"authored"] easing:(MTEasing)[coder decodeIntegerForKey:@"easing"]];
}
- (void)encodeWithCoder:(NSCoder *)coder {
  [coder encodeDouble:self.positionX forKey:@"x"];
  [coder encodeDouble:self.scale forKey:@"scale"];
  [coder encodeBool:self.authored forKey:@"authored"];
  [coder encodeInteger:self.easing forKey:@"easing"];
}
- (id)copyWithZone:(NSZone *)zone { return self; }
- (BOOL)isEqual:(id)object {
  if (![object isKindOfClass:MMCombinedPose.class]) return NO;
  MMCombinedPose *other = object;
  return self.positionX == other.positionX && self.scale == other.scale && self.authored == other.authored && self.easing == other.easing;
}
- (NSUInteger)hash { return @(self.positionX).hash ^ @(self.scale).hash ^ (NSUInteger)self.authored ^ (NSUInteger)self.easing; }
- (NSObject<NSSecureCoding, NSCopying> *)interpolateBetween:(NSObject<NSSecureCoding, NSCopying> *)rightValue withWeight:(float)weight {
  if (![rightValue isKindOfClass:MMCombinedPose.class] || !isfinite(weight)) return self;
  MMCombinedPose *right = (MMCombinedPose *)rightValue;
  double w = fmax(0, fmin(1, weight));
  return [[MMCombinedPose alloc] initWithPositionX:self.positionX + (right.positionX-self.positionX)*w
                                           scale:self.scale + (right.scale-self.scale)*w
                                        authored:self.authored || right.authored easing:w >= 1 ? right.easing : self.easing];
}
@end

static id MMCombinedFailure(NSError **error) {
  if (error) *error = [NSError errorWithDomain:FxPlugErrorDomain code:kFxError_InvalidParameter
                                     userInfo:@{NSLocalizedDescriptionKey:@"Unable to read combined pose keyframes"}];
  return nil;
}
static MMCombinedPose *MMCombinedValue(id<FxParameterRetrievalAPI_v6> get, CMTime time) {
  NSObject<NSSecureCoding, NSCopying> *value = nil;
  BOOL success = [get getCustomParameterValue:&value fromParameter:MMCustomControls atTime:time];
  if (!success) return nil;
  if ([value isKindOfClass:MMCombinedPose.class]) return (MMCombinedPose *)value;
  // Older capability-checkpoint instances saved a numeric placeholder.
  if ([value isKindOfClass:NSNumber.class])
    return [[MMCombinedPose alloc] initWithPositionX:0 scale:100 authored:NO];
  return nil;
}
static NSArray *MMReadCombinedEntries(id<PROAPIAccessing> manager, CMTime time, NSError **error) {
  if (!CMTIME_IS_NUMERIC(time)) return MMCombinedFailure(error);
  id<FxParameterRetrievalAPI_v6> get = [manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxKeyframeAPI_v3> keys = [manager apiForProtocol:@protocol(FxKeyframeAPI_v3)];
  if (!get || !keys) return MMCombinedFailure(error);
  NSUInteger count = 0;
  NSError *failure = [keys keyframeCount:&count forParameter:MMCustomControls andChannel:0];
  if (failure) { if (error) *error = failure; return nil; }
  if (!count) {
    MMCombinedPose *pose = MMCombinedValue(get, time);
    if (!pose) return MMCombinedFailure(error);
    return @[@{@"pose":pose}];
  }
  NSMutableArray *entries = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger i=0; i<count; ++i) {
    FxKeyframe key; FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
    failure = [keys keyframe:&key forParameter:MMCustomControls channel:0 andIndex:i];
    if (failure) { if (error) *error = failure; return nil; }
    if (!CMTIME_IS_NUMERIC(key.time)) return MMCombinedFailure(error);
    MMCombinedPose *pose = MMCombinedValue(get, key.time);
    if (!pose) return MMCombinedFailure(error);
    [entries addObject:@{@"time":@(CMTimeGetSeconds(key.time)), @"pose":pose, @"nativeTime":[NSValue valueWithBytes:&key.time objCType:@encode(CMTime)]}];
  }
  [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
    return [a[@"time"] compare:b[@"time"]];
  }];
  return [entries copy];
}
static MMCombinedPose *MMSampleCombinedEntries(NSArray *entries, CMTime time, BOOL *active, NSError **error) {
  *active = NO;
  if (!entries || !CMTIME_IS_NUMERIC(time)) return MMCombinedFailure(error);
  if (entries.count == 1 && !entries[0][@"time"]) {
    MMCombinedPose *pose = entries[0][@"pose"];
    *active = pose.authored;
    return pose;
  }
  NSUInteger count = entries.count;
  NSMutableData *values = [NSMutableData dataWithLength:count * 2 * sizeof(double)];
  NSMutableData *storage = [NSMutableData dataWithLength:count * sizeof(MTDestination)];
  double *components = values.mutableBytes;
  MTDestination *destinations = storage.mutableBytes;
  double start = [entries[0][@"time"] doubleValue];
  for (NSUInteger i=0; i<count; ++i) {
    MMCombinedPose *pose = entries[i][@"pose"];
    components[i*2] = pose.positionX; components[i*2+1] = pose.scale;
    destinations[i] = (MTDestination){[entries[i][@"time"] doubleValue]-start, 1.2, &components[i*2], pose.easing};
  }
  double result[2];
  if (!MTSample(destinations, count, 2, CMTimeGetSeconds(time)-start, result)) return MMCombinedFailure(error);
  *active = YES;
  return [[MMCombinedPose alloc] initWithPositionX:result[0] scale:result[1] authored:YES];
}

@interface MMCombinedPoseCache ()
@property(nonatomic) NSString *token;
@property(nonatomic) NSArray *entries;
@property(nonatomic) NSUInteger generation;
@end
@implementation MMCombinedPoseCache
- (BOOL)valueTargetAtTime:(CMTime)time targetTime:(CMTime *)target {
  if (!CMTIME_IS_NUMERIC(time)) return NO;
  NSArray *entries;
  @synchronized (self) { entries = self.entries; }
  if (!entries.count || !entries[0][@"nativeTime"]) return NO;
  double seconds = CMTimeGetSeconds(time);
  NSDictionary *chosen = entries.lastObject;
  for (NSDictionary *entry in entries)
    if (seconds <= [entry[@"time"] doubleValue] || fabs(seconds-[entry[@"time"] doubleValue])<1e-6) {
      chosen = entry; break;
    }
  [chosen[@"nativeTime"] getValue:target];
  return YES;
}
- (MMCombinedPose *)poseForEditingAtTime:(CMTime)time latestValue:(MMCombinedPose *)latest {
  if (!latest || !CMTIME_IS_NUMERIC(time)) return nil;
  NSArray *entries;
  @synchronized (self) { entries = self.entries; }
  if (!entries) return nil;
  // At a native key (or with no keys), use the freshly read host object so a
  // delayed notification cannot overwrite a more recent partner-component edit.
  for (NSDictionary *entry in entries)
    if (!entry[@"time"] || fabs([entry[@"time"] doubleValue]-CMTimeGetSeconds(time)) < 1e-6)
      return latest;
  // Between keys preserve the timing engine's displayed value, not the host's
  // independently weighted interpolation.
  BOOL active = NO;
  return MMSampleCombinedEntries(entries, time, &active, nil);
}
- (MMCombinedPose *)sampleAtTime:(CMTime)time {
  NSArray *entries;
  @synchronized (self) { entries = self.entries; }
  BOOL active = NO;
  return entries ? MMSampleCombinedEntries(entries, time, &active, nil) : nil;
}
@end
static NSMapTable *MMCombinedCaches(void) {
  static NSMapTable *caches; static dispatch_once_t once;
  dispatch_once(&once, ^{ caches = [NSMapTable strongToWeakObjectsMapTable]; });
  return caches;
}
MMCombinedPoseCache *MMCreateCombinedPoseCache(void) {
  MMCombinedPoseCache *cache = [MMCombinedPoseCache new];
  cache.token = NSUUID.UUID.UUIDString;
  NSMapTable *caches = MMCombinedCaches();
  @synchronized (caches) { [caches setObject:cache forKey:cache.token]; }
  return cache;
}
static MMCombinedPoseCache *MMCacheForManager(id<PROAPIAccessing> manager) {
  id<FxParameterRetrievalAPI_v6> get = [manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *token = nil;
  if (![get getStringParameterValue:&token fromParameter:MMCombinedCacheToken] || !token.length) return nil;
  NSMapTable *caches = MMCombinedCaches();
  @synchronized (caches) { return [caches objectForKey:token]; }
}
static NSUInteger MMBeginCacheRefresh(MMCombinedPoseCache *cache) {
  @synchronized (cache) { cache.generation += 1; return cache.generation; }
}
static void MMPublishCache(MMCombinedPoseCache *cache, NSArray *entries, NSUInteger generation) {
  if (!cache) return;
  @synchronized (cache) {
    if (cache.generation == generation) cache.entries = entries;
  }
}
void MMRefreshCombinedPoseCache(id<PROAPIAccessing> manager, CMTime time) {
  MMCombinedPoseCache *cache = MMCacheForManager(manager);
  if (!cache) return;
  NSUInteger generation = MMBeginCacheRefresh(cache);
  // Invalidate first: a failed host read must not leave stale data editable.
  MMPublishCache(cache, nil, generation);
  MMPublishCache(cache, MMReadCombinedEntries(manager, time, nil), generation);
}
MMCombinedPose *MMReadCombinedValue(id<PROAPIAccessing> manager, CMTime time) {
  id<FxParameterRetrievalAPI_v6> get = [manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  return MMCombinedValue(get, time);
}
MMCombinedPose *MMReadCombinedPose(id<PROAPIAccessing> manager, CMTime time, BOOL *active, NSError **error) {
  MMCombinedPoseCache *cache = MMCacheForManager(manager);
  NSUInteger generation = 0;
  @synchronized (cache) { generation = cache.generation; }
  NSArray *entries = MMReadCombinedEntries(manager, time, error);
  MMPublishCache(cache, entries, generation);
  return MMSampleCombinedEntries(entries, time, active, error);
}

BOOL MMCombinedIncomingEasing(id<PROAPIAccessing> manager, CMTime time, int *easing, CMTime *targetTime) {
  if (!CMTIME_IS_NUMERIC(time)) return NO;
  MMCombinedPoseCache *cache = MMCacheForManager(manager);
  NSArray *entries;
  @synchronized (cache) { entries = cache.entries; }
  double seconds = CMTimeGetSeconds(time);
  if (entries.count < 2 || seconds <= [entries[0][@"time"] doubleValue] + 1e-6) return NO;
  for (NSUInteger i=1; i<entries.count; ++i) {
    double arrival = [entries[i][@"time"] doubleValue];
    if (seconds <= arrival || fabs(arrival-seconds) < 1e-6) {
      *easing = ((MMCombinedPose *)entries[i][@"pose"]).easing;
      if (targetTime) [entries[i][@"nativeTime"] getValue:targetTime];
      return YES;
    }
  }
  return NO;
}

BOOL MMWriteCombinedComponent(id<PROAPIAccessing> manager, MMCombinedPoseCache *cache,
                              UInt32 component, double value, CMTime time) {
  if ((component != MMPositionX && component != MMScale) || !isfinite(value)) return NO;
  id<FxParameterRetrievalAPI_v6> get = [manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> set = [manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  BOOL explicit = NO;
  if (![get getBoolValue:&explicit fromParameter:MMExplicitCreation atTime:time]) return NO;
  CMTime target = time;
  if (explicit && ![cache valueTargetAtTime:time targetTime:&target]) return NO;
  MMCombinedPose *latest = MMReadCombinedValue(manager,target);
  MMCombinedPose *old = explicit ? latest : [cache poseForEditingAtTime:time latestValue:latest];
  if (!old) return NO;
  MMCombinedPose *pose = [[MMCombinedPose alloc]
      initWithPositionX:component == MMPositionX ? value : old.positionX
                  scale:component == MMScale ? value : old.scale authored:YES easing:old.easing];
  return pose && [set setCustomParameterValue:pose toParameter:MMCustomControls atTime:target];
}
