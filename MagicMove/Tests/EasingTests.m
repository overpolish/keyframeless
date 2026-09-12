/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "ShaderTypes.h"
#import <math.h>
static MTDurationRecord Record(MockHost *h, UInt32 value, UInt32 data, NSUInteger index) {
  NSData *records = TestData(h,value,data);
  assert(records.length > index*sizeof(MTDurationRecord));
  return ((const MTDurationRecord *)records.bytes)[index];
}
int main(void) {
  @autoreleasepool {
    MockHost *h = [MockHost new];
    MagicMovePlugin *plugin = [[MagicMovePlugin alloc] initWithAPIManager:h]; h.plugin = plugin;
    assert([plugin addParametersWithError:nil]);
    TestAdd(h,MMPositionX,0,0); TestAdd(h,MMPositionX,4,100); TestAdd(h,MMPositionX,8,0);
    TestAdd(h,MMScale,0,100); TestAdd(h,MMScale,4,200); TestAdd(h,MMScale,8,100);
    [plugin refreshDurationAtTime:TestTime(0)];
    assert([h.flags[@(MMPositionEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED);
    [plugin refreshDurationAtTime:TestTime(4)];
    assert(!([h.flags[@(MMPositionEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED));
    h.editors[@(MMTransitionDuration)] = @2; TestChange(h,MMTransitionDuration,4);
    h.editors[@(MMPositionEasing)] = @(MTEasingLinear); TestChange(h,MMPositionEasing,4);
    assert(Record(h,MMPositionX,MMDurationData,1).easing == MTEasingLinear);
    NSData *state; NSError *error = nil;
    assert([plugin pluginState:&state atTime:TestTime(2.5) quality:0 error:&error]);
    MMTransform transform; [state getBytes:&transform length:sizeof(transform)];
    assert(fabs(transform.offset.x-0.25)<1e-6);
    TestLinkPose(h,MMPositionLink,4,YES);
    assert(Record(h,MMScale,MMScaleDurationData,1).easing == MTEasingLinear);
    // Match the entry and exit, then edit easing through the connected partner.
    h.editors[@(MMPositionMatch)] = @YES; TestChange(h,MMPositionMatch,0);
    [plugin refreshDurationAtTime:TestTime(4)];
    h.editors[@(MMScaleEasing)] = @(MTEasingEaseIn); TestChange(h,MMScaleEasing,4);
    assert(Record(h,MMPositionX,MMDurationData,1).easing == MTEasingEaseIn);
    assert(Record(h,MMPositionX,MMDurationData,2).easing == MTEasingEaseIn);
    assert(Record(h,MMScale,MMScaleDurationData,1).easing == MTEasingEaseIn);
    // Saved JSON and reconciliation carry the mode through native movement.
    TestMove(h,MMScale,1,5);
    assert(Record(h,MMScale,MMScaleDurationData,1).easing == MTEasingEaseIn);
    NSData *saved = MMReadSavedDestinations(h,MMScaleDurationData,&error);
    assert(saved && !error && ((const MTDurationRecord *)saved.bytes)[1].easing == MTEasingEaseIn);
    [plugin refreshDurationAtTime:TestTime(5)];
    NSUInteger writes = h.hostWrites;
    [plugin parameterChanged:MMScaleEasing atTime:TestTime(5) error:nil];
    assert(h.hostWrites == writes); // Ignore delayed editor echoes.
    [plugin refreshDurationAtTime:TestTime(5.1)];
    assert(!([h.flags[@(MMScaleEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED));
    // From between keys, edit the next destination and propagate matched timing.
    h.editors[@(MMPositionEasing)] = @(MTEasingEaseOut); TestChange(h,MMPositionEasing,6);
    assert(Record(h,MMPositionX,MMDurationData,2).easing == MTEasingEaseOut);
    assert(Record(h,MMPositionX,MMDurationData,1).easing == MTEasingEaseOut);
    assert(Record(h,MMScale,MMScaleDurationData,1).easing == MTEasingEaseOut);
    [plugin refreshDurationAtTime:TestTime(3)];
    h.editors[@(MMTransitionDuration)] = @0.7; TestChange(h,MMTransitionDuration,3);
    assert(Record(h,MMPositionX,MMDurationData,1).duration == 0.7);
    assert(Record(h,MMPositionX,MMDurationData,2).duration == 0.7);
    assert(Record(h,MMScale,MMScaleDurationData,1).duration == 0.7);
    h.editors[@(MMPositionAvailableTime)] = @YES; TestChange(h,MMPositionAvailableTime,3);
    assert(Record(h,MMPositionX,MMDurationData,1).useAvailableTime);
    assert(Record(h,MMPositionX,MMDurationData,2).useAvailableTime);
    assert(Record(h,MMScale,MMScaleDurationData,1).useAvailableTime);
    [plugin refreshDurationAtTime:TestTime(3)];
    assert([h.flags[@(MMPositionLink)] unsignedIntValue] & kFxParameterFlag_DISABLED);
    assert([h.flags[@(MMPositionMatch)] unsignedIntValue] & kFxParameterFlag_DISABLED);
    [plugin refreshDurationAtTime:TestTime(9)];
    assert([h.flags[@(MMPositionEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED);
    // The timer's held-mouse path refreshes selectors from cached snapshots.
    NSUInteger reads = h.nativeKeyReads, mutations = h.mutations, blobs = h.blobWrites;
    assert([plugin updateTimingEditorsAtTime:TestTime(3) mouseDown:YES error:nil]);
    assert(!([h.flags[@(MMPositionEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED));
    assert([h.editors[@(MMPositionEasing)] intValue] == MTEasingEaseOut);
    assert([plugin updateTimingEditorsAtTime:TestTime(0) mouseDown:YES error:nil]);
    assert([h.flags[@(MMPositionEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED);
    assert([plugin updateTimingEditorsAtTime:TestTime(9) mouseDown:YES error:nil]);
    assert([h.flags[@(MMPositionEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED);
    assert(h.nativeKeyReads == reads && h.mutations == mutations && h.blobWrites == blobs);
    // A cache miss must disable stale controls, never enumerate while held.
    plugin.timingLanes[0].durationSnapshot = nil;
    assert([plugin updateTimingEditorsAtTime:TestTime(3) mouseDown:YES error:nil]);
    assert([h.flags[@(MMPositionEasing)] unsignedIntValue] & kFxParameterFlag_DISABLED);
    assert(h.nativeKeyReads == reads);
    plugin.hasPendingNativeEdits = YES;
    NSUInteger heldWrites = h.hostWrites;
    assert([plugin updateTimingEditorsAtTime:TestTime(3) mouseDown:YES error:nil]);
    assert(plugin.hasPendingNativeEdits && h.hostWrites == heldWrites);
    plugin.hasPendingNativeEdits = NO;
    puts("Easing: incoming-only selectors, scalar rendering, persistence, movement, linked/matched propagation and echo suppression passed");
  }
}
