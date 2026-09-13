/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "MMCombinedPose.h"
#import "ShaderTypes.h"
#import <math.h>

@interface MockHost (CombinedTestSorting)
- (void)sort:(NSUInteger)parameter;
- (void)notifyParameter:(UInt32)parameter atTime:(CMTime)time;
@end

// Model custom values at native key times separately from the scalar mock.
@interface CombinedHost : MockHost
@property(nonatomic) CMTime lastCombinedWrite;
@end
@implementation CombinedHost
- (NSError *)addKeyframe:(const FxKeyframe *)key toParameter:(NSUInteger)p andChannel:(NSUInteger)channel {
  if (p != MMCustomControls) return [super addKeyframe:key toParameter:p andChannel:channel];
  if (self.failAddOnce) { self.failAddOnce = NO; return [NSError errorWithDomain:@"Mock" code:1 userInfo:nil]; }
  NSObject<NSSecureCoding,NSCopying> *value;
  [self getCustomParameterValue:&value fromParameter:(UInt32)p atTime:key->time];
  [[self lane:p] addObject:[@{@"time":@(CMTimeGetSeconds(key->time)), @"value":value,
      @"key":[NSValue valueWithBytes:key objCType:@encode(FxKeyframe)]} mutableCopy]];
  [self sort:p]; self.mutations++;
  [self notifyParameter:(UInt32)p atTime:key->time];
  return nil;
}
- (BOOL)setCustomParameterValue:(id)value toParameter:(UInt32)p atTime:(CMTime)time {
  if (self.failBlobOnce == p) return [super setCustomParameterValue:value toParameter:p atTime:time];
  if (p == MMCustomControls) self.lastCombinedWrite = time;
  if (p == MMCustomControls)
    for (NSMutableDictionary *key in [self lane:p])
      if (fabs([key[@"time"] doubleValue]-CMTimeGetSeconds(time))<1e-6) key[@"value"] = value;
  return [super setCustomParameterValue:value toParameter:p atTime:time];
}
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding,NSCopying> **)value fromParameter:(UInt32)p atTime:(CMTime)t {
  if (p != MMCustomControls) return [super getCustomParameterValue:value fromParameter:p atTime:t];
  if (self.failReadParameter == p) return NO;
  NSArray *keys = [self lane:p];
  if (!keys.count) return [super getCustomParameterValue:value fromParameter:p atTime:t];
  *value = keys[0][@"value"];
  for (NSDictionary *key in keys) {
    if ([key[@"time"] doubleValue] > CMTimeGetSeconds(t)) break;
    *value = key[@"value"];
  }
  return YES;
}
@end
static MMCombinedPose *Pose(double x, double scale) {
  return [[MMCombinedPose alloc] initWithPositionX:x scale:scale authored:YES];
}
static void Key(CombinedHost *host, double time, double x, double scale) {
  FxKeyframe key; FxInitKeyframe(key, kFxKeyframe_CurrentVersion); key.time = TestTime(time);
  [[host lane:MMCustomControls] addObject:[@{@"time":@(time), @"value":Pose(x,scale),
    @"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)]} mutableCopy]];
  [host sort:MMCustomControls];
}
static void Check(CombinedHost *host, double time, double x, double scale) {
  BOOL active = NO; NSError *error = nil;
  MMCombinedPose *pose = MMReadCombinedPose(host, TestTime(time), &active, &error);
  assert(pose && !error && active);
  assert(fabs(pose.positionX-x)<1e-6 && fabs(pose.scale-scale)<1e-6);
  NSData *state = nil;
  assert([host.plugin pluginState:&state atTime:TestTime(time) quality:0 error:&error]);
  MMTransform transform; [state getBytes:&transform length:sizeof(transform)];
  assert(fabs(transform.offset.x-x/100)<1e-6 && fabs(transform.scale-scale/100)<1e-6);
}
int main(void) {
  @autoreleasepool {
    MMCombinedPose *original = Pose(-35, 180);
    NSError *error = nil;
    NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:original requiringSecureCoding:YES error:&error];
    assert(archive && !error);
    MMCombinedPose *decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:MMCombinedPose.class fromData:archive error:&error];
    assert(decoded && !error && [decoded isEqual:original] && [decoded hash] == [original hash]);
    assert([original copy] == original);
    MMCombinedPose *middle = (id)[Pose(0,100) interpolateBetween:Pose(100,200) withWeight:0.25];
    assert(middle.positionX == 25 && middle.scale == 125);
    assert(![[MMCombinedPose alloc] initWithPositionX:NAN scale:100 authored:YES]);

    CombinedHost *host = [CombinedHost new];
    MagicMovePlugin *plugin = [[MagicMovePlugin alloc] initWithAPIManager:host]; host.plugin = plugin;
    assert([plugin addParametersWithError:&error] && !error);
    BOOL active = YES;
    assert(MMReadCombinedPose(host, TestTime(0), &active, &error) && !active);
    host.blobs[@(MMCustomControls)] = @1600; // Previously saved placeholder.
    assert(MMReadCombinedPose(host, TestTime(0), &active, &error) && !active);
    [host setCustomParameterValue:Pose(20,150) toParameter:MMCustomControls atTime:TestTime(0)];
    Check(host, 0, 20, 150);
    Key(host, 0, 0, 100); Key(host, 2, 100, 200);
    Check(host, -1, 0, 100); Check(host, 0.5, 0, 100);
    Check(host, 1.4, 50, 150); Check(host, 2, 100, 200); Check(host, 4, 100, 200);
    Key(host, 1, 40, 120); // Incoming duration caps to each smaller gap.
    Check(host, 0.5, 20, 110); Check(host, 1.5, 70, 160);
    // Host movement carries the entire pose object, with no scalar key writes.
    NSMutableDictionary *moved = [host lane:MMCustomControls][1];
    FxKeyframe metadata; [moved[@"key"] getValue:&metadata]; metadata.time = TestTime(3);
    moved[@"time"] = @3; moved[@"key"] = [NSValue valueWithBytes:&metadata objCType:@encode(FxKeyframe)];
    [host sort:MMCustomControls]; Check(host, 3, 40, 120);
    assert([host lane:MMPositionX].count == 0 && [host lane:MMScale].count == 0);
    [[host lane:MMCustomControls] removeLastObject]; Check(host, 3, 100, 200);
    MMCombinedPoseCache *cache = MMCreateCombinedPoseCache();
    assert(![cache sampleAtTime:TestTime(1)]);
    [host setStringParameterValue:cache.token toParameter:MMCombinedCacheToken];
    NSUInteger reads = host.nativeKeyReads;
    NSUInteger writes = host.hostWrites;
    MMCombinedPose *cached = [cache sampleAtTime:TestTime(1.4)];
    assert(cached && fabs(cached.positionX-50)<1e-6 && fabs(cached.scale-150)<1e-6);
    assert(host.nativeKeyReads == reads && host.hostWrites == writes);
    // Same-time edit before its notification: preserve the freshly read partner.
    [host lane:MMCustomControls][1][@"value"] = Pose(100, 250);
    MMCombinedPose *latest = MMReadCombinedValue(host, TestTime(2));
    MMCombinedPose *editable = [cache poseForEditingAtTime:TestTime(2) latestValue:latest];
    assert(editable.scale == 250 && host.nativeKeyReads == reads);
    [plugin parameterChanged:MMCustomControls atTime:TestTime(2) error:nil];
    assert([cache sampleAtTime:TestTime(2)].scale == 250);
    // Undo/redo arrives through the same native parameter callback.
    [host lane:MMCustomControls][1][@"value"] = Pose(100, 200);
    [plugin parameterChanged:MMCustomControls atTime:TestTime(2) error:nil];
    assert([cache sampleAtTime:TestTime(2)].scale == 200);
    [host lane:MMCustomControls][1][@"value"] = Pose(100, 250);
    [plugin parameterChanged:MMCustomControls atTime:TestTime(2) error:nil];
    assert([cache sampleAtTime:TestTime(2)].scale == 250);
    Key(host, 1, 40, 120);
    [plugin parameterChanged:MMCustomControls atTime:TestTime(1) error:nil];
    assert([cache sampleAtTime:TestTime(1)].positionX == 40);
    // A callback refresh carries moved key times into the inspector snapshot.
    NSMutableDictionary *moving = [host lane:MMCustomControls][1];
    [moving[@"key"] getValue:&metadata]; metadata.time = TestTime(3);
    moving[@"time"] = @3; moving[@"key"] = [NSValue valueWithBytes:&metadata objCType:@encode(FxKeyframe)];
    [host sort:MMCustomControls];
    [plugin parameterChanged:MMCustomControls atTime:TestTime(3) error:nil];
    assert([cache sampleAtTime:TestTime(3)].positionX == 40);
    [[host lane:MMCustomControls] removeLastObject];
    [plugin parameterChanged:MMCustomControls atTime:TestTime(3) error:nil];
    assert([cache sampleAtTime:TestTime(3)].positionX == 100);
    // Between keys preserve our sampled value, even when host weighting differs.
    reads = host.nativeKeyReads;
    editable = [cache poseForEditingAtTime:TestTime(1.4) latestValue:Pose(0, 100)];
    assert(fabs(editable.scale-175)<1e-6 && host.nativeKeyReads == reads);
    MMCombinedPoseCache *other = MMCreateCombinedPoseCache();
    assert(![other sampleAtTime:TestTime(1)]); // No cross-instance cache reuse.
    CombinedHost *second = [CombinedHost new];
    MagicMovePlugin *secondPlugin = [[MagicMovePlugin alloc] initWithAPIManager:second];
    second.plugin = secondPlugin;
    assert([secondPlugin addParametersWithError:nil]);
    second.blobs[@(MMCustomControls)] = Pose(-20, 80);
    [second setStringParameterValue:other.token toParameter:MMCombinedCacheToken];
    assert([other sampleAtTime:TestTime(2)].positionX == -20);
    assert([cache sampleAtTime:TestTime(2)].positionX == 100);
    host.failReadParameter = MMCustomControls;
    [plugin parameterChanged:MMCustomControls atTime:TestTime(2) error:nil];
    assert(![cache sampleAtTime:TestTime(2)]);
    assert(![cache poseForEditingAtTime:TestTime(2) latestValue:latest]);
    host.failReadParameter = 0;
    [plugin parameterChanged:MMCustomControls atTime:TestTime(2) error:nil];
    assert([cache sampleAtTime:TestTime(2)]);
    [plugin refreshDurationAtTime:TestTime(2)];
    assert(!([host.flags[@(MMCombinedEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED));
    host.editors[@(MMCombinedEasing)] = @(MTEasingLinear);
    assert([plugin parameterChanged:MMCombinedEasing atTime:TestTime(2) error:nil]);
    assert(MMReadCombinedValue(host,TestTime(2)).easing == MTEasingLinear);
    Check(host, 1.1, 25, 137.5);
    NSData *easedArchive = [NSKeyedArchiver archivedDataWithRootObject:MMReadCombinedValue(host,TestTime(2)) requiringSecureCoding:YES error:&error];
    MMCombinedPose *eased = [NSKeyedUnarchiver unarchivedObjectOfClass:MMCombinedPose.class fromData:easedArchive error:&error];
    assert(eased.easing == MTEasingLinear);
    [plugin refreshDurationAtTime:TestTime(0)];
    assert([host.flags[@(MMCombinedEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED);
    // Timing from the interval edits the next native key, preserving its values.
    [plugin refreshDurationAtTime:TestTime(1)];
    assert(!([host.flags[@(MMCombinedEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED));
    int incoming = -1; CMTime target = kCMTimeInvalid;
    assert(MMCombinedIncomingEasing(host,TestTime(1),&incoming,&target));
    assert(CMTimeCompare(target,TestTime(2)) == 0);
    NSUInteger combinedKeyCount = [host lane:MMCustomControls].count;
    host.editors[@(MMCombinedEasing)] = @(MTEasingEaseOut);
    assert([plugin parameterChanged:MMCombinedEasing atTime:TestTime(1) error:nil]);
    assert([host lane:MMCustomControls].count == combinedKeyCount);
    MMCombinedPose *destination = MMReadCombinedValue(host,TestTime(2));
    assert(destination.positionX == 100 && destination.scale == 250 && destination.easing == MTEasingEaseOut);
    assert(MMReadCombinedValue(host,TestTime(0)).easing == MTEasingSmooth);
    assert(!MMCombinedIncomingEasing(host,TestTime(-1),&incoming,NULL));
    assert(!MMCombinedIncomingEasing(host,TestTime(0),&incoming,NULL));
    assert(!MMCombinedIncomingEasing(host,TestTime(3),&incoming,NULL));
    reads = host.nativeKeyReads;
    assert([plugin updateTimingEditorsAtTime:TestTime(1) mouseDown:YES error:nil]);
    assert(!([host.flags[@(MMCombinedEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED));
    assert([host.editors[@(MMCombinedEasing)] intValue] == MTEasingEaseOut);
    assert([plugin updateTimingEditorsAtTime:TestTime(0) mouseDown:YES error:nil]);
    assert([host.flags[@(MMCombinedEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED);
    assert(host.nativeKeyReads == reads);
    // Explicit mode routes custom edits to the next existing key, never the playhead.
    assert(![host.editors[@(MMExplicitCreation)] boolValue]);
    host.editors[@(MMExplicitCreation)] = @YES;
    NSUInteger beforeKeys = [host lane:MMCustomControls].count;
    host.deferCallbacks = YES; reads = host.nativeKeyReads;
    assert(MMWriteCombinedComponent(host,cache,MMPositionX,60,TestTime(1)));
    assert(CMTimeCompare(host.lastCombinedWrite,TestTime(2)) == 0);
    assert([host lane:MMCustomControls].count == beforeKeys && host.nativeKeyReads == reads);
    destination = MMReadCombinedValue(host,TestTime(2));
    assert(destination.positionX == 60 && destination.scale == 250 && destination.easing == MTEasingEaseOut);
    host.deferCallbacks = NO; assert([host drainCallbacks]);
    assert(MMWriteCombinedComponent(host,cache,MMScale,90,TestTime(0)));
    assert(CMTimeCompare(host.lastCombinedWrite,TestTime(0)) == 0);
    assert(MMWriteCombinedComponent(host,cache,MMPositionX,65,TestTime(8)));
    assert(CMTimeCompare(host.lastCombinedWrite,TestTime(2)) == 0);
    // Default behavior continues writing at the actual playhead time.
    host.editors[@(MMExplicitCreation)] = @NO;
    assert(MMWriteCombinedComponent(host,cache,MMPositionX,10,TestTime(1)));
    assert(CMTimeCompare(host.lastCombinedWrite,TestTime(1)) == 0);
    host.editors[@(MMExplicitCreation)] = @YES;
    // The native keyframe button creates the first key in an empty explicit lane.
    second.editors[@(MMExplicitCreation)] = @YES;
    assert(!MMWriteCombinedComponent(second,other,MMPositionX,25,TestTime(1)));
    error = nil;
    FxKeyframe firstKey; FxInitKeyframe(firstKey,kFxKeyframe_CurrentVersion);
    firstKey.time = TestTime(1);
    assert(![second addKeyframe:&firstKey toParameter:MMCustomControls andChannel:0]);
    assert([second lane:MMCustomControls].count == 1);
    assert(MMWriteCombinedComponent(second,other,MMPositionX,25,TestTime(0)));
    assert(CMTimeCompare(second.lastCombinedWrite,TestTime(1)) == 0);
    // Outgoing motion uses the previous key, independently of incoming easing.
    [plugin refreshDurationAtTime:TestTime(0.5)];
    host.editors[@(MMCombinedAddedMotion)] = @(MTAddedMotionWiggle);
    TestChange(host,MMCombinedAddedMotion,0.5);
    MMCombinedPose *origin = MMReadCombinedValue(host,TestTime(0));
    assert(origin.addedMotion == MTAddedMotionWiggle);
    assert(CMTimeCompare(host.lastCombinedWrite,TestTime(0)) == 0);
    assert(MMReadCombinedValue(host,TestTime(2)).addedMotion == MTAddedMotionNone);
    archive = [NSKeyedArchiver archivedDataWithRootObject:origin requiringSecureCoding:YES error:&error];
    decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:MMCombinedPose.class fromData:archive error:&error];
    assert([decoded isEqual:origin] && decoded.addedMotion == MTAddedMotionWiggle);
    // Both value writes and incoming easing writes retain outgoing motion.
    assert(MMWriteCombinedComponent(host,cache,MMPositionX,30,TestTime(0)));
    assert(MMReadCombinedValue(host,TestTime(0)).addedMotion == MTAddedMotionWiggle);
    host.editors[@(MMCombinedAddedMotion)] = @(MTAddedMotionWave);
    TestChange(host,MMCombinedAddedMotion,2); // Last key has no outgoing interval.
    assert(MMReadCombinedValue(host,TestTime(2)).addedMotion == MTAddedMotionNone);
    [plugin refreshDurationAtTime:TestTime(0)];
    assert(!([host.flags[@(MMCombinedAddedMotion)] unsignedIntValue] & kFxParameterFlag_DISABLED));
    [plugin refreshDurationAtTime:TestTime(2)];
    assert([host.flags[@(MMCombinedAddedMotion)] unsignedIntValue] & kFxParameterFlag_DISABLED);
    // Blur takes one combined native snapshot, then evaluates every shutter time.
    host.editors[@(MMMotionBlur)] = @YES;
    NSUInteger blurReads = host.nativeKeyReads;
    NSData *blurState;
    assert([plugin pluginState:&blurState atTime:TestTime(0.5) quality:0 error:&error]);
    assert(host.nativeKeyReads-blurReads < 7); // Includes the independent Rotation lane count.
    KKMotionBlurState blur;
    [blurState getBytes:&blur range:NSMakeRange(blurState.length-sizeof(blur),sizeof(blur))];
    assert(blur.enabled && blur.sampleCount == 16);
    NSArray<NSValue *> *blurTimes = [KKMotionBlur sampleTimesForState:blur renderTime:TestTime(0.5)];
    for (NSUInteger i=0;i<blurTimes.count;++i) {
      CMTime sampleTime; [blurTimes[i] getValue:&sampleTime];
      MMCombinedPose *expected = MMReadCombinedPose(host,sampleTime,&active,&error);
      MMTransform sample;
      [blurState getBytes:&sample range:NSMakeRange(i*sizeof(sample),sizeof(sample))];
      assert(fabs(sample.offset.x-expected.positionX/100)<1e-6 && fabs(sample.scale-expected.scale/100)<1e-6);
    }
    host.editors[@(MMMotionBlur)] = @NO;
    host.failReadParameter = MMCustomControls; error = nil;
    assert(!MMReadCombinedPose(host, TestTime(1), &active, &error) && error);
    puts("Combined pose: coding, interpolation, activation, vector timing, insertion, movement, deletion, rendering, callback cache refresh, no-enumeration UI reads, delayed partner edits, undo/redo, isolation and read failure passed");
  }
}
