/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFMatchEndpoints.h"
#import "KFNativeLinks.h"
#import "KFCreationDefaults.h"
#import "KFPropertyLane.h"
#import <math.h>

@interface KFPropertyPoseCache ()
@property(nonatomic) NSString *token;
@property(nonatomic) NSArray<NSDictionary *> *entries;
@property(nonatomic) NSUInteger generation;
- (void)publishValuePose:(id<KFPropertyPose>)pose atTime:(CMTime)time;
@end
@interface KFPropertyLane ()
- (BOOL)writeReplacements:(NSArray *)replacements manager:(id<PROAPIAccessing>)manager cache:(KFPropertyPoseCache *)cache time:(CMTime)time explicit:(BOOL)explicit;
- (NSArray *)readEntries:(id<PROAPIAccessing>)manager time:(CMTime)time error:(NSError **)error;
@end
@implementation KFPropertyPoseCache
- (void)publishEntries:(NSArray<NSDictionary *> *)entries {
  @synchronized(self) { self.generation++; self.entries=[entries copy]; }
}
- (void)publishConstantPose:(id<KFPropertyPose>)pose {
  @synchronized(self) { self.generation++; self.entries=@[@{@"pose":pose}]; }
}

- (NSArray *)snapshotEntries { @synchronized(self) { return self.entries; } }
- (void)publishPose:(id<KFPropertyPose>)pose atTime:(CMTime)time inSnapshot:(NSArray *)snapshot {
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
- (void)publishValuePose:(id<KFPropertyPose>)pose atTime:(CMTime)time {
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

static NSMapTable *KFPropertyCaches(void) {
  static NSMapTable *caches; static dispatch_once_t once;
  dispatch_once(&once,^{ caches=[NSMapTable strongToWeakObjectsMapTable]; }); return caches;
}
static void KFPropertyError(NSError **error) {
  if(error) *error=[NSError errorWithDomain:FxPlugErrorDomain code:kFxError_InvalidParameter userInfo:@{NSLocalizedDescriptionKey:@"Unable to read property keyposes"}];
}
@implementation KFPropertyLane
- (instancetype)initWithParameterID:(UInt32)parameterID
                        displayName:(NSString *)displayName
                       cacheTokenID:(UInt32)cacheTokenID
                      matchToggleID:(UInt32)matchToggleID
               proportionalToggleID:(UInt32)proportionalToggleID
                 visibilityToggleID:(UInt32)visibilityToggleID
                    componentColors:(NSArray<NSColor *> *)componentColors
                    componentLabels:(NSArray<NSString *> *)componentLabels
                         unitSuffix:(NSString *)unitSuffix
                     fractionDigits:(NSUInteger)fractionDigits
                        defaultPose:(id<KFPropertyPose>)pose
                            minimum:(double)minimum
                            maximum:(double)maximum
                       boundsValues:(BOOL)boundsValues
                     percentOfImage:(BOOL)percentOfImage {
  if(!pose.values.count || !displayName.length || !isfinite(minimum) || !isfinite(maximum) || minimum>=maximum) return nil;
  if(componentColors.count!=pose.values.count || componentLabels.count!=pose.values.count) return nil;
  if((self=[super init])) {
    _parameterID=parameterID; _displayName=[displayName copy]; _cacheTokenID=cacheTokenID;
    _matchToggleID=matchToggleID; _proportionalToggleID=proportionalToggleID;
    _visibilityToggleID=visibilityToggleID;
    _componentColors=[componentColors copy]; _componentLabels=[componentLabels copy];
    _unitSuffix=[unitSuffix copy]; _fractionDigits=fractionDigits; _defaultPose=pose;
    _defaultValue=pose.value; _minimum=minimum; _maximum=maximum;
    _componentCount=pose.values.count; _boundsValues=boundsValues; _percentOfImage=percentOfImage;
  }
  return self;
}
- (KFPropertyPoseCache *)createCache {
  KFPropertyPoseCache *cache=[KFPropertyPoseCache new]; cache.token=NSUUID.UUID.UUIDString;
  @synchronized(KFPropertyCaches()) { [KFPropertyCaches() setObject:cache forKey:cache.token]; } return cache;
}
- (KFPropertyPoseCache *)cacheForManager:(id<PROAPIAccessing>)manager {
  NSString *token=nil;
  id<FxParameterRetrievalAPI_v6> get=[manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if(![get getStringParameterValue:&token fromParameter:self.cacheTokenID] || !token.length) return nil;
  @synchronized(KFPropertyCaches()) { return [KFPropertyCaches() objectForKey:token]; }
}
- (id<KFPropertyPose>)readValue:(id<PROAPIAccessing>)manager time:(CMTime)time {
  NSObject<NSSecureCoding,NSCopying> *pose=nil;
  id<FxParameterRetrievalAPI_v6> get=[manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if(!CMTIME_IS_NUMERIC(time) || ![get getCustomParameterValue:&pose fromParameter:self.parameterID atTime:time]) return nil;
  // Missing payloads use the lane default, including older effect instances.
  if(!pose) return self.defaultPose;
  return [pose isKindOfClass:[(NSObject *)self.defaultPose class]] ? (id<KFPropertyPose>)pose:nil;
}
- (NSArray *)readEntries:(id<PROAPIAccessing>)manager time:(CMTime)time error:(NSError **)error {
  id<KFPropertyPose> probe=[self readValue:manager time:time];
  id<FxKeyframeAPI_v3> keys=[manager apiForProtocol:@protocol(FxKeyframeAPI_v3)];
  if(!probe || !keys) { KFPropertyError(error); return nil; }
  NSUInteger count=0; NSError *failure=[keys keyframeCount:&count forParameter:self.parameterID andChannel:0];
  if(failure) { if(error) *error=failure; return nil; }
  if(!count) return @[@{@"pose":probe}];
  NSMutableArray *entries=[NSMutableArray arrayWithCapacity:count];
  for(NSUInteger i=0;i<count;i++) {
    FxKeyframe key; FxInitKeyframe(key,kFxKeyframe_CurrentVersion);
    failure=[keys keyframe:&key forParameter:self.parameterID channel:0 andIndex:i];
    if(failure) { if(error) *error=failure; return nil; }
    id<KFPropertyPose> pose=[self readValue:manager time:key.time];
    if(!pose) { KFPropertyError(error); return nil; }
    [entries addObject:@{@"time":@(CMTimeGetSeconds(key.time)),@"nativeTime":[NSValue valueWithBytes:&key.time objCType:@encode(CMTime)],@"nativeKey":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)],@"pose":pose}];
  }
  [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) { return [a[@"time"] compare:b[@"time"]]; }];
  return [entries copy];
}
- (void)refreshCacheForManager:(id<PROAPIAccessing>)manager time:(CMTime)time {
  KFPropertyPoseCache *cache=[self cacheForManager:manager]; if(!cache) return;
  NSUInteger generation; @synchronized(cache) { generation=++cache.generation; }
  NSArray *entries=[self readEntries:manager time:time error:nil];
  @synchronized(cache) { if(generation==cache.generation) cache.entries=entries; }
}
- (id<KFPropertyPose>)sampleEntries:(NSArray *)entries time:(CMTime)time {
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
    id<KFPropertyPose> pose=entries[i][@"pose"];
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
  return [self.defaultPose poseByReplacingValues:sample authored:YES easing:MTEasingSmooth addedMotion:MTAddedMotionNone timing:[KFPoseTiming new]];
}
- (NSArray *)readSamples:(id<PROAPIAccessing>)manager times:(NSArray<NSValue *> *)times error:(NSError **)error {
  if(!times.count) { KFPropertyError(error); return nil; }
  CMTime time; [times[0] getValue:&time];
  KFPropertyPoseCache *cache=[self cacheForManager:manager]; NSUInteger generation=0;
  if(cache) @synchronized(cache) { generation=cache.generation; }
  NSArray *entries=[self readEntries:manager time:time error:error];
  if(cache) @synchronized(cache) { if(generation==cache.generation) cache.entries=entries; }
  if(!entries) return nil;
  NSMutableArray *samples=[NSMutableArray arrayWithCapacity:times.count];
  for(NSValue *t in times) {
    [t getValue:&time]; id<KFPropertyPose> pose=[self sampleEntries:entries time:time];
    if(!pose) { KFPropertyError(error); return nil; } [samples addObject:pose];
  }
  return samples;
}
- (BOOL)writeValue:(double)value manager:(id<PROAPIAccessing>)manager cache:(KFPropertyPoseCache *)cache time:(CMTime)time explicit:(BOOL)explicit {
  return [self writeComponent:0 value:value manager:manager cache:cache time:time explicit:explicit];
}
- (BOOL)writeComponent:(NSUInteger)component value:(double)value manager:(id<PROAPIAccessing>)manager cache:(KFPropertyPoseCache *)cache time:(CMTime)time explicit:(BOOL)explicit {
  if(component>=self.componentCount) return NO;
  NSMutableArray *replacements=[NSMutableArray arrayWithCapacity:self.componentCount];
  for(NSUInteger i=0;i<self.componentCount;i++) [replacements addObject:i==component ? (id)@(value):(id)NSNull.null];
  return [self writeReplacements:replacements manager:manager cache:cache time:time explicit:explicit];
}
- (BOOL)writeValues:(NSArray<NSNumber *> *)values manager:(id<PROAPIAccessing>)manager cache:(KFPropertyPoseCache *)cache time:(CMTime)time explicit:(BOOL)explicit {
  if(values.count!=self.componentCount) return NO;
  return [self writeReplacements:values manager:manager cache:cache time:time explicit:explicit];
}
// One host write per call: `replacements` carries a value per component, or
// NSNull where the existing one stays.
- (BOOL)writeReplacements:(NSArray *)replacements manager:(id<PROAPIAccessing>)manager cache:(KFPropertyPoseCache *)cache time:(CMTime)time explicit:(BOOL)explicit {
  if(!CMTIME_IS_NUMERIC(time)) return NO;
  for(id replacement in replacements)
    if(replacement!=NSNull.null && !isfinite([replacement doubleValue])) return NO;
  NSArray *entries=[cache snapshotEntries]; if(!entries.count) return NO;
  CMTime target=time;
  if(explicit) {
    if(entries[0][@"nativeTime"]) {
      NSDictionary *destination=entries.lastObject;
      for(NSDictionary *entry in entries) if(CMTimeGetSeconds(time)<=[entry[@"time"] doubleValue]+1e-6) { destination=entry; break; }
      [destination[@"nativeTime"] getValue:&target];
    }
  }
  id<KFPropertyPose> old=[self readValue:manager time:target]; if(!old) return NO;
  // In a gap, sample unedited components from our engine, not host interpolation.
  BOOL exact=NO;
  for(NSDictionary *entry in entries)
    if(!entry[@"time"] || fabs([entry[@"time"] doubleValue]-CMTimeGetSeconds(target))<1e-6) { exact=YES; break; }
  id<KFPropertyPose> source=(!explicit && !exact && self.componentCount>1) ? [self sampleEntries:entries time:time] : old;
  if(!source) return NO;
  NSMutableArray *values=[source.values mutableCopy];
  for(NSUInteger i=0;i<self.componentCount;i++) {
    id replacement=replacements[i];
    if(replacement==NSNull.null) continue;
    double value=[replacement doubleValue];
    values[i]=@(self.boundsValues ? fmax(self.minimum,fmin(self.maximum,value)) : value);
  }
  KFPoseTiming *timing=(!explicit && !exact) ? [source.timing timingByReplacingLinkID:@""]:source.timing;
  BOOL creating=!explicit && KFIsNewKeyTime(entries,target);
  if (creating) timing=KFTimingWithCreationDefaults(timing);
  id<KFPropertyPose> pose=[source poseByReplacingValues:values authored:YES easing:creating ? (MTEasing)[KFReadDefault(KFEasingDefaultKey)[@"value"] integerValue] : source.easing addedMotion:source.addedMotion timing:timing];
  if(KFMirrorsValueEdit(manager,self.parameterID,target)) return KFWriteNativeLinkedPose(manager,self.parameterID,target,pose);
  id<FxParameterSettingAPI_v5> set=[manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  BOOL ok=[set setCustomParameterValue:pose toParameter:self.parameterID atTime:target];
  if(ok) [cache publishValuePose:pose atTime:target]; return ok;
}
@end

KFPropertyPoseCache *KFPropertyEditingCache(KFPropertyLane *lane, id<PROAPIAccessing> manager, CMTime time) {
  KFPropertyPoseCache *cache=[lane cacheForManager:manager];
  if(cache) return cache;
  cache=[KFPropertyPoseCache new];
  [cache publishEntries:[lane readEntries:manager time:time error:nil]];
  return cache;
}

// The plugin registers its table once at load; readers never build it, so a
// lane is always the same object for a given parameter.
static NSArray<KFPropertyLane *> *KFRegisteredLanes = nil;
void KFRegisterLanes(NSArray<KFPropertyLane *> *lanes) { KFRegisteredLanes=[lanes copy]; }
NSArray<KFPropertyLane *> *KFPropertyLanes(void) { return KFRegisteredLanes ?: @[]; }
KFPropertyLane *KFPropertyLaneForParameter(UInt32 parameterID) {
  for(KFPropertyLane *lane in KFPropertyLanes()) if(lane.parameterID==parameterID) return lane;
  return nil;
}
NSArray<NSNumber *> *KFProperties(void) {
  NSMutableArray<NSNumber *> *properties=[NSMutableArray arrayWithCapacity:KFPropertyLanes().count];
  for(KFPropertyLane *lane in KFPropertyLanes()) [properties addObject:@(lane.parameterID)];
  return properties;
}
NSString *KFPropertyDisplayName(UInt32 parameter) {
  return KFPropertyLaneForParameter(parameter).displayName;
}

static UInt32 KFExplicitCreationParameter;
void KFSetExplicitCreationParameter(UInt32 parameterID) { KFExplicitCreationParameter=parameterID; }
BOOL KFExplicitCreationEnabled(id<PROAPIAccessing> manager, CMTime time, BOOL *explicit) {
  if(!KFExplicitCreationParameter) { *explicit=NO; return YES; }
  id<FxParameterRetrievalAPI_v6> get=[manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  return [get getBoolValue:explicit fromParameter:KFExplicitCreationParameter atTime:time];
}
