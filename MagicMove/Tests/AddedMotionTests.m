/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "ShaderTypes.h"
#import <math.h>
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKTimingEvaluation.h>
static MTDurationRecord Record(MockHost *h, UInt32 value, UInt32 data, NSUInteger index) {
  NSData *records = TestData(h,value,data);
  assert(records.length > index*sizeof(MTDurationRecord));
  return ((const MTDurationRecord *)records.bytes)[index];
}
int main(void) {
  @autoreleasepool {
    // Keep the port faithful to the established algorithms at fixed defaults.
    double values[] = {100,100}, output[2];
    MTDestination flat[] = {{.arrival=0,.values=values}, {.arrival=4,.values=values}};
    for (int motion=MTAddedMotionWave; motion<=MTAddedMotionHandheld; ++motion) {
      flat[0].addedMotion = (MTAddedMotion)motion;
      for (int i=1; i<40; ++i) {
        double t=i/40.0;
        assert(MTSample(flat,2,2,t*4,output));
        for (NSUInteger c=0;c<2;++c)
          assert(fabs(output[c]-100*KKApplyHoldEffectForComponent(t,(KKHoldEffect)motion,1,1,0,c))<1e-9);
      }
    }
    // Compare the entire join window with the old two-half Hermite implementation.
    double a[]={100}, b[]={200}, c[]={150};
    MTDestination joined[] = {{.arrival=0,.values=a,.addedMotion=MTAddedMotionWave},
      {.arrival=4,.duration=1.2,.values=b}, {.arrival=8,.duration=1.2,.values=c}};
    const MTDestination *joinSource = joined;
    double (^raw)(double) = ^double(double seconds) {
      MTDestination pair[2];
      if (seconds < 4) { pair[0]=joinSource[0]; pair[1]=joinSource[1]; }
      else { pair[0]=joinSource[1]; pair[1]=joinSource[2]; }
      double value; assert(MTSample(pair,2,1,seconds,&value)); return value;
    };
    for (int i=0;i<100;++i) {
      double seconds=2.4+i*0.032;
      assert(MTSample(joined,3,1,seconds,output));
      assert(fabs(output[0]-KKHermiteJoinBlend(seconds,4,4*KK_JOIN_BLEND_MOD_FRAC,raw))<1e-9);
    }
    MockHost *h = [MockHost new];
    MagicMovePlugin *plugin = [[MagicMovePlugin alloc] initWithAPIManager:h]; h.plugin = plugin;
    assert([plugin addParametersWithError:nil]);
    TestAdd(h,MMPositionX,0,0); TestAdd(h,MMPositionX,4,100); TestAdd(h,MMPositionX,8,0);
    TestAdd(h,MMScale,0,100); TestAdd(h,MMScale,4,200); TestAdd(h,MMScale,8,100);
    [plugin refreshDurationAtTime:TestTime(0)];
    assert(!([h.flags[@(MMPositionAddedMotion)] unsignedIntValue] & kFxParameterFlag_DISABLED));
    assert([h.flags[@(MMPositionEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED);
    h.editors[@(MMPositionAddedMotion)] = @(MTAddedMotionWave); TestChange(h,MMPositionAddedMotion,2);
    assert(Record(h,MMPositionX,MMDurationData,0).addedMotion == MTAddedMotionWave);
    assert(Record(h,MMPositionX,MMDurationData,1).addedMotion == MTAddedMotionNone);
    assert(Record(h,MMScale,MMScaleDurationData,0).addedMotion == MTAddedMotionNone);
    // Added motion is rendered even during a hold at position zero.
    NSData *state; NSError *error = nil;
    assert([plugin pluginState:&state atTime:TestTime(0.3) quality:0 error:&error]);
    MMTransform transform; [state getBytes:&transform length:sizeof(transform)];
    assert(fabs(transform.offset.x) > 1e-5);
    // Exact keys own OUT, while incoming easing still edits that exact key's IN.
    h.editors[@(MMPositionAddedMotion)] = @(MTAddedMotionHandheld); TestChange(h,MMPositionAddedMotion,4);
    h.editors[@(MMPositionEasing)] = @(MTEasingLinear); TestChange(h,MMPositionEasing,4);
    assert(Record(h,MMPositionX,MMDurationData,1).addedMotion == MTAddedMotionHandheld);
    assert(Record(h,MMPositionX,MMDurationData,1).easing == MTEasingLinear);
    TestLinkPose(h,MMPositionLink,4,YES);
    // Linking time does not opt the partner into added motion.
    assert(Record(h,MMScale,MMScaleDurationData,1).addedMotion == MTAddedMotionNone);
    TestMove(h,MMPositionX,1,5);
    assert(Record(h,MMPositionX,MMDurationData,1).addedMotion == MTAddedMotionHandheld);
    [plugin refreshDurationAtTime:TestTime(6)];
    NSUInteger writes = h.hostWrites;
    TestChange(h,MMPositionAddedMotion,6);
    assert(h.hostWrites == writes);
    NSUInteger reads = h.nativeKeyReads;
    assert([plugin updateTimingEditorsAtTime:TestTime(8) mouseDown:YES error:&error]);
    assert([h.flags[@(MMPositionAddedMotion)] unsignedIntValue] & kFxParameterFlag_DISABLED);
    assert([plugin updateTimingEditorsAtTime:TestTime(1) mouseDown:YES error:&error]);
    assert(!([h.flags[@(MMPositionAddedMotion)] unsignedIntValue] & kFxParameterFlag_DISABLED));
    assert(h.nativeKeyReads == reads);
    NSData *saved = MMReadSavedDestinations(h,MMDurationData,&error);
    assert(((const MTDurationRecord *)saved.bytes)[1].addedMotion == MTAddedMotionHandheld);
    h.editors[@(MMPositionAddedMotion)] = @99;
    assert(![plugin parameterChanged:MMPositionAddedMotion atTime:TestTime(1) error:&error]);
    assert(Record(h,MMPositionX,MMDurationData,0).addedMotion == MTAddedMotionWave);
    puts("Added motion: outgoing ownership, rendering, independent linking, persistence, movement, live flags and echo suppression passed");
  }
}
