/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMRotationPose.h"
#import "MMPropertyLane.h"
#import "MMScalarPose.h"
#import "MMTimingEditorModel.h"
#import "MockHost.h"
#import "ShaderTypes.h"
#import <assert.h>
#import <math.h>

@interface RotationHost : MockHost
@property(nonatomic, copy) void (^readHook)(void);
@end

@implementation RotationHost
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding, NSCopying> **)value
                  fromParameter:(UInt32)p atTime:(CMTime)t {
  if (p != MMRotationControls || ![self lane:p].count)
    return [super getCustomParameterValue:value fromParameter:p atTime:t];
  if (self.failReadParameter == p) return NO;
  double seconds=CMTimeGetSeconds(t);
  for (NSDictionary *entry in [self lane:p]) {
    if (fabs([entry[@"time"] doubleValue]-seconds)<1e-6) {
      *value=entry[@"value"];
      if (self.readHook) { void (^hook)(void)=self.readHook; self.readHook=nil; hook(); }
      return YES;
    }
  }
  *value=[self lane:p].lastObject[@"value"];
  return YES;
}
- (BOOL)setCustomParameterValue:(id)value toParameter:(UInt32)p atTime:(CMTime)t {
  if (p==MMRotationControls && self.failBlobOnce==p)
    return [super setCustomParameterValue:value toParameter:p atTime:t];
  if (p==MMRotationControls) {
    double seconds=CMTimeGetSeconds(t); NSMutableDictionary *found=nil;
    for (NSMutableDictionary *entry in [self lane:p])
      if (fabs([entry[@"time"] doubleValue]-seconds)<1e-6) found=entry;
    if (found) found[@"value"]=value;
    else {
      FxKeyframe key; FxInitKeyframe(key,kFxKeyframe_CurrentVersion); key.time=t;
      [[self lane:p] addObject:[@{ @"time":@(seconds), @"value":value,
        @"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)] } mutableCopy]];
      [[self lane:p] sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        return [a[@"time"] compare:b[@"time"]];
      }];
    }
  }
  return [super setCustomParameterValue:value toParameter:p atTime:t];
}
@end

static MMRotationPose *rotation(double x,double y,double z,BOOL authored,
                                MTEasing easing,MTAddedMotion motion,MMPoseTiming *timing) {
  MMRotationPose *pose=[[MMRotationPose alloc] initWithX:x y:y z:z authored:authored easing:easing addedMotion:motion];
  return timing ? [pose poseByReplacingTiming:timing] : pose;
}
static void addKey(RotationHost *host,double time,MMRotationPose *pose) {
  FxKeyframe key; FxInitKeyframe(key,kFxKeyframe_CurrentVersion); key.time=TestTime(time);
  [[host lane:MMRotationControls] addObject:[@{ @"time":@(time), @"value":pose,
    @"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)] } mutableCopy]];
}
static NSArray *twoKeys(MMRotationPose *a,MMRotationPose *b) {
  FxKeyframe ka,kb; FxInitKeyframe(ka,kFxKeyframe_CurrentVersion); FxInitKeyframe(kb,kFxKeyframe_CurrentVersion);
  ka.time=TestTime(0); kb.time=TestTime(4);
  return @[
    @{ @"time":@0,@"nativeTime":[NSValue valueWithBytes:&ka objCType:@encode(CMTime)],@"pose":a },
    @{ @"time":@4,@"nativeTime":[NSValue valueWithBytes:&kb objCType:@encode(CMTime)],@"pose":b }
  ];
}

static void testCoding(void) {
  MMRotationPose *pose=rotation(360,720,-450,YES,MTEasingEaseIn,MTAddedMotionWave,nil);
  NSError *error=nil; NSData *data=[NSKeyedArchiver archivedDataWithRootObject:pose requiringSecureCoding:YES error:&error];
  assert(data&&!error);
  MMRotationPose *decoded=[NSKeyedUnarchiver unarchivedObjectOfClass:MMRotationPose.class fromData:data error:&error];
  assert(decoded&&[decoded isEqual:pose]&&decoded.x==360&&decoded.y==720&&decoded.z==-450);
  assert(![[MMRotationPose alloc] initWithX:NAN y:0 z:0 authored:YES easing:MTEasingSmooth addedMotion:MTAddedMotionNone]);
  assert(![[MMRotationPose alloc] initWithX:0 y:0 z:0 authored:YES easing:(MTEasing)99 addedMotion:MTAddedMotionNone]);
  assert(![[MMRotationPose alloc] initWithX:0 y:0 z:0 authored:YES easing:MTEasingSmooth addedMotion:(MTAddedMotion)99]);
  NSData *bad=[NSKeyedArchiver archivedDataWithRootObject:@{ @"x":@1 } requiringSecureCoding:YES error:nil];
  assert(![NSKeyedUnarchiver unarchivedObjectOfClass:MMRotationPose.class fromData:bad error:nil]);
}

static void testSampling(void) {
  MMPropertyLane *lane=MMRotationLane();
  assert(lane.componentCount==3&&lane.defaultValue==0&&!lane.boundsValues);
  MMPoseTiming *available=[[MMPoseTiming alloc] initWithDuration:1 available:YES amount:1 speed:1];
  NSArray *e=twoKeys(rotation(0,0,0,YES,MTEasingLinear,MTAddedMotionNone,nil),
                     rotation(720,0,0,YES,MTEasingLinear,MTAddedMotionNone,available));
  id<MMPropertyPose> mid=[lane sampleEntries:e time:TestTime(2)];
  assert(fabs(mid.values[0].doubleValue-360)<1e-6);
  assert(fabs(mid.values[1].doubleValue)<1e-6&&fabs(mid.values[2].doubleValue)<1e-6);
  id<MMPropertyPose> end=[lane sampleEntries:e time:TestTime(4)];
  assert(fabs(end.values[0].doubleValue-720)<1e-6);
  for(double t=0;t<=4;t+=.25) {
    id<MMPropertyPose> sample=[lane sampleEntries:e time:TestTime(t)];
    for(NSNumber *v in sample.values) assert(isfinite(v.doubleValue));
  }
}

static void testComponentWrites(void) {
  RotationHost *host=[RotationHost new]; MMPropertyLane *lane=MMRotationLane();
  MMPropertyPoseCache *cache=[lane createCache]; host.staticValues[@(MMRotationCacheToken)]=cache.token;
  addKey(host,0,rotation(0,10,20,YES,MTEasingSmooth,MTAddedMotionNone,nil));
  MMPoseTiming *available=[[MMPoseTiming alloc] initWithDuration:4 available:YES amount:1 speed:1];
  addKey(host,4,rotation(360,40,80,YES,MTEasingLinear,MTAddedMotionWave,available));
  [lane refreshCacheForManager:host time:TestTime(0)];
  NSUInteger reads=host.nativeKeyReads;
  assert([lane writeComponent:1 value:25 manager:host cache:cache time:TestTime(2) explicit:NO]);
  assert(host.nativeKeyReads==reads);
  MMRotationPose *gapPose=cache.snapshotEntries[1][@"pose"];
  assert(fabs(gapPose.y-25)<1e-6&&fabs(gapPose.x-180)<1e-6&&fabs(gapPose.z-50)<1e-6);
  // Explicit creation targets the destination key and preserves its other axes.
  assert([lane writeComponent:2 value:90 manager:host cache:cache time:TestTime(3) explicit:YES]);
  MMRotationPose *destination=cache.snapshotEntries.lastObject[@"pose"];
  assert(destination.z==90&&destination.x==360&&destination.y==40&&[host lane:MMRotationControls].count==3);
  NSUInteger writes=host.hostWrites; host.failBlobOnce=MMRotationControls;
  assert(![lane writeComponent:0 value:123 manager:host cache:cache time:TestTime(4) explicit:NO]);
  assert(host.hostWrites==writes+1&&cache.snapshotEntries.lastObject[@"pose"]==destination);
  host.failReadParameter=MMRotationControls;
  assert(![lane writeComponent:0 value:123 manager:host cache:cache time:TestTime(4) explicit:NO]);
  host.failReadParameter=0; [lane refreshCacheForManager:host time:TestTime(0)];
  __weak RotationHost *weakHost=host;
  host.readHook=^{ assert([lane writeComponent:0 value:270 manager:weakHost cache:cache time:TestTime(4) explicit:NO]); };
  [lane refreshCacheForManager:host time:TestTime(4)];
  MMRotationPose *newest=cache.snapshotEntries.lastObject[@"pose"];
  assert(newest.x==270);
}

static void testTimingAndMove(void) {
  RotationHost *host=[RotationHost new]; MMPropertyLane *lane=MMRotationLane();
  MMPropertyPoseCache *cache=[lane createCache]; host.staticValues[@(MMRotationCacheToken)]=cache.token;
  addKey(host,0,rotation(0,0,0,YES,MTEasingSmooth,MTAddedMotionNone,nil));
  addKey(host,4,rotation(90,180,360,YES,MTEasingSmooth,MTAddedMotionNone,nil));
  [lane refreshCacheForManager:host time:TestTime(0)];
  MMInspectorGap *gap=MMReadInspectorGap(host,MMRotationControls,TestTime(2));
  assert(gap&&gap.destinationIndex==1);
  NSArray<NSArray<NSNumber *> *> *graph=MMInspectorGraphComponents(gap,5);
  assert(graph.count==5&&graph.firstObject.count==3&&graph.lastObject.count==3);
  assert(graph.firstObject[0].doubleValue==0&&graph.firstObject[1].doubleValue==0&&graph.firstObject[2].doubleValue==0);
  assert(graph.lastObject[0].doubleValue==90&&graph.lastObject[1].doubleValue==180&&graph.lastObject[2].doubleValue==360);
  assert(MMWriteInspectorSetting(host,MMRotationControls,TestTime(2),MMInspectorDuration,2));
  MMRotationPose *pose=[host lane:MMRotationControls][1][@"value"];
  assert(pose.timing.duration==2);
  assert(MMWriteInspectorSetting(host,MMRotationControls,TestTime(2),MMInspectorAvailable,YES));
  pose=[host lane:MMRotationControls][1][@"value"]; assert(pose.timing.available);
  assert(MMWriteInspectorSetting(host,MMRotationControls,TestTime(2),MMInspectorEasing,MTEasingEaseOut));
  pose=[host lane:MMRotationControls][1][@"value"]; assert(pose.easing==MTEasingEaseOut);
  assert(MMWriteInspectorSetting(host,MMRotationControls,TestTime(2),MMInspectorMotion,MTAddedMotionHandheld));
  pose=[host lane:MMRotationControls][0][@"value"]; assert(pose.addedMotion==MTAddedMotionHandheld);
  FxKeyframe moved; [host keyframe:&moved forParameter:MMRotationControls channel:0 andIndex:1]; moved.time=TestTime(6);
  assert(![host setKeyframeIndex:1 withKeyframe:&moved forParameter:MMRotationControls andChannel:0]);
  pose=[host lane:MMRotationControls][1][@"value"];
  assert(pose.timing.duration==2&&[host lane:MMRotationControls].count==2);
}

static void testRenderState(void) {
  RotationHost *host=[RotationHost new]; MagicMovePlugin *plugin=[[MagicMovePlugin alloc] initWithAPIManager:host]; host.plugin=plugin;
  assert([plugin addParametersWithError:nil]);
  host.blobs[@(MMRotationControls)]=rotation(180,270,360,YES,MTEasingSmooth,MTAddedMotionNone,nil);
  host.blobs[@(MMOpacityControls)]=[[MMScalarPose alloc] initWithValue:50 authored:YES easing:MTEasingSmooth addedMotion:MTAddedMotionNone];
  NSData *state=nil; assert([plugin pluginState:&state atTime:TestTime(0) quality:kFxQuality_HIGH error:nil]);
  MMTransform transform; [state getBytes:&transform length:sizeof(transform)];
  assert(fabs(transform.rotationX-(float)(180*M_PI/180))<1e-5&&fabs(transform.rotationY-(float)(270*M_PI/180))<1e-5&&fabs(transform.rotation)<1e-5);
  assert(fabs(transform.opacity-.5)<1e-6);
}

int main(void) {
  @autoreleasepool { testCoding(); testSampling(); testComponentWrites(); testTimingAndMove(); testRenderState(); }
  puts("Rotation: coding, unwrapped turns, sampling, component writes, timing, moves and render state passed");
  return 0;
}
