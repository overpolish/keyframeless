/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "MMCombinedPose.h"
#import "Constants.h"
#import "ShaderTypes.h"
@import KeyframelessKit;
#import <math.h>

@interface MockHost (PositionTestsSorting)
- (void)sort:(NSUInteger)parameter;
@end

@interface PositionHost : MockHost @end
@implementation PositionHost
- (NSError *)addKeyframe:(const FxKeyframe *)key toParameter:(NSUInteger)p andChannel:(NSUInteger)channel {
  if (p != MMCustomControls) return [super addKeyframe:key toParameter:p andChannel:channel];
  NSObject<NSSecureCoding,NSCopying> *value = nil;
  [self getCustomParameterValue:&value fromParameter:(UInt32)p atTime:key->time];
  [[self lane:p] addObject:[@{ @"time": @(CMTimeGetSeconds(key->time)), @"value": value,
    @"key": [NSValue valueWithBytes:key objCType:@encode(FxKeyframe)] } mutableCopy]];
  [self sort:p];
  return nil;
}
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding,NSCopying> **)value fromParameter:(UInt32)p atTime:(CMTime)t {
  if (p != MMCustomControls) return [super getCustomParameterValue:value fromParameter:p atTime:t];
  NSArray *keys = [self lane:p];
  if (!keys.count) { *value = self.blobs[@(p)]; return *value != nil; }
  *value = keys.firstObject[@"value"];
  for (NSDictionary *key in keys) if ([key[@"time"] doubleValue] <= CMTimeGetSeconds(t)) *value = key[@"value"];
  return YES;
}
- (BOOL)setCustomParameterValue:(id)value toParameter:(UInt32)p atTime:(CMTime)t {
  if (p == MMCustomControls) {
    for (NSMutableDictionary *key in [self lane:p])
      if (fabs([key[@"time"] doubleValue] - CMTimeGetSeconds(t)) < 1e-6) key[@"value"] = value;
  }
  return [super setCustomParameterValue:value toParameter:p atTime:t];
}
@end

@interface MissingYCoder : NSCoder @end
@implementation MissingYCoder
- (double)decodeDoubleForKey:(NSString *)key { return [key isEqualToString:@"x"] ? 12 : ([key isEqualToString:@"scale"] ? 140 : 0); }
- (BOOL)decodeBoolForKey:(NSString *)key { return YES; }
- (NSInteger)decodeIntegerForKey:(NSString *)key { return [key isEqualToString:@"easing"] ? MTEasingLinear : 0; }
@end

static MMCombinedPose *Pose(double x, double y, double scale, MTAddedMotion motion) {
  return [[MMCombinedPose alloc] initWithPositionX:x positionY:y scale:scale authored:YES easing:MTEasingLinear addedMotion:motion];
}
static void Key(PositionHost *host, double time, MMCombinedPose *pose) {
  FxKeyframe key; FxInitKeyframe(key, kFxKeyframe_CurrentVersion); key.time = TestTime(time);
  [[host lane:MMCustomControls] addObject:[@{ @"time": @(time), @"value": pose,
    @"key": [NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)] } mutableCopy]];
  [host sort:MMCustomControls];
}

int main(void) {
  @autoreleasepool {
    MMCombinedPose *legacy = [[MMCombinedPose alloc] initWithCoder:[MissingYCoder new]];
    assert(legacy.positionX == 12 && legacy.positionY == 0 && legacy.scale == 140);
    MMCombinedPose *original = Pose(-20, 35, 180, MTAddedMotionWiggle);
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:original requiringSecureCoding:YES error:&error];
    MMCombinedPose *roundtrip = [NSKeyedUnarchiver unarchivedObjectOfClass:MMCombinedPose.class fromData:data error:&error];
    assert(roundtrip && [roundtrip isEqual:original] && roundtrip.hash == original.hash);
    MMCombinedPose *middle = (MMCombinedPose *)[Pose(0, 10, 100, MTAddedMotionNone) interpolateBetween:Pose(100, 50, 200, MTAddedMotionNone) withWeight:.25];
    assert(middle.positionX == 25 && middle.positionY == 20 && middle.scale == 125);

    PositionHost *host = [PositionHost new];
    MagicMovePlugin *plugin = [[MagicMovePlugin alloc] initWithAPIManager:host]; host.plugin = plugin;
    assert([plugin addParametersWithError:&error]);
    Key(host, 0, Pose(0, 0, 100, MTAddedMotionNone));
    Key(host, 2, Pose(100, 60, 200, MTAddedMotionNone));
    MMCombinedPoseCache *cache = MMCreateCombinedPoseCache();
    [host setStringParameterValue:cache.token toParameter:MMCombinedCacheToken];
    [plugin parameterChanged:MMCustomControls atTime:TestTime(0) error:nil];
    MMCombinedPose *sample = [cache sampleAtTime:TestTime(1)];
    assert(sample);
    assert(fabs(sample.positionX - 16.6666667) < 1e-6 && fabs(sample.positionY - 10) < 1e-6 && fabs(sample.scale - 116.6666667) < 1e-6);
    host.editors[@(MMExplicitCreation)] = @NO;
    assert(MMWriteCombinedComponent(host, cache, MMPositionY, 77, TestTime(2)));
    MMCombinedPose *edited = [host lane:MMCustomControls][1][@"value"];
    assert(edited.positionY == 77 && edited.positionX == 100 && edited.scale == 200 && edited.easing == MTEasingLinear);
    assert(MMWriteCombinedComponent(host, cache, MMScale, 220, TestTime(2)));
    edited = [host lane:MMCustomControls][1][@"value"];
    assert(edited.positionY == 77 && edited.positionX == 100 && edited.scale == 220);
    host.editors[@(MMCombinedEasing)] = @(MTEasingEaseOut);
    assert([plugin parameterChanged:MMCombinedEasing atTime:TestTime(1) error:&error]);
    edited = [host lane:MMCustomControls][1][@"value"];
    assert(edited.positionY == 77 && edited.easing == MTEasingEaseOut);
    host.editors[@(MMCombinedAddedMotion)] = @(MTAddedMotionHandheld);
    assert([plugin parameterChanged:MMCombinedAddedMotion atTime:TestTime(1) error:&error]);
    edited = [host lane:MMCustomControls][1][@"value"];
    MMCombinedPose *outgoing = [host lane:MMCustomControls][0][@"value"];
    assert(edited.positionY == 77 && outgoing.positionY == 0 && outgoing.addedMotion == MTAddedMotionHandheld);
    NSData *state = nil;
    assert([plugin pluginState:&state atTime:TestTime(1) quality:0 error:&error]);
    MMTransform transform; [state getBytes:&transform length:sizeof(transform)];
    assert(isfinite(transform.offset.x) && isfinite(transform.offset.y) && fabs(transform.offset.y) > 1e-9);
    host.frameDuration = TestTime(1.0 / 30.0);
    host.editors[@(MMMotionBlur)] = @YES;
    assert([plugin pluginState:&state atTime:TestTime(1) quality:0 error:&error]);
    KKMotionBlurState blur;
    [state getBytes:&blur range:NSMakeRange(state.length - sizeof(blur), sizeof(blur))];
    assert(blur.enabled && blur.sampleCount > 1);
    BOOL sawY = NO;
    for (NSUInteger i = 0; i < blur.sampleCount; ++i) {
      MMTransform sampleState;
      [state getBytes:&sampleState range:NSMakeRange(i * sizeof(sampleState), sizeof(sampleState))];
      assert(isfinite(sampleState.offset.y));
      sawY |= fabs(sampleState.offset.y) > 1e-9;
    }
    assert(sawY);
    puts("Position Y: legacy default, secure roundtrip, three-component sampling, edit preservation and render offset passed");
  }
}
