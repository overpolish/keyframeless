/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMCombinedPose.h"
#import "MMScalePose.h"
#import "MockHost.h"
#import "ShaderTypes.h"
#import <assert.h>
#import <math.h>

@interface ScaleHost : MockHost
@property(nonatomic, copy) void (^lastKeyReadHook)(void);
@end
@implementation ScaleHost
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding, NSCopying> **)value
                  fromParameter:(UInt32)p
                         atTime:(CMTime)t {
  if (p != MMScaleControls || ![self lane:p].count)
    return [super getCustomParameterValue:value fromParameter:p atTime:t];
  if (self.failReadParameter == p)
    return NO;
  for (NSDictionary *key in [self lane:p])
    if (fabs([key[@"time"] doubleValue] - CMTimeGetSeconds(t)) < 1e-6) {
      *value = key[@"value"];
      if (CMTimeCompare(t, TestTime(3)) == 0 && self.lastKeyReadHook) {
        void (^hook)(void) = self.lastKeyReadHook;
        self.lastKeyReadHook = nil;
        hook();
      }
      return YES;
    }
  // Deliberately unlike engine interpolation: gap edits must use the cache.
  *value = [[MMScalePose alloc] initWithX:399 y:399 authored:YES];
  return YES;
}
- (BOOL)setCustomParameterValue:(id)value
                    toParameter:(UInt32)p
                         atTime:(CMTime)t {
  if (p == MMScaleControls && [self lane:p].count && self.failBlobOnce != p) {
    NSMutableDictionary *found = nil;
    for (NSMutableDictionary *key in [self lane:p])
      if (fabs([key[@"time"] doubleValue] - CMTimeGetSeconds(t)) < 1e-6)
        found = key;
    if (found)
      found[@"value"] = value;
    else {
      FxKeyframe key;
      FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
      key.time = t;
      [[self lane:p] addObject:[@{
                       @"time" : @(CMTimeGetSeconds(t)),
                       @"value" : value,
                       @"key" : [NSValue valueWithBytes:&key
                                               objCType:@encode(FxKeyframe)]
                     } mutableCopy]];
      [[self lane:p] sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                             NSDictionary *b) {
        return [a[@"time"] compare:b[@"time"]];
      }];
    }
  }
  return [super setCustomParameterValue:value toParameter:p atTime:t];
}
@end
static MMScalePose *pose(double x, double y) {
  return [[MMScalePose alloc] initWithX:x y:y authored:YES];
}
static void key(ScaleHost *host, double time, double x, double y) {
  FxKeyframe k;
  FxInitKeyframe(k, kFxKeyframe_CurrentVersion);
  k.time = TestTime(time);
  [[host lane:MMScaleControls]
      addObject:[@{
        @"time" : @(time),
        @"value" : pose(x, y),
        @"key" : [NSValue valueWithBytes:&k objCType:@encode(FxKeyframe)]
      } mutableCopy]];
}
static void targetBoundaries(void) {
  MMScalePoseCache *cache=MMCreateScalePoseCache();
  [cache publishConstantPose:pose(20,30)]; CMTime target=kCMTimeInvalid;
  assert([cache valueTargetAtTime:TestTime(9) targetTime:&target] && CMTimeCompare(target,TestTime(9))==0);
  CMTime t1=TestTime(1),t2=TestTime(3),t3=TestTime(5);
  NSArray *all=@[
    @{ @"time":@1,@"nativeTime":[NSValue valueWithBytes:&t1 objCType:@encode(CMTime)],@"pose":pose(1,1) },
    @{ @"time":@3,@"nativeTime":[NSValue valueWithBytes:&t2 objCType:@encode(CMTime)],@"pose":pose(3,3) },
    @{ @"time":@5,@"nativeTime":[NSValue valueWithBytes:&t3 objCType:@encode(CMTime)],@"pose":pose(5,5) }];
  double times[]={-1,1,2,3,4,5,8};
  double expected[3][7]={{1,1,1,1,1,1,1},{1,1,3,3,3,3,3},{1,1,3,3,5,5,5}};
  for(NSUInteger count=1;count<=3;count++) {
    [cache publishEntries:[all subarrayWithRange:NSMakeRange(0,count)]];
    for(NSUInteger i=0;i<7;i++) {
      assert([cache valueTargetAtTime:TestTime(times[i]) targetTime:&target]);
      assert(fabs(CMTimeGetSeconds(target)-expected[count-1][i])<1e-6);
    }
  }
}
static void integration(void) {
  ScaleHost *host = [ScaleHost new];
  MMScalePoseCache *cache = MMCreateScalePoseCache();
  host.staticValues[@(MMScaleCacheToken)] = cache.token;
  host.blobs[@(MMScaleControls)] = pose(150, 75);
  host.editors[@(MMScaleProportional)] = @YES;
  MMRefreshScalePoseCache(host, TestTime(0));
  assert(MMWriteScaleComponent(host, cache, MMScaleX, 200, TestTime(0)));
  assert([cache sampleAtTime:TestTime(0)].y == 100);
  // A delayed partner change at an unkeyed value must survive the next edit.
  host.blobs[@(MMScaleControls)] = pose(200, 90);
  host.editors[@(MMScaleProportional)] = @NO;
  assert(MMWriteScaleComponent(host, cache, MMScaleX, 180, TestTime(0)));
  assert([cache sampleAtTime:TestTime(0)].y == 90);
  host.editors[@(MMScaleProportional)] = @YES;
  host.blobs[@(MMScaleControls)] = pose(0, 20);
  assert(MMWriteScaleComponent(host, cache, MMScaleX, 10, TestTime(0)));
  assert([cache sampleAtTime:TestTime(0)].y == 30);
  host.blobs[@(MMScaleControls)] = pose(100, 200);
  assert(MMWriteScaleComponent(host, cache, MMScaleX, 400, TestTime(0)));
  assert([cache sampleAtTime:TestTime(0)].x == 200 &&
         [cache sampleAtTime:TestTime(0)].y == 400);
  host.editors[@(MMScaleProportional)] = @NO;
  key(host, 0, 100, 50);
  key(host, 3, 300, 150);
  MMRefreshScalePoseCache(host, TestTime(2.4));
  MMScalePose *sample = [cache sampleAtTime:TestTime(2.4)];
  assert(fabs(sample.x - 200) < 1e-6 && fabs(sample.y - 100) < 1e-6);
  NSUInteger reads = host.nativeKeyReads;
  assert(MMWriteScaleComponent(host, cache, MMScaleX, 220, TestTime(2.4)));
  assert([host lane:MMScaleControls].count == 3);
  assert(fabs([cache sampleAtTime:TestTime(2.4)].y - 100) < 1e-6);
  assert(host.nativeKeyReads ==
         reads); // write and optimistic cache publish do not enumerate
  host.editors[@(MMExplicitCreation)] = @YES;
  assert(MMWriteScaleComponent(host, cache, MMScaleY, 175, TestTime(2.6)));
  assert([host lane:MMScaleControls].count == 3 &&
         [cache sampleAtTime:TestTime(3)].y == 175);
  assert(fabs([cache sampleAtTime:TestTime(2.4)].y - 100) < 1e-6);
  // Exact-key writes preserve a newer component even before a callback refresh.
  [host lane:MMScaleControls].lastObject[@"value"] = pose(320, 175);
  assert(MMWriteScaleComponent(host, cache, MMScaleY, 180, TestTime(3)));
  assert([cache sampleAtTime:TestTime(3)].x == 320);
  NSUInteger writes = host.hostWrites;
  host.failReadParameter = MMScaleProportional;
  assert(!MMWriteScaleComponent(host, cache, MMScaleX, 200, TestTime(3)) &&
         host.hostWrites == writes);
  host.failReadParameter = MMScaleControls;
  MMRefreshScalePoseCache(host, TestTime(3));
  assert(![cache sampleAtTime:TestTime(3)]);
  NSError *error = nil;
  BOOL active = NO;
  assert(!MMReadScalePose(host, TestTime(3), &active, &error) && error);
  host.failReadParameter = 0;
  MMRefreshScalePoseCache(host, TestTime(3));
  host.failBlobOnce = MMScaleControls;
  assert(!MMWriteScaleComponent(host, cache, MMScaleX, 200, TestTime(3)));
  assert([cache sampleAtTime:TestTime(3)].x == 320);
  // A render that started before an edit must not publish over the newer cache.
  __weak ScaleHost *weakHost = host;
  host.lastKeyReadHook = ^{
    assert(MMWriteScaleComponent(weakHost, cache, MMScaleX, 360, TestTime(3)));
  };
  assert(MMReadScalePose(host, TestTime(0), &active, nil));
  assert([cache sampleAtTime:TestTime(3)].x == 360);
  // A separate legacy-only instance stays on its uniform render path.
  MockHost *legacy = [MockHost new];
  legacy.blobs[@(MMCustomControls)] =
      [[MMCombinedPose alloc] initWithPositionX:0 scale:125 authored:YES];
  MagicMovePlugin *plugin = [[MagicMovePlugin alloc] initWithAPIManager:legacy];
  NSData *state = nil;
  assert([plugin pluginState:&state
                      atTime:TestTime(0)
                     quality:kFxQuality_HIGH
                       error:nil]);
  MMTransform transform;
  [state getBytes:&transform length:sizeof(transform)];
  assert(transform.scale == 1.25 && transform.scaleY == 1.25);
  legacy.blobs[@(MMScaleControls)] = pose(200, 50);
  assert([plugin pluginState:&state
                      atTime:TestTime(0)
                     quality:kFxQuality_HIGH
                       error:nil]);
  [state getBytes:&transform length:sizeof(transform)];
  assert(transform.scale == 2 && transform.scaleY == 0.5);
  legacy.editors[@(MMMotionBlur)] = @YES;
  assert([plugin pluginState:&state
                      atTime:TestTime(0)
                     quality:kFxQuality_HIGH
                       error:nil]);
  assert(state.length > sizeof(transform));
  [state getBytes:&transform length:sizeof(transform)];
  assert(transform.scale == 2 && transform.scaleY == 0.5);
}

int main(void) {
  @autoreleasepool {
    targetBoundaries();
    integration();
    MMScalePose *base = [[MMScalePose alloc] initWithX:100 y:200 authored:NO];
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:base
                                         requiringSecureCoding:YES
                                                         error:&error];
    assert(data && !error);
    MMScalePose *decoded =
        [NSKeyedUnarchiver unarchivedObjectOfClass:MMScalePose.class
                                          fromData:data
                                             error:&error];
    assert(decoded && [decoded isEqual:base] && decoded.x == 100 &&
           decoded.y == 200 && !decoded.authored);
    MMScalePose *middle =
        (id)[[MMScalePose alloc] initWithX:100 y:200 authored:YES];
    MMScalePose *right = [[MMScalePose alloc] initWithX:300 y:400 authored:YES];
    middle = (id)[middle interpolateBetween:right withWeight:0.25];
    assert(fabs(middle.x - 150) < 1e-6 && fabs(middle.y - 250) < 1e-6 &&
           middle.authored);
    assert(![[MMScalePose alloc] initWithX:NAN y:100 authored:YES]);
    assert(![[MMScalePose alloc] initWithX:100
                                         y:100
                                  authored:YES
                                    easing:(MTEasing)99
                               addedMotion:MTAddedMotionNone]);
  }
  puts("Scale: coding, engine sampling, explicit targeting, insertion, "
       "proportional editing, cache preservation, failures and render fallback "
       "passed");
  return 0;
}
