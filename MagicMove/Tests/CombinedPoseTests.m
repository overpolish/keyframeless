/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "MMCombinedPose.h"
#import "ShaderTypes.h"
#import <math.h>

@interface MockHost (CombinedTestSorting)
- (void)sort:(NSUInteger)parameter;
@end

// Model custom values at native key times separately from the scalar mock.
@interface CombinedHost : MockHost
@end
@implementation CombinedHost
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
    host.failReadParameter = MMCustomControls; error = nil;
    assert(!MMReadCombinedPose(host, TestTime(1), &active, &error) && error);
    puts("Combined pose: coding, interpolation, activation, vector timing, insertion, movement, deletion, rendering, callback cache refresh, no-enumeration UI reads, delayed partner edits, undo/redo, isolation and read failure passed");
  }
}
