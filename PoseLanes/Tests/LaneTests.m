/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "TestLanes.h"
#import <assert.h>
#import <math.h>

// Every property is the same lane adapter over the same pose class, so these
// checks run per lane and only genuinely lane-specific behaviour gets its own
// case.
@interface LaneHost : MockHost <FxCustomParameterActionAPI_v4>
@property CMTime currentTime;
@property NSUInteger actions;
@property NSUInteger ends;
@property NSMutableArray *order;
@property(nonatomic, copy) void (^readHook)(void);
@end
@implementation LaneHost
- (instancetype)init { if((self=[super init])) { _currentTime=TestTime(2); _order=[NSMutableArray new]; } return self; }
- (void)startAction:(id)sender { self.actions++; }
- (void)endAction:(id)sender { self.ends++; }
- (BOOL)addCustomParameterWithName:(NSString *)name parameterID:(UInt32)p defaultValue:(id)value parameterFlags:(FxParameterFlags)flags {
  [self.order addObject:@(p)];
  return [super addCustomParameterWithName:name parameterID:p defaultValue:value parameterFlags:flags];
}
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding,NSCopying> **)value fromParameter:(UInt32)p atTime:(CMTime)t {
  if(self.failReadParameter==p) return NO;
  for(NSDictionary *entry in [self lane:p])
    if(fabs([entry[@"time"] doubleValue]-CMTimeGetSeconds(t))<1e-6) {
      *value=entry[@"value"];
      if(self.readHook) { void (^hook)(void)=self.readHook; self.readHook=nil; hook(); }
      return YES;
    }
  return [super getCustomParameterValue:value fromParameter:p atTime:t];
}
- (BOOL)setCustomParameterValue:(id)value toParameter:(UInt32)p atTime:(CMTime)t {
  if(self.failBlobOnce==p) return [super setCustomParameterValue:value toParameter:p atTime:t];
  for(NSMutableDictionary *entry in [self lane:p])
    if(fabs([entry[@"time"] doubleValue]-CMTimeGetSeconds(t))<1e-6) entry[@"value"]=value;
  return [super setCustomParameterValue:value toParameter:p atTime:t];
}
@end

static id<KFPropertyPose> Pose(KFPropertyLane *lane, NSArray<NSNumber *> *values, KFPoseTiming *timing) {
  return [lane.defaultPose poseByReplacingValues:values authored:YES easing:MTEasingLinear
                                     addedMotion:MTAddedMotionNone timing:timing ?: [KFPoseTiming new]];
}
// Values inside the lane's own range, offset per component so a write that
// touches the wrong axis is visible.
static NSArray<NSNumber *> *Values(KFPropertyLane *lane, double fraction) {
  double span=lane.maximum-lane.minimum, base=lane.minimum+span*fraction;
  NSMutableArray<NSNumber *> *values=[NSMutableArray arrayWithCapacity:lane.componentCount];
  for(NSUInteger axis=0;axis<lane.componentCount;axis++) [values addObject:@(base+axis*span/16)];
  return values;
}
static void Key(LaneHost *host, KFPropertyLane *lane, double time, id<KFPropertyPose> pose) {
  FxKeyframe key; FxInitKeyframe(key,kFxKeyframe_CurrentVersion); key.time=TestTime(time);
  [[host lane:lane.parameterID] addObject:[@{@"time":@(time), @"value":pose,
      @"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)]} mutableCopy]];
  host.blobs[@(lane.parameterID)]=pose;
}
static KFPropertyPoseCache *Cache(LaneHost *host, KFPropertyLane *lane) {
  KFPropertyPoseCache *cache=[lane createCache];
  host.staticValues[@(lane.cacheTokenID)]=cache.token;
  [lane refreshCacheForManager:host time:TestTime(0)];
  return cache;
}


static void testSamplingAndBounds(void) {
  KFPoseTiming *held=[[KFPoseTiming alloc] initWithDuration:2 available:NO amount:1 speed:1];
  KFPoseTiming *available=[[KFPoseTiming alloc] initWithDuration:2 available:YES amount:1 speed:1];
  for(KFPropertyLane *lane in KFPropertyLanes()) {
    LaneHost *host=[LaneHost new];
    NSArray<NSNumber *> *start=Values(lane,0.25), *end=Values(lane,0.75);
    Key(host,lane,0,Pose(lane,start,nil));
    Key(host,lane,4,Pose(lane,end,held));
    KFPropertyPoseCache *cache=Cache(host,lane);
    NSArray *entries=cache.snapshotEntries;
    assert([[lane sampleEntries:entries time:TestTime(0)].values isEqualToArray:start]);
    assert([[lane sampleEntries:entries time:TestTime(4)].values isEqualToArray:end]);
    // Outside the sequence the endpoint values hold, and the transition only
    // begins once the requested duration needs it.
    assert([[lane sampleEntries:entries time:TestTime(-2)].values isEqualToArray:start]);
    assert([[lane sampleEntries:entries time:TestTime(9)].values isEqualToArray:end]);
    assert([[lane sampleEntries:entries time:TestTime(1.5)].values isEqualToArray:start]);
    for(double t=0;t<=4;t+=.25) {
      id<KFPropertyPose> sample=[lane sampleEntries:entries time:TestTime(t)];
      assert(sample.values.count==lane.componentCount);
      for(NSNumber *value in sample.values) {
        assert(isfinite(value.doubleValue));
        if(lane.boundsValues) assert(value.doubleValue>=lane.minimum && value.doubleValue<=lane.maximum);
      }
    }
    // Available time fills the whole gap, so the midpoint is already moving.
    LaneHost *filling=[LaneHost new];
    Key(filling,lane,0,Pose(lane,start,nil));
    Key(filling,lane,4,Pose(lane,end,available));
    NSArray *fillingEntries=Cache(filling,lane).snapshotEntries;
    double moving=[lane sampleEntries:fillingEntries time:TestTime(2)].values[0].doubleValue;
    assert(moving>[start[0] doubleValue] && moving<[end[0] doubleValue]);
  }
}

// Rotation keeps full turns rather than wrapping, which is why its lane does
// not bound sampled values.
static void testRotationKeepsTurns(void) {
  KFPropertyLane *lane=KFTestRotationLane();
  LaneHost *host=[LaneHost new];
  KFPoseTiming *linear=[[KFPoseTiming alloc] initWithDuration:4 available:YES amount:1 speed:1];
  Key(host,lane,0,Pose(lane,@[@0,@0,@0],nil));
  Key(host,lane,4,Pose(lane,@[@720,@0,@0],linear));
  NSArray *entries=Cache(host,lane).snapshotEntries;
  assert(fabs([lane sampleEntries:entries time:TestTime(2)].values[0].doubleValue-360)<1e-6);
  assert(fabs([lane sampleEntries:entries time:TestTime(4)].values[0].doubleValue-720)<1e-6);
  assert(fabs([lane sampleEntries:entries time:TestTime(4)].values[1].doubleValue)<1e-6);
}

static void testWritesAndCache(void) {
  for(KFPropertyLane *lane in KFPropertyLanes()) {
    LaneHost *host=[LaneHost new];
    NSArray<NSNumber *> *start=Values(lane,0.25), *end=Values(lane,0.75);
    KFPoseTiming *timing=[[KFPoseTiming alloc] initWithDuration:4 available:YES amount:1 speed:1];
    Key(host,lane,0,Pose(lane,start,nil));
    Key(host,lane,4,Pose(lane,end,timing));
    KFPropertyPoseCache *cache=Cache(host,lane);
    NSUInteger reads=host.nativeKeyReads;
    NSUInteger component=lane.componentCount-1;
    double target=[Values(lane,0.5)[component] doubleValue];
    id<KFPropertyPose> sampled=[lane sampleEntries:cache.snapshotEntries time:TestTime(2)];
    assert([lane writeComponent:component value:target manager:host cache:cache time:TestTime(2) explicit:NO]);
    // The write publishes into the cache directly: no key enumeration, and the
    // untouched axes come from our own engine rather than host interpolation.
    assert(host.nativeKeyReads==reads);
    id<KFPropertyPose> written=cache.snapshotEntries[1][@"pose"];
    assert(fabs(written.values[component].doubleValue-target)<1e-6);
    for(NSUInteger axis=0;axis<component;axis++)
      assert(fabs(written.values[axis].doubleValue-sampled.values[axis].doubleValue)<1e-6);
    assert(cache.snapshotEntries.count==3); // The published snapshot gained the edited key.
    // Explicit editing targets the next existing key instead of the playhead.
    host.editors[@(KFTestExplicitCreation)]=@YES;
    NSUInteger keys=[host lane:lane.parameterID].count;
    assert([lane writeComponent:0 value:[end[0] doubleValue] manager:host cache:cache time:TestTime(3) explicit:YES]);
    assert([host lane:lane.parameterID].count==keys);
    host.editors[@(KFTestExplicitCreation)]=@NO;
    // A rejected host write leaves the published snapshot alone.
    id<KFPropertyPose> before=cache.snapshotEntries.lastObject[@"pose"];
    NSUInteger writes=host.hostWrites;
    host.failBlobOnce=lane.parameterID;
    assert(![lane writeValue:[end[0] doubleValue] manager:host cache:cache time:TestTime(4) explicit:NO]);
    assert(host.hostWrites==writes+1 && cache.snapshotEntries.lastObject[@"pose"]==before);
    host.failReadParameter=lane.parameterID;
    assert(![lane writeValue:[end[0] doubleValue] manager:host cache:cache time:TestTime(4) explicit:NO]);
    host.failReadParameter=0;
    // Out-of-range writes clamp only where the lane bounds its values.
    [lane refreshCacheForManager:host time:TestTime(0)];
    double beyond=lane.maximum+100;
    assert([lane writeComponent:0 value:beyond manager:host cache:cache time:TestTime(4) explicit:NO]);
    double stored=[(id<KFPropertyPose>)cache.snapshotEntries.lastObject[@"pose"] values][0].doubleValue;
    assert(lane.boundsValues ? stored==lane.maximum : stored==beyond);
    // A render or refresh that started before an edit must not publish over it.
    [lane refreshCacheForManager:host time:TestTime(0)];
    __weak LaneHost *weakHost=host;
    double raced=[Values(lane,0.5)[0] doubleValue];
    host.readHook=^{ assert([lane writeComponent:0 value:raced manager:weakHost cache:cache time:TestTime(4) explicit:NO]); };
    [lane refreshCacheForManager:host time:TestTime(4)];
    assert(fabs([(id<KFPropertyPose>)cache.snapshotEntries.lastObject[@"pose"] values][0].doubleValue-raced)<1e-6);
  }
}

static void testStaticPayloadWrites(void) {
  for(KFPropertyLane *lane in KFPropertyLanes()) {
    LaneHost *host=[LaneHost new];
    KFPropertyPoseCache *cache=[lane createCache];
    host.staticValues[@(lane.cacheTokenID)]=cache.token;
    host.blobs[@(lane.parameterID)]=lane.defaultPose;
    [lane refreshCacheForManager:host time:TestTime(0)];
    host.editors[@(KFTestExplicitCreation)]=@YES;
    double value=[Values(lane,0.5)[0] doubleValue];
    // An unkeyed property is editable from anywhere and stays unkeyed.
    assert([lane writeValue:value manager:host cache:cache time:TestTime(7) explicit:YES]);
    assert([host lane:lane.parameterID].count==0);
    assert(cache.snapshotEntries.count==1 && !cache.snapshotEntries[0][@"nativeTime"]);
    id<KFPropertyPose> pose=cache.snapshotEntries[0][@"pose"];
    assert(fabs(pose.value-value)<1e-6 && pose.authored);
  }
}

static void testTimingModelPerLane(void) {
  for(KFPropertyLane *lane in KFPropertyLanes()) {
    LaneHost *host=[LaneHost new];
    NSArray<NSNumber *> *start=Values(lane,0.25), *end=Values(lane,0.75);
    Key(host,lane,0,Pose(lane,start,nil));
    Key(host,lane,4,Pose(lane,end,nil));
    KFPropertyPoseCache *cache=Cache(host,lane);
    KFInspectorGap *gap=KFReadInspectorGap(host,lane.parameterID,TestTime(2));
    assert(gap && gap.destinationIndex==1 && gap.parameterID==lane.parameterID);
    assert(!KFReadInspectorGap(host,lane.parameterID,TestTime(9)));
    NSArray<NSArray<NSNumber *> *> *graph=KFInspectorGraphComponents(gap,5);
    assert(graph.count==5 && graph.firstObject.count==lane.componentCount);
    assert([graph.firstObject isEqualToArray:start] && [graph.lastObject isEqualToArray:end]);
    assert(KFWriteInspectorSetting(host,lane.parameterID,TestTime(2),KFInspectorDuration,2));
    assert(KFWriteInspectorSetting(host,lane.parameterID,TestTime(2),KFInspectorAvailable,YES));
    assert(KFWriteInspectorSetting(host,lane.parameterID,TestTime(2),KFInspectorEasing,MTEasingEaseOut));
    // Incoming timing belongs to the destination; Added Motion to the key that
    // precedes the gap.
    assert(KFWriteInspectorSetting(host,lane.parameterID,TestTime(2),KFInspectorMotion,MTAddedMotionWave));
    [lane refreshCacheForManager:host time:TestTime(0)];
    id<KFPropertyPose> source=cache.snapshotEntries.firstObject[@"pose"];
    id<KFPropertyPose> destination=cache.snapshotEntries.lastObject[@"pose"];
    assert(destination.timing.duration==2 && destination.timing.available);
    assert(destination.easing==MTEasingEaseOut && destination.addedMotion==MTAddedMotionNone);
    assert(source.addedMotion==MTAddedMotionWave);
    assert([destination.values isEqualToArray:end]);
    // Moving the key keeps its settings, and a rejected host move changes nothing.
    NSUInteger keys=[host lane:lane.parameterID].count;
    FxKeyframe moved; [host keyframe:&moved forParameter:lane.parameterID channel:0 andIndex:1];
    moved.time=TestTime(6);
    assert(![host setKeyframeIndex:1 withKeyframe:&moved forParameter:lane.parameterID andChannel:0]);
    assert([host lane:lane.parameterID].count==keys);
    assert([(id<KFPropertyPose>)[host lane:lane.parameterID][1][@"value"] timing].duration==2);
  }
}

static void testLinkingAndReset(void) {
  LaneHost *host=[LaneHost new];
  KFPropertyLane *position=KFTestPositionLane(), *scale=KFTestScaleLane();
  Key(host,position,0,Pose(position,@[@0,@0],nil));
  Key(host,position,4,Pose(position,@[@25,@(-50)],nil));
  Key(host,scale,1,Pose(scale,@[@100,@100],nil));
  Key(host,scale,4,Pose(scale,@[@150,@120],nil));
  KFPropertyPoseCache *positionCache=Cache(host,position), *scaleCache=Cache(host,scale);
  assert(KFSetNativePropertyLink(host,KFTestPosition,KFTestScale,TestTime(2),YES));
  assert(KFNativePropertyLinked(host,KFTestPosition,TestTime(2)));
  assert(KFNativePropertyLinked(host,KFTestScale,TestTime(2)));
  // Linked keyposes share incoming timing while keeping their own values.
  assert(KFWriteInspectorSetting(host,KFTestPosition,TestTime(2),KFInspectorDuration,.75));
  assert([(id<KFPropertyPose>)scaleCache.snapshotEntries.lastObject[@"pose"] timing].duration==.75);
  assert([[(id<KFPropertyPose>)scaleCache.snapshotEntries.lastObject[@"pose"] values] isEqualToArray:(@[@150,@120])]);
  NSArray *gaps=KFReadInspectorGraphGaps(host,KFTestPosition,TestTime(2));
  assert(gaps.count==2 && KFInspectorGraphStartFractions(gaps).count==4);
  assert([KFInspectorCombinedGraphPoints(gaps,9,CGSizeMake(1920,1080))[0] count]==4);
  // A native move of one member carries its linked partner on release.
  KFObserveNativeLinks(host,KFTestPosition,NO);
  FxKeyframe moved; [host keyframe:&moved forParameter:KFTestPosition channel:0 andIndex:1];
  moved.time=TestTime(5);
  assert(![host setKeyframeIndex:1 withKeyframe:&moved forParameter:KFTestPosition andChannel:0]);
  [position refreshCacheForManager:host time:TestTime(2)];
  KFObserveNativeLinks(host,KFTestPosition,YES);
  assert(KFHasPendingNativeLinkMoves(host));
  assert(KFCommitNativeLinkMoves(host,YES,nil));
  assert([[host lane:KFTestScale].lastObject[@"time"] doubleValue]==4);
  assert(KFCommitNativeLinkMoves(host,NO,nil));
  assert([[host lane:KFTestScale].lastObject[@"time"] doubleValue]==5);
  for(KFPropertyLane *lane in KFPropertyLanes()) {
    if(![host lane:lane.parameterID].count) {
      Key(host,lane,0,Pose(lane,Values(lane,0.25),nil));
      Key(host,lane,4,Pose(lane,Values(lane,0.75),nil));
      Cache(host,lane);
    }
    host.failBlobOnce=lane.parameterID;
    assert(!KFResetParameter(host,[NSView new],lane.parameterID));
    assert([host lane:lane.parameterID].count==2); // Rollback restores the keys.
    assert(KFResetParameter(host,[NSView new],lane.parameterID));
    assert([host lane:lane.parameterID].count==0 && host.undoDepth==0);
    assert(host.undoGroupsStarted==host.undoGroupsEnded);
    id<KFPropertyPose> restored=[lane readValue:host time:TestTime(2)];
    assert([restored.values isEqualToArray:lane.defaultPose.values]);
    assert(restored.timing.linkID.length==0 && restored.addedMotion==MTAddedMotionNone);
  }
  assert(positionCache.snapshotEntries.count==1 && scaleCache.snapshotEntries.count==1);
}

int main(void) {
  @autoreleasepool {
    KFTestRegisterLanes();
    [NSApplication sharedApplication];
    testSamplingAndBounds();
    testRotationKeepsTurns();
    testWritesAndCache();
    testStaticPayloadWrites();
    testTimingModelPerLane();
    testLinkingAndReset();
  }
  puts("Lanes: sampling, bounds, turns, cached writes, failures, timing, links and reset passed");
  return 0;
}
