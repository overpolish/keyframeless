/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Constants.h"
#import "MockHost.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import "MMLanes.h"
@import RenderSupport;
#import <math.h>

// Keyed custom values, as the host serves them for the Position lane.
@interface BlurHost : MockHost @end
@implementation BlurHost
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding,NSCopying> **)value
                  fromParameter:(UInt32)p atTime:(CMTime)t {
  if (p != MMPositionControls || ![self lane:p].count)
    return [super getCustomParameterValue:value fromParameter:p atTime:t];
  if (self.failReadParameter == p) return NO;
  NSArray *keys = [self lane:p];
  *value = keys.firstObject[@"value"];
  for (NSDictionary *key in keys) {
    if ([key[@"time"] doubleValue] > CMTimeGetSeconds(t)) break;
    *value = key[@"value"];
  }
  return YES;
}
@end

static id<KFPropertyPose> Pose(double x, MTEasing easing, MTAddedMotion motion, BOOL available) {
  id<KFPropertyPose> pose=[MMPositionLane().defaultPose poseByReplacingValues:@[@(x),@0] authored:YES
      easing:easing addedMotion:motion
      timing:[[KFPoseTiming alloc] initWithDuration:1.2 available:available amount:1 speed:1]];
  return pose;
}

static void Key(MockHost *host, double time, id<KFPropertyPose> pose) {
  FxKeyframe key;
  FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
  key.time = TestTime(time);
  [[host lane:MMPositionControls] addObject:[@{@"time":@(time), @"value":pose,
      @"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)]} mutableCopy]];
}

static NSUInteger BlurStateOffset(NSData *state) {
  return state.length - sizeof(RSRenderBlurState);
}

static RSRenderBlurState BlurStateFrom(NSData *state) {
  RSRenderBlurState blur = {0};
  [state getBytes:&blur
            range:NSMakeRange(BlurStateOffset(state), sizeof(blur))];
  return blur;
}

static MMTransform TransformAt(NSData *state, NSUInteger index) {
  MMTransform transform = {0};
  [state getBytes:&transform
            range:NSMakeRange(index * sizeof(transform), sizeof(transform))];
  return transform;
}

static BOOL IsFiniteTransform(MMTransform transform) {
  return isfinite(transform.offset.x) && isfinite(transform.offset.y) &&
         isfinite(transform.scale) && isfinite(transform.rotation) &&
         isfinite(transform.aspect);
}

int main(void) {
  @autoreleasepool {
    BlurHost *host = [BlurHost new];
    // An unavailable host setting must read as a failure, not as zero.
    host.strictReadParameters =
        [NSSet setWithObjects:@(MMMotionBlurSamples), @(MMMotionBlurShutterAngle), nil];
    MagicMovePlugin *plugin = [[MagicMovePlugin alloc] initWithAPIManager:host];
    host.plugin = plugin;
    assert([plugin addParametersWithError:nil]);

    Key(host, 0, Pose(0, MTEasingSmooth, MTAddedMotionNone, NO));
    Key(host, 4, Pose(100, MTEasingSmooth, MTAddedMotionNone, NO));
    Key(host, 8, Pose(0, MTEasingSmooth, MTAddedMotionNone, NO));

    // The ordinary payload stays compact when blur is disabled.
    NSData *state = nil;
    NSError *error = nil;
    NSUInteger unblurredReadsBefore=host.nativeKeyReads;
    assert([plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    assert(!error && state.length == sizeof(MMTransform));
    assert(IsFiniteTransform(TransformAt(state, 0)));
    NSUInteger snapshotReads=host.nativeKeyReads-unblurredReadsBefore;
    // Three keyframe reads for the combined lane plus one count read for each
    // of the six pose parameters.
    assert(snapshotReads == 9);

    // Blur uses the fixed primitive defaults and appends the shared state after
    // the complete set of transform samples.
    host.editors[@(MMMotionBlur)] = @YES;
    NSUInteger readsBefore = host.nativeKeyReads;
    error = nil;
    assert([plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    assert(!error);
    RSRenderBlurState blur = BlurStateFrom(state);
    assert(blur.enabled && blur.sampleCount == MMMotionBlurDefaultSamples);
    assert(fabs(blur.shutterSec - (1.0 / 60.0)) < 1e-9);
    assert(state.length == MMMotionBlurDefaultSamples * sizeof(MMTransform) + sizeof(blur));
    assert(host.nativeKeyReads - readsBefore == snapshotReads); // Independent of shutter sample count.
    MMTransform current = TransformAt(state, 0);
    MMTransform earlier = TransformAt(state, 15);
    assert(IsFiniteTransform(current) && IsFiniteTransform(earlier));
    assert(fabs(current.offset.x - earlier.offset.x) > 1e-5);

    // Easing, available-time timing, and outgoing added motion travel with the
    // poses and are evaluated for each shutter sample, not only the playhead.
    [host lane:MMPositionControls][0][@"value"] =
        Pose(0, MTEasingSmooth, MTAddedMotionWave, NO);
    [host lane:MMPositionControls][1][@"value"] =
        Pose(100, MTEasingEaseOut, MTAddedMotionNone, YES);
    error = nil;
    assert([plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    assert(!error && state.length == MMMotionBlurDefaultSamples * sizeof(MMTransform) + sizeof(blur));
    NSArray<NSValue *> *times = RSRenderBlurSampleTimes(blur, TestTime(3.5));
    host.editors[@(MMMotionBlur)] = @NO;
    for (NSUInteger i = 0; i < MMMotionBlurDefaultSamples; ++i) {
      CMTime sampleTime; [times[i] getValue:&sampleTime];
      NSData *reference;
      assert([plugin pluginState:&reference atTime:sampleTime quality:0 error:&error]);
      MMTransform sample = TransformAt(state,i), expected = TransformAt(reference,0);
      assert(IsFiniteTransform(sample));
      assert(sample.offset.x == expected.offset.x && sample.scale == expected.scale);
    }
    host.editors[@(MMMotionBlur)] = @YES;

    // The shared sampler's high-timescale conversion keeps sub-frame samples
    // distinct even when the host gives the render callback a coarse clock.
    CMTime coarseTime = CMTimeMake(1, 2);
    error = nil;
    assert([plugin pluginState:&state atTime:coarseTime quality:0 error:&error]);
    assert(!error && state.length == MMMotionBlurDefaultSamples * sizeof(MMTransform) + sizeof(blur));
    NSUInteger distinct = 0;
    for (NSUInteger i = 1; i < MMMotionBlurDefaultSamples; ++i) {
      if (fabs(TransformAt(state, i - 1).offset.x -
               TransformAt(state, i).offset.x) > 1e-7)
        distinct++;
    }
    assert(distinct > 0);

    // A missing frame duration is a real setup error when blur is enabled.
    host.frameDuration = kCMTimeZero;
    error = nil;
    assert(![plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    assert(error != nil);

    // Persisted settings alter both the sample count and shutter window.
    host.frameDuration = TestTime(1.0 / 30.0);
    host.editors[@(MMMotionBlurSamples)] = @32;
    host.editors[@(MMMotionBlurShutterAngle)] = @90;
    error = nil;
    assert([plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    blur = BlurStateFrom(state);
    assert(blur.enabled && blur.sampleCount == 32);
    assert(fabs(blur.shutterSec - (1.0 / 120.0)) < 1e-9);
    assert(state.length == 32 * sizeof(MMTransform) + sizeof(blur));

    // A zero shutter intentionally bypasses temporal sampling.
    host.editors[@(MMMotionBlurShutterAngle)] = @0;
    assert([plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    assert(state.length == sizeof(MMTransform));

    host.editors[@(MMMotionBlurSamples)]=@999;
    host.editors[@(MMMotionBlurShutterAngle)]=@999;
    assert([plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    blur=BlurStateFrom(state);
    assert(blur.sampleCount==128 && fabs(blur.shutterSec-1.0/30.0)<1e-9);
    host.editors[@(MMMotionBlurSamples)]=@(-1);
    host.editors[@(MMMotionBlurShutterAngle)]=@180;
    assert([plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    assert(BlurStateFrom(state).sampleCount==2);

    // A setting the host cannot serve falls back to the registered default
    // rather than rendering with zero samples.
    [host.editors removeObjectForKey:@(MMMotionBlurSamples)];
    [host.editors removeObjectForKey:@(MMMotionBlurShutterAngle)];
    assert([plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    blur = BlurStateFrom(state);
    assert(blur.enabled && blur.sampleCount == MMMotionBlurDefaultSamples);
    assert(fabs(blur.shutterSec - (1.0 / 60.0)) < 1e-9);

    // Turning blur off returns to the one-transform payload again.
    host.frameDuration = TestTime(1.0 / 30.0);
    host.editors[@(MMMotionBlur)] = @NO;
    error = nil;
    assert([plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    assert(!error && state.length == sizeof(MMTransform));

    puts("Motion blur: compact payload, persisted settings, timing/motion evaluation, coarse clock, bounded reads, validation and fallback passed");
  }
}
