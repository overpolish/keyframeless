/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KKMotionBlur.h>
#import <math.h>

static NSUInteger BlurStateOffset(NSData *state) {
  return state.length - sizeof(KKMotionBlurState);
}

static KKMotionBlurState BlurStateFrom(NSData *state) {
  KKMotionBlurState blur = {0};
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
    MockHost *host = [MockHost new];
    MagicMovePlugin *plugin = [[MagicMovePlugin alloc] initWithAPIManager:host];
    host.plugin = plugin;
    assert([plugin addParametersWithError:nil]);

    TestAdd(host, MMPositionX, 0, 0);
    TestAdd(host, MMPositionX, 4, 100);
    TestAdd(host, MMPositionX, 8, 0);
    TestAdd(host, MMScale, 0, 100);
    TestAdd(host, MMScale, 4, 150);
    TestAdd(host, MMScale, 8, 100);

    // The ordinary payload stays compact when blur is disabled.
    NSData *state = nil;
    NSError *error = nil;
    NSUInteger unblurredReadsBefore=host.nativeKeyReads;
    assert([plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    assert(!error && state.length == sizeof(MMTransform));
    assert(IsFiniteTransform(TransformAt(state, 0)));
    NSUInteger snapshotReads=host.nativeKeyReads-unblurredReadsBefore;
    assert(snapshotReads <= 12); // Includes one count read each for Scale, Opacity and Rotation.

    // Blur uses the fixed primitive defaults and appends the shared state after
    // the complete set of transform samples.
    host.editors[@(MMMotionBlur)] = @YES;
    NSUInteger readsBefore = host.nativeKeyReads;
    error = nil;
    assert([plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    assert(!error);
    KKMotionBlurState blur = BlurStateFrom(state);
    assert(blur.enabled && blur.sampleCount == 16);
    assert(fabs(blur.shutterSec - (1.0 / 60.0)) < 1e-9);
    assert(state.length == 16 * sizeof(MMTransform) + sizeof(blur));
    assert(host.nativeKeyReads - readsBefore == snapshotReads); // Independent of shutter sample count.
    MMTransform current = TransformAt(state, 0);
    MMTransform earlier = TransformAt(state, 15);
    assert(IsFiniteTransform(current) && IsFiniteTransform(earlier));
    assert(fabs(current.offset.x - earlier.offset.x) > 1e-5);

    // Duration, easing, available-time timing, and outgoing added motion are
    // evaluated for each shutter sample rather than only at the playhead.
    host.editors[@(MMTransitionDuration)] = @1.2;
    TestChange(host, MMTransitionDuration, 4);
    host.editors[@(MMPositionEasing)] = @(MTEasingEaseOut);
    TestChange(host, MMPositionEasing, 4);
    host.editors[@(MMPositionAvailableTime)] = @YES;
    TestChange(host, MMPositionAvailableTime, 4);
    host.editors[@(MMPositionAddedMotion)] = @(MTAddedMotionWave);
    TestChange(host, MMPositionAddedMotion, 0);
    error = nil;
    assert([plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    assert(!error && state.length == 16 * sizeof(MMTransform) + sizeof(blur));
    NSArray<NSValue *> *times = [KKMotionBlur sampleTimesForState:blur renderTime:TestTime(3.5)];
    host.editors[@(MMMotionBlur)] = @NO;
    for (NSUInteger i = 0; i < 16; ++i) {
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
    assert(!error && state.length == 16 * sizeof(MMTransform) + sizeof(blur));
    NSUInteger distinct = 0;
    for (NSUInteger i = 1; i < 16; ++i) {
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

    // Turning blur off returns to the one-transform payload again.
    host.frameDuration = TestTime(1.0 / 30.0);
    host.editors[@(MMMotionBlur)] = @NO;
    error = nil;
    assert([plugin pluginState:&state atTime:TestTime(3.5) quality:0 error:&error]);
    assert(!error && state.length == sizeof(MMTransform));

    puts("Motion blur: compact payload, 16 sampled transforms, timing/motion evaluation, coarse clock, bounded reads, validation and fallback passed");
  }
}
