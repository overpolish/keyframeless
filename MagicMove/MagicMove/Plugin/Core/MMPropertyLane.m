/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMMatchEndpoints.h"
#import "MMNativeLinks.h"
#import "MMDefaults.h"
#import "MMPropertyLane.h"
#import <math.h>

@interface MMPropertyPoseCache ()
@property(nonatomic) NSString *token;
@property(nonatomic) NSArray<NSDictionary *> *entries;
@property(nonatomic) NSUInteger generation;
- (void)publishValuePose:(id<MMPropertyPose>)pose atTime:(CMTime)time;
@end
@implementation MMPropertyPoseCache
- (void)publishEntries:(NSArray<NSDictionary *> *)entries {
  @synchronized(self) { self.generation++; self.entries=[entries copy]; }
}
- (void)publishConstantPose:(id<MMPropertyPose>)pose {
  @synchronized(self) { self.generation++; self.entries=@[@{@"pose":pose}]; }
}

- (NSArray *)snapshotEntries { @synchronized(self) { return self.entries; } }
- (void)publishPose:(id<MMPropertyPose>)pose atTime:(CMTime)time inSnapshot:(NSArray *)snapshot {
  if(!pose || !CMTIME_IS_NUMERIC(time)) return;
  @synchronized(self) {
    NSArray *entries=self.entries ?: snapshot;
    for(NSUInteger i=0;i<entries.count;i++) {
      NSDictionary *entry=entries[i];
      if(!entry[@"nativeTime"] || fabs([entry[@"time"] doubleValue]-CMTimeGetSeconds(time))>=1e-6) continue;
      NSMutableArray *copy=[entries mutableCopy]; NSMutableDictionary *key=[entry mutableCopy];
      key[@"pose"]=pose; copy[i]=[key copy]; self.entries=[copy copy]; self.generation++; return;
    }
    // Never resurrect a key removed by a newer completed snapshot.
  }
}
- (void)publishValuePose:(id<MMPropertyPose>)pose atTime:(CMTime)time {
  @synchronized(self) {
    NSMutableArray *copy=[self.entries mutableCopy];
    if(!copy.count) copy=[NSMutableArray arrayWithObject:@{@"pose":pose}];
    BOOL replaced=NO; double seconds=CMTimeGetSeconds(time);
    for(NSUInteger i=0;i<copy.count;i++) {
      NSDictionary *entry=copy[i];
      if(!entry[@"time"] || fabs([entry[@"time"] doubleValue]-seconds)<1e-6) {
        NSMutableDictionary *key=[entry mutableCopy]; key[@"pose"]=pose; copy[i]=[key copy]; replaced=YES; break;
      }
    }
    if(!replaced) {
      [copy addObject:@{@"time":@(seconds),@"nativeTime":[NSValue valueWithBytes:&time objCType:@encode(CMTime)],@"pose":pose}];
      [copy sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) { return [a[@"time"] compare:b[@"time"]]; }];
    }
    self.entries=[copy copy]; self.generation++;
  }
}
@end

static NSMapTable *MMPropertyCaches(void) {
  static NSMapTable *caches; static dispatch_once_t once;
  dispatch_once(&once,^{ caches=[NSMapTable strongToWeakObjectsMapTable]; }); return caches;
}
static void MMPropertyError(NSError **error) {
  if(error) *error=[NSError errorWithDomain:FxPlugErrorDomain code:kFxError_InvalidParameter userInfo:@{NSLocalizedDescriptionKey:@"Unable to read property keyposes"}];
}
@implementation MMPropertyLane
- (instancetype)initWithParameterID:(UInt32)parameterID cacheTokenID:(UInt32)cacheTokenID defaultPose:(id<MMPropertyPose>)pose minimum:(double)minimum maximum:(double)maximum boundsValues:(BOOL)boundsValues {
  if(!pose.values.count || !isfinite(minimum) || !isfinite(maximum) || minimum>=maximum) return nil;
  if((self=[super init])) {
    _parameterID=parameterID; _cacheTokenID=cacheTokenID; _defaultPose=pose;
    _defaultValue=pose.value; _minimum=minimum; _maximum=maximum;
    _componentCount=pose.values.count; _boundsValues=boundsValues;
  }
  return self;
}
- (MMPropertyPoseCache *)createCache {
  MMPropertyPoseCache *cache=[MMPropertyPoseCache new]; cache.token=NSUUID.UUID.UUIDString;
  @synchronized(MMPropertyCaches()) { [MMPropertyCaches() setObject:cache forKey:cache.token]; } return cache;
}
- (MMPropertyPoseCache *)cacheForManager:(id<PROAPIAccessing>)manager {
  NSString *token=nil;
  id<FxParameterRetrievalAPI_v6> get=[manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if(![get getStringParameterValue:&token fromParameter:self.cacheTokenID] || !token.length) return nil;
  @synchronized(MMPropertyCaches()) { return [MMPropertyCaches() objectForKey:token]; }
}
- (id<MMPropertyPose>)readValue:(id<PROAPIAccessing>)manager time:(CMTime)time {
  NSObject<NSSecureCoding,NSCopying> *pose=nil;
  id<FxParameterRetrievalAPI_v6> get=[manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if(!CMTIME_IS_NUMERIC(time) || ![get getCustomParameterValue:&pose fromParameter:self.parameterID atTime:time]) return nil;
  // Missing payloads use the lane default, including older effect instances.
  if(!pose) return self.defaultPose;
  return [pose isKindOfClass:[(NSObject *)self.defaultPose class]] ? (id<MMPropertyPose>)pose:nil;
}
- (NSArray *)readEntries:(id<PROAPIAccessing>)manager time:(CMTime)time error:(NSError **)error {
  id<MMPropertyPose> probe=[self readValue:manager time:time];
  id<FxKeyframeAPI_v3> keys=[manager apiForProtocol:@protocol(FxKeyframeAPI_v3)];
  if(!probe || !keys) { MMPropertyError(error); return nil; }
  NSUInteger count=0; NSError *failure=[keys keyframeCount:&count forParameter:self.parameterID andChannel:0];
  if(failure) { if(error) *error=failure; return nil; }
  if(!count) return @[@{@"pose":probe}];
  NSMutableArray *entries=[NSMutableArray arrayWithCapacity:count];
  for(NSUInteger i=0;i<count;i++) {
    FxKeyframe key; FxInitKeyframe(key,kFxKeyframe_CurrentVersion);
    failure=[keys keyframe:&key forParameter:self.parameterID channel:0 andIndex:i];
    if(failure) { if(error) *error=failure; return nil; }
    id<MMPropertyPose> pose=[self readValue:manager time:key.time];
    if(!pose) { MMPropertyError(error); return nil; }
    [entries addObject:@{@"time":@(CMTimeGetSeconds(key.time)),@"nativeTime":[NSValue valueWithBytes:&key.time objCType:@encode(CMTime)],@"nativeKey":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)],@"pose":pose}];
  }
  [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) { return [a[@"time"] compare:b[@"time"]]; }];
  return [entries copy];
}
- (void)refreshCacheForManager:(id<PROAPIAccessing>)manager time:(CMTime)time {
  MMPropertyPoseCache *cache=[self cacheForManager:manager]; if(!cache) return;
  NSUInteger generation; @synchronized(cache) { generation=++cache.generation; }
  NSArray *entries=[self readEntries:manager time:time error:nil];
  @synchronized(cache) { if(generation==cache.generation) cache.entries=entries; }
}
- (id<MMPropertyPose>)sampleEntries:(NSArray *)entries time:(CMTime)time {
  if(!entries.count || !CMTIME_IS_NUMERIC(time)) return nil;
  if(entries.count==1 && !entries[0][@"time"]) return entries[0][@"pose"];
  NSUInteger count=entries.count, components=self.componentCount;
  NSMutableData *values=[NSMutableData dataWithLength:count*components*sizeof(double)];
  NSMutableData *storage=[NSMutableData dataWithLength:count*sizeof(MTDestination)];
  NSMutableData *limits=[NSMutableData dataWithLength:components*2*sizeof(double)];
  double *v=values.mutableBytes, *minimum=limits.mutableBytes, *maximum=minimum+components;
  MTDestination *destinations=storage.mutableBytes;
  for(NSUInteger axis=0;axis<components;axis++) { minimum[axis]=self.minimum; maximum[axis]=self.maximum; }
  double start=[entries[0][@"time"] doubleValue];
  for(NSUInteger i=0;i<count;i++) {
    id<MMPropertyPose> pose=entries[i][@"pose"];
    if(pose.values.count!=components) return nil;
    for(NSUInteger axis=0;axis<components;axis++) v[i*components+axis]=pose.values[axis].doubleValue;
    double at=[entries[i][@"time"] doubleValue];
    destinations[i]=(MTDestination){
      .arrival = at - start,
      .duration = (pose.timing.available && i > 0
                       ? at - [entries[i-1][@"time"] doubleValue]
                       : pose.timing.duration),
      .values = &v[i * components], .easing = pose.easing,
      .addedMotion = pose.addedMotion, .modulationMins = minimum,
      .modulationMaxs = maximum, .modulationRangeCount = components,
      .customMotion = true, .customMotionComponents = true, .motionAmount = pose.timing.amount,
      .motionSpeed = pose.timing.speed, .motionSeed = pose.timing.motionSeed,
      .motionLinked = pose.timing.motionLinked,
      .motionComponentMask = pose.timing.motionComponentMask};
  }
  NSMutableData *output=[NSMutableData dataWithLength:components*sizeof(double)]; double *result=output.mutableBytes;
  if(!MTSample(destinations,count,components,CMTimeGetSeconds(time)-start,result)) return nil;
  NSMutableArray *sample=[NSMutableArray arrayWithCapacity:components];
  for(NSUInteger axis=0;axis<components;axis++)
    [sample addObject:@(self.boundsValues ? fmax(self.minimum,fmin(self.maximum,result[axis])) : result[axis])];
  return [self.defaultPose poseByReplacingValues:sample authored:YES easing:MTEasingSmooth addedMotion:MTAddedMotionNone timing:[MMPoseTiming new]];
}
- (NSArray *)readSamples:(id<PROAPIAccessing>)manager times:(NSArray<NSValue *> *)times error:(NSError **)error {
  if(!times.count) { MMPropertyError(error); return nil; }
  CMTime time; [times[0] getValue:&time];
  MMPropertyPoseCache *cache=[self cacheForManager:manager]; NSUInteger generation=0;
  if(cache) @synchronized(cache) { generation=cache.generation; }
  NSArray *entries=[self readEntries:manager time:time error:error];
  if(cache) @synchronized(cache) { if(generation==cache.generation) cache.entries=entries; }
  if(!entries) return nil;
  NSMutableArray *samples=[NSMutableArray arrayWithCapacity:times.count];
  for(NSValue *t in times) {
    [t getValue:&time]; id<MMPropertyPose> pose=[self sampleEntries:entries time:time];
    if(!pose) { MMPropertyError(error); return nil; } [samples addObject:pose];
  }
  return samples;
}
- (BOOL)writeValue:(double)value manager:(id<PROAPIAccessing>)manager cache:(MMPropertyPoseCache *)cache time:(CMTime)time explicit:(BOOL)explicit {
  return [self writeComponent:0 value:value manager:manager cache:cache time:time explicit:explicit];
}
- (BOOL)writeComponent:(NSUInteger)component value:(double)value manager:(id<PROAPIAccessing>)manager cache:(MMPropertyPoseCache *)cache time:(CMTime)time explicit:(BOOL)explicit {
  if(component>=self.componentCount || !isfinite(value)||!CMTIME_IS_NUMERIC(time)) return NO;
  NSArray *entries=[cache snapshotEntries]; if(!entries.count) return NO;
  CMTime target=time;
  if(explicit) {
    if(entries[0][@"nativeTime"]) {
      NSDictionary *destination=entries.lastObject;
      for(NSDictionary *entry in entries) if(CMTimeGetSeconds(time)<=[entry[@"time"] doubleValue]+1e-6) { destination=entry; break; }
      [destination[@"nativeTime"] getValue:&target];
    }
  }
  id<MMPropertyPose> old=[self readValue:manager time:target]; if(!old) return NO;
  // In a gap, sample unedited components from our engine, not host interpolation.
  BOOL exact=NO;
  for(NSDictionary *entry in entries)
    if(!entry[@"time"] || fabs([entry[@"time"] doubleValue]-CMTimeGetSeconds(target))<1e-6) { exact=YES; break; }
  id<MMPropertyPose> source=(!explicit && !exact && self.componentCount>1) ? [self sampleEntries:entries time:time] : old;
  if(!source) return NO;
  NSMutableArray *values=[source.values mutableCopy];
  values[component]=@(self.boundsValues ? fmax(self.minimum,fmin(self.maximum,value)) : value);
  MMPoseTiming *timing=(!explicit && !exact) ? [source.timing timingByReplacingLinkID:@""]:source.timing;
  BOOL creating=!explicit && MMIsNewKeyTime(entries,target);
  if (creating) timing=MMTimingWithCreationDefaults(timing);
  id<MMPropertyPose> pose=[source poseByReplacingValues:values authored:YES easing:creating ? (MTEasing)[MMReadDefault(@"easing")[@"value"] integerValue] : source.easing addedMotion:source.addedMotion timing:timing];
  if(MMMirrorsValueEdit(manager,self.parameterID,target)) return MMWriteNativeLinkedPose(manager,self.parameterID,target,pose);
  id<FxParameterSettingAPI_v5> set=[manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  BOOL ok=[set setCustomParameterValue:pose toParameter:self.parameterID atTime:target];
  if(ok) [cache publishValuePose:pose atTime:target]; return ok;
}
@end

#import "MMScalarPose.h"
#import "MMRotationPose.h"
#import "MMAnchorPose.h"
NSArray<MMPropertyLane *> *MMPropertyLanes(void) {
  return @[MMRotationLane(),MMOpacityLane(),MMBlurLane(),MMAnchorLane()];
}
MMPropertyLane *MMPropertyLaneForParameter(UInt32 parameterID) {
  for(MMPropertyLane *lane in MMPropertyLanes()) if(lane.parameterID==parameterID) return lane;
  return nil;
}
