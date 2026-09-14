/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMScalarPose.h"
#import "MMTimingEditorModel.h"
#import "MockHost.h"
#import <assert.h>
#import <math.h>
#import "ShaderTypes.h"

@interface OpacityHost : MockHost
@property(nonatomic, copy) void (^readHook)(void);
@end

@implementation OpacityHost
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding, NSCopying> **)value
                  fromParameter:(UInt32)p atTime:(CMTime)t {
  if (p != MMOpacityControls || ![self lane:p].count)
    return [super getCustomParameterValue:value fromParameter:p atTime:t];
  if (self.failReadParameter == p) return NO;
  double seconds = CMTimeGetSeconds(t);
  for (NSDictionary *entry in [self lane:p]) {
    if (fabs([entry[@"time"] doubleValue] - seconds) < 1e-6) {
      *value = entry[@"value"];
      if (self.readHook) {
        void (^hook)(void) = self.readHook;
        self.readHook = nil;
        hook();
      }
      return YES;
    }
  }
  // Keep tests honest: a gap read must use the lane cache, while exact native
  // key reads still return the payload that the host owns.
  *value = [self lane:p].lastObject[@"value"];
  return YES;
}
- (BOOL)setCustomParameterValue:(id)value toParameter:(UInt32)p atTime:(CMTime)t {
  if (p == MMOpacityControls && self.failBlobOnce == p)
    return [super setCustomParameterValue:value toParameter:p atTime:t];
  if (p == MMOpacityControls) {
    double seconds = CMTimeGetSeconds(t);
    NSMutableDictionary *found = nil;
    for (NSMutableDictionary *entry in [self lane:p])
      if (fabs([entry[@"time"] doubleValue] - seconds) < 1e-6) found = entry;
    if (found) found[@"value"] = value;
    else {
      FxKeyframe key; FxInitKeyframe(key, kFxKeyframe_CurrentVersion); key.time=t;
      [[self lane:p] addObject:[@{ @"time":@(seconds), @"value":value,
        @"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)] } mutableCopy]];
      [[self lane:p] sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"time"] compare:b[@"time"]];
      }];
    }
  }
  return [super setCustomParameterValue:value toParameter:p atTime:t];
}
@end

static MMScalarPose *opacity(double value, BOOL authored, MTEasing easing,
                             MTAddedMotion motion, MMPoseTiming *timing) {
  MMScalarPose *pose = [[MMScalarPose alloc] initWithValue:value authored:authored
                                                     easing:easing addedMotion:motion];
  return timing ? [pose poseByReplacingTiming:timing] : pose;
}

static void addOpacityKey(OpacityHost *host, double time, MMScalarPose *pose) {
  FxKeyframe key; FxInitKeyframe(key, kFxKeyframe_CurrentVersion); key.time=TestTime(time);
  [[host lane:MMOpacityControls] addObject:[@{ @"time":@(time), @"value":pose,
    @"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)] } mutableCopy]];
}

static NSArray *entries(MMScalarPose *a, MMScalarPose *b) {
  FxKeyframe ka, kb; FxInitKeyframe(ka, kFxKeyframe_CurrentVersion); FxInitKeyframe(kb, kFxKeyframe_CurrentVersion);
  ka.time=TestTime(0); kb.time=TestTime(4);
  return @[
    @{ @"time":@0, @"nativeTime":[NSValue valueWithBytes:&ka objCType:@encode(CMTime)], @"pose":a },
    @{ @"time":@4, @"nativeTime":[NSValue valueWithBytes:&kb objCType:@encode(CMTime)], @"pose":b }
  ];
}

@interface ScalarEnumCoder : NSCoder
@property NSInteger easing;
@property NSInteger motion;
@end
@implementation ScalarEnumCoder
- (NSInteger)decodeIntegerForKey:(NSString *)key { return [key isEqualToString:@"easing"] ? self.easing : self.motion; }
- (double)decodeDoubleForKey:(NSString *)key { return 50; }
- (BOOL)decodeBoolForKey:(NSString *)key { return YES; }
- (BOOL)containsValueForKey:(NSString *)key { return NO; }
@end

static void testCodingAndValidation(void) {
  ScalarEnumCoder *coder=[ScalarEnumCoder new];
  coder.easing=MTEasingSmooth; coder.motion=MTAddedMotionNone;
  assert([[MMScalarPose alloc] initWithCoder:coder]);
  // These would truncate to valid enum values if cast before validation.
  coder.easing=((NSInteger)1<<32)+MTEasingSmooth;
  assert(![[MMScalarPose alloc] initWithCoder:coder]);
  coder.easing=MTEasingSmooth; coder.motion=((NSInteger)1<<32)+MTAddedMotionNone;
  assert(![[MMScalarPose alloc] initWithCoder:coder]);
  MMScalarPose *pose = opacity(42.5, YES, MTEasingEaseIn, MTAddedMotionWave, nil);
  NSError *error=nil;
  NSData *data=[NSKeyedArchiver archivedDataWithRootObject:pose requiringSecureCoding:YES error:&error];
  assert(data && !error);
  MMScalarPose *decoded=[NSKeyedUnarchiver unarchivedObjectOfClass:MMScalarPose.class fromData:data error:&error];
  assert(decoded && [decoded isEqual:pose] && decoded.value==42.5);
  assert(![[MMScalarPose alloc] initWithValue:NAN authored:YES easing:MTEasingSmooth addedMotion:MTAddedMotionNone]);
  assert(![[MMScalarPose alloc] initWithValue:50 authored:YES easing:(MTEasing)99 addedMotion:MTAddedMotionNone]);
  assert(![[MMScalarPose alloc] initWithValue:50 authored:YES easing:MTEasingSmooth addedMotion:(MTAddedMotion)99]);
  NSData *bad=[NSKeyedArchiver archivedDataWithRootObject:@{ @"value":@42 } requiringSecureCoding:YES error:nil];
  assert(![NSKeyedUnarchiver unarchivedObjectOfClass:MMScalarPose.class fromData:bad error:nil]);
}

static void testLaneSamplingAndBounds(void) {
  MMPropertyLane *lane=MMOpacityLane();
  assert(lane.defaultValue==100 && lane.minimum==0 && lane.maximum==100);
  MMPoseTiming *slow=[[MMPoseTiming alloc] initWithDuration:2 available:NO amount:1 speed:1];
  MMPoseTiming *available=[[MMPoseTiming alloc] initWithDuration:2 available:YES amount:1 speed:1];
  MMScalarPose *left=opacity(0,YES,MTEasingSmooth,MTAddedMotionNone,nil);
  MMScalarPose *right=opacity(100,YES,MTEasingEaseOut,MTAddedMotionHandheld,slow);
  NSArray *e=entries(left,right);
  assert(fabs([lane sampleEntries:e time:TestTime(0)].value-0)<1e-6);
  assert(fabs([lane sampleEntries:e time:TestTime(4)].value-100)<1e-6);
  for (double t=0; t<=4; t+=.25) {
    double v=[lane sampleEntries:e time:TestTime(t)].value;
    assert(isfinite(v) && v>=0 && v<=100);
  }
  MMScalarPose *fast=opacity(100,YES,MTEasingEaseIn,MTAddedMotionNone,available);
  NSArray *availableEntries=entries(left,fast);
  double availableMidpoint=[lane sampleEntries:availableEntries time:TestTime(2)].value;
  assert(availableMidpoint > 0 && availableMidpoint < 100);
}

static void testWritesAndCache(void) {
  OpacityHost *host=[OpacityHost new]; MMPropertyLane *lane=MMOpacityLane();
  MMScalarPose *a=opacity(20,YES,MTEasingSmooth,MTAddedMotionNone,nil);
  MMScalarPose *b=opacity(80,YES,MTEasingEaseIn,MTAddedMotionWave,nil);
  addOpacityKey(host,0,a); addOpacityKey(host,4,b);
  MMPropertyPoseCache *cache=[lane createCache]; host.staticValues[@(MMOpacityCacheToken)]=cache.token;
  [lane refreshCacheForManager:host time:TestTime(0)];
  NSUInteger reads=host.nativeKeyReads;
  assert([lane writeValue:55 manager:host cache:cache time:TestTime(4) explicit:NO]);
  MMScalarPose *cached = cache.snapshotEntries.lastObject[@"pose"];
  assert(host.nativeKeyReads==reads && cached.value==55);
  // An explicit edit in a gap targets the owning native key and does not add one.
  assert([lane writeValue:35 manager:host cache:cache time:TestTime(2) explicit:YES]);
  assert([host lane:MMOpacityControls].count==2);
  cached = cache.snapshotEntries.lastObject[@"pose"];
  assert(cached.value==35);
  NSUInteger writes=host.hostWrites;
  host.failBlobOnce=MMOpacityControls;
  assert(![lane writeValue:44 manager:host cache:cache time:TestTime(4) explicit:NO]);
  cached = cache.snapshotEntries.lastObject[@"pose"];
  assert(host.hostWrites==writes+1 && cached.value==35);
  host.failReadParameter=MMOpacityControls;
  assert(![lane writeValue:44 manager:host cache:cache time:TestTime(4) explicit:NO]);
  host.failReadParameter=0;
  [lane refreshCacheForManager:host time:TestTime(0)];
  __weak OpacityHost *weakHost=host;
  host.readHook=^{ assert([lane writeValue:66 manager:weakHost cache:cache time:TestTime(4) explicit:NO]); };
  [lane refreshCacheForManager:host time:TestTime(4)];
  cached = cache.snapshotEntries.lastObject[@"pose"];
  assert(cached.value==66);
}
static void testStaticExplicitWrite(void) {
  MockHost *host=[MockHost new]; MMPropertyLane *lane=MMOpacityLane();
  MMPropertyPoseCache *cache=[lane createCache]; host.staticValues[@(MMOpacityCacheToken)]=cache.token;
  host.blobs[@(MMOpacityControls)]=opacity(20,NO,MTEasingSmooth,MTAddedMotionNone,nil);
  [lane refreshCacheForManager:host time:TestTime(0)];
  host.editors[@(MMExplicitCreation)]=@YES;
  assert([lane writeValue:55 manager:host cache:cache time:TestTime(7) explicit:YES]);
  assert([host lane:MMOpacityControls].count==0 && cache.snapshotEntries.count==1 && !cache.snapshotEntries[0][@"nativeTime"]);
  assert(fabs([(MMScalarPose *)cache.snapshotEntries[0][@"pose"] value]-55)<1e-6);
}

static void testTimingModel(void) {
  OpacityHost *host=[OpacityHost new]; MMPropertyLane *lane=MMOpacityLane();
  MMPropertyPoseCache *cache=[lane createCache];
  host.staticValues[@(MMOpacityCacheToken)]=cache.token;
  addOpacityKey(host,0,opacity(0,YES,MTEasingSmooth,MTAddedMotionNone,nil));
  addOpacityKey(host,4,opacity(100,YES,MTEasingSmooth,MTAddedMotionNone,nil));
  [lane refreshCacheForManager:host time:TestTime(0)];
  MMInspectorGap *gap=MMReadInspectorGap(host,MMOpacityControls,TestTime(2));
  assert(gap && gap.destinationIndex==1 && gap.parameterID==MMOpacityControls);
  assert(MMWriteInspectorSetting(host,MMOpacityControls,TestTime(2),MMInspectorDuration,2));
  MMScalarPose *edited=[host lane:MMOpacityControls][1][@"value"];
  assert(edited.timing.duration==2 && edited.value==100);
  assert(MMWriteInspectorSetting(host,MMOpacityControls,TestTime(2),MMInspectorAvailable,YES));
  MMScalarPose *editedPose = [host lane:MMOpacityControls][1][@"value"];
  assert(editedPose.timing.available);
  assert(MMWriteInspectorSetting(host,MMOpacityControls,TestTime(2),MMInspectorEasing,MTEasingEaseIn));
  editedPose = [host lane:MMOpacityControls][1][@"value"];
  assert(editedPose.easing==MTEasingEaseIn);
  assert(MMWriteInspectorSetting(host,MMOpacityControls,TestTime(2),MMInspectorMotion,MTAddedMotionWiggle));
  editedPose = [host lane:MMOpacityControls][0][@"value"];
  assert(editedPose.addedMotion==MTAddedMotionWiggle);
  NSUInteger count=[host lane:MMOpacityControls].count;
  FxKeyframe moved; [host keyframe:&moved forParameter:MMOpacityControls channel:0 andIndex:1];
  moved.time=TestTime(6);
  assert(![host setKeyframeIndex:1 withKeyframe:&moved forParameter:MMOpacityControls andChannel:0]);
  editedPose = [host lane:MMOpacityControls][1][@"value"];
  assert([host lane:MMOpacityControls].count==count && editedPose.timing.duration==2);
}

static void testRenderOpacity(void) {
  OpacityHost *host=[OpacityHost new];
  MagicMovePlugin *plugin=[[MagicMovePlugin alloc] initWithAPIManager:host];
  host.plugin=plugin;
  assert([plugin addParametersWithError:nil]);
  host.blobs[@(MMOpacityControls)]=opacity(100,NO,MTEasingSmooth,MTAddedMotionNone,nil);
  NSData *state=nil;
  assert([plugin pluginState:&state atTime:TestTime(0) quality:kFxQuality_HIGH error:nil]);
  MMTransform transform; [state getBytes:&transform length:sizeof(transform)];
  assert(fabs(transform.opacity-1.0)<1e-6);
  host.blobs[@(MMOpacityControls)]=opacity(50,YES,MTEasingSmooth,MTAddedMotionNone,nil);
  assert([plugin pluginState:&state atTime:TestTime(0) quality:kFxQuality_HIGH error:nil]);
  [state getBytes:&transform length:sizeof(transform)];
  assert(fabs(transform.opacity-.5)<1e-6);
}

int main(void) {
  @autoreleasepool { testCodingAndValidation(); testLaneSamplingAndBounds(); testWritesAndCache(); testStaticExplicitWrite(); testTimingModel(); testRenderOpacity(); }
  puts("Opacity: secure payload, scalar sampling, timing, cached writes, failures and native moves passed");
  return 0;
}
