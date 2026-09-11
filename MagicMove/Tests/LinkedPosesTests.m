/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import <float.h>

// A detached library/drag instance must never start the host-action timer.
@interface LifecycleProbe : MagicMovePlugin
@property NSUInteger refreshStarts;
@end
@implementation LifecycleProbe
- (void)startDurationRefresh {
  self.refreshStarts += 1;
}
@end
int main() {
  @autoreleasepool {
    MockHost *lifecycleHost = [MockHost new];
    LifecycleProbe *lifecycle =
        [[LifecycleProbe alloc] initWithAPIManager:lifecycleHost];
    assert([lifecycle addParametersWithError:nil]);
    assert(lifecycle.refreshStarts == 0);
    [lifecycle pluginInstanceAddedToDocument];
    assert(lifecycle.refreshStarts == 1);
    MockHost *h = [MockHost new];
    MagicMovePlugin *p = [[MagicMovePlugin alloc] initWithAPIManager:h];
    h.plugin = p;
    // Creating keys is independent, regardless of the retired global flag.
    h.linked = YES;
    TestAdd(h, MMPositionX, 0, -50);
    TestAdd(h, MMPositionX, 2, 50);
    assert([h lane:MMScale].count == 0);
    // Link a destination first, then the initial pose; both create silent
    // partners.
    TestLinkPose(h, MMPositionLink, 2, YES);
    assert([h lane:MMScale].count == 1);
    assert([h.lanes[@(MMScale)][0][@"value"] doubleValue] == 100);
    TestLinkPose(h, MMPositionLink, 0, YES);
    assert([h lane:MMScale].count == 2);
    assert(p.timingLanes[0].linkEditorEnabled &&
           p.timingLanes[0].linkEditorValue);
    assert(!p.timingLanes[0].durationEditorEnabled);
    [p refreshDurationAtTime:TestTime(1)];
    assert(!p.timingLanes[0].linkEditorEnabled);
    [p refreshDurationAtTime:TestTime(2)];
    assert(p.timingLanes[1].linkEditorValue);
    h.editors[@(MMTransitionDuration)] = @0.4;
    TestChange(h, MMTransitionDuration, 2);
    NSData *d = TestData(h, MMScale, MMScaleDurationData);
    assert(((MTDurationRecord *)d.bytes)[1].duration == 0.4);
    h.editors[@(MMScaleAvailableTime)] = @YES;
    TestChange(h, MMScaleAvailableTime, 2);
    d = TestData(h, MMPositionX, MMDurationData);
    assert(((MTDurationRecord *)d.bytes)[1].useAvailableTime);
    TestMove(h, MMPositionX, 1, 3);
    assert([h.lanes[@(MMScale)][1][@"time"] doubleValue] == 3);
    assert([h.lanes[@(MMScale)][1][@"value"] doubleValue] == 100);
    // Nearby new keys remain independent until explicitly linked.
    TestAdd(h, MMScale, 4, 150);
    assert([h lane:MMPositionX].count == 2);
    TestMove(h, MMScale, 2, 5);
    assert([h lane:MMPositionX].count == 2);
    TestLinkPose(h, MMScaleLink, 5, YES);
    assert([h lane:MMPositionX].count == 3);
    TestMove(h, MMScale, 2, 1);
    assert([h.lanes[@(MMPositionX)][1][@"time"] doubleValue] == 1);
    d = TestData(h, MMPositionX, MMDurationData);
    assert(((MTDurationRecord *)d.bytes)[2].useAvailableTime);
    TestRemovePose(h, MMScale, 1, 1);
    assert([h lane:MMPositionX].count == 2);
    // Unlinking one pair leaves another pair linked and preserves
    // settings/keys.
    TestLinkPose(h, MMPositionLink, 3, NO);
    assert([h lane:MMScale].count == 2);
    d = TestData(h, MMScale, MMScaleDurationData);
    assert(((MTDurationRecord *)d.bytes)[1].duration == 0.4);
    assert(!((MTDurationRecord *)d.bytes)[1].linkID &&
           ((MTDurationRecord *)d.bytes)[0].linkID);
    TestMove(h, MMPositionX, 1, 5);
    assert([h.lanes[@(MMScale)][1][@"time"] doubleValue] == 3);
    TestMove(h, MMScale, 0, 0.5);
    assert([h.lanes[@(MMPositionX)][0][@"time"] doubleValue] == 0.5);
    NSUInteger beforeEcho = h.mutations;
    TestChange(h, MMPositionX, 0.5);
    assert(h.mutations == beforeEcho);
    // Persisted IDs continue working with a new plugin instance, even if the
    // old global switch is off.
    h.linked = NO;
    MagicMovePlugin *reopened = [[MagicMovePlugin alloc] initWithAPIManager:h];
    h.plugin = reopened;
    TestMove(h, MMPositionX, 0, 0);
    assert([h.lanes[@(MMScale)][0][@"time"] doubleValue] == 0);
    // A missing partner samples the other property's native value at this time.
    MockHost *sample = [MockHost new];
    MagicMovePlugin *sp = [[MagicMovePlugin alloc] initWithAPIManager:sample];
    sample.plugin = sp;
    TestAdd(sample, MMScale, 0, 100);
    TestAdd(sample, MMScale, 4, 200);
    TestAdd(sample, MMPositionX, 2, 40);
    TestLinkPose(sample, MMPositionLink, 2, YES);
    assert([sample.lanes[@(MMScale)][1][@"value"] doubleValue] == 150);
    d = TestData(sample, MMScale, MMScaleDurationData);
    assert(!((MTDurationRecord *)d.bytes)[0].linkID &&
           ((MTDurationRecord *)d.bytes)[1].linkID &&
           !((MTDurationRecord *)d.bytes)[2].linkID);
    // Existing aligned keys are paired without replacing their values or adding
    // keys.
    TestAdd(sample, MMPositionX, 0, -30);
    TestLinkPose(sample, MMScaleLink, 0, YES);
    assert([sample lane:MMPositionX].count == 2 &&
           [sample.lanes[@(MMPositionX)][0][@"value"] doubleValue] == -30);
    // Fail each metadata write after a native partner move and verify rollback.
    for (NSNumber *failureID in
         @[ @(MMDurationData), @(MMScaleDurationData) ]) {
      MockHost *f = [MockHost new];
      MagicMovePlugin *fp = [[MagicMovePlugin alloc] initWithAPIManager:f];
      f.plugin = fp;
      TestAdd(f, MMPositionX, 0, 0);
      TestAdd(f, MMPositionX, 2, 80);
      TestLinkPose(f, MMPositionLink, 0, YES);
      TestLinkPose(f, MMPositionLink, 2, YES);
      NSData *oldSource = ((KKDataBlob *)f.blobs[@(MMDurationData)]).data;
      NSData *oldPartner = ((KKDataBlob *)f.blobs[@(MMScaleDurationData)]).data;
      f.failBlobOnce = failureID.unsignedIntValue;
      TestFailedMove(f, 3);
      assert([f.lanes[@(MMScale)][1][@"time"] doubleValue] == 2);
      assert([f.lanes[@(MMScale)][1][@"value"] doubleValue] == 100);
      assert(
          [((KKDataBlob *)f.blobs[@(MMDurationData)]).data isEqual:oldSource]);
      assert([((KKDataBlob *)f.blobs[@(MMScaleDurationData)]).data
          isEqual:oldPartner]);
    }
    // Failed creation of a silent partner restores both saved records and
    // native keys.
    MockHost *f = [MockHost new];
    MagicMovePlugin *fp = [[MagicMovePlugin alloc] initWithAPIManager:f];
    f.plugin = fp;
    TestAdd(f, MMPositionX, 0, 0);
    f.editors[@(MMPositionLink)] = @YES;
    f.failBlobOnce = MMScaleDurationData;
    NSError *failure = nil;
    assert(![fp parameterChanged:MMPositionLink
                          atTime:TestTime(0)
                           error:&failure] &&
           failure);
    assert([f lane:MMScale].count == 0);
    d = TestData(f, MMPositionX, MMDurationData);
    assert(!((MTDurationRecord *)d.bytes)[0].linkID);
    // A native API failure restores the partner, including its value.
    TestLinkPose(f, MMPositionLink, 0, YES);
    TestAdd(f, MMPositionX, 2, 90);
    TestLinkPose(f, MMPositionLink, 2, YES);
    MagicMovePlugin *keep = f.plugin;
    f.plugin = nil;
    FxKeyframe key;
    [f keyframe:&key forParameter:MMPositionX channel:0 andIndex:1];
    key.time = TestTime(3);
    [f setKeyframeIndex:1
           withKeyframe:&key
           forParameter:MMPositionX
             andChannel:0];
    f.plugin = keep;
    f.failAddOnce = YES;
    failure = nil;
    assert([fp parameterChanged:MMPositionX atTime:TestTime(3) error:&failure]);
    assert(![fp commitPendingEditsWithMouseDown:NO atTime:TestTime(3) error:&failure] && failure);
    assert([f.lanes[@(MMScale)][1][@"time"] doubleValue] == 2);
    // Reproduce the host wrapper dropping the middle key's requested index.
    MockHost *broken = [MockHost new];
    MagicMovePlugin *bp = [[MagicMovePlugin alloc] initWithAPIManager:broken];
    broken.plugin = bp;
    for (NSNumber *property in @[@(MMPositionX), @(MMScale)]) {
      TestAdd(broken, property.unsignedIntValue, 0, 0);
      TestAdd(broken, property.unsignedIntValue, 148.0/60, -31.2);
      TestAdd(broken, property.unsignedIntValue, 299.0/60, 29.8);
    }
    TestLinkPose(broken, MMScaleLink, 148.0/60, YES);
    d = TestData(broken, MMPositionX, MMDurationData);
    MTDurationRecord original = ((MTDurationRecord *)d.bytes)[1];
    broken.ignorePluginMoveIndex = YES;
    TestMove(broken, MMScale, 1, 146.0/60);
    assert([broken lane:MMPositionX].count == 3);
    assert([broken.lanes[@(MMPositionX)][0][@"time"] doubleValue] == 0);
    assert(fabs([broken.lanes[@(MMPositionX)][1][@"time"] doubleValue] - CMTimeGetSeconds(TestTime(146.0/60))) < 1e-9);
    assert(fabs([broken.lanes[@(MMPositionX)][2][@"time"] doubleValue] - CMTimeGetSeconds(TestTime(299.0/60))) < 1e-9);
    d = TestData(broken, MMPositionX, MMDurationData);
    MTDurationRecord moved = ((MTDurationRecord *)d.bytes)[1];
    assert(moved.value == original.value && moved.linkID == original.linkID);
    assert(moved.duration == original.duration && moved.useAvailableTime == original.useAvailableTime);
    // Motion can deliver notifications after the plugin's synchronous write
    // guard clears.
    MockHost *delayed = [MockHost new];
    MagicMovePlugin *dp = [[MagicMovePlugin alloc] initWithAPIManager:delayed];
    delayed.plugin = dp;
    TestAdd(delayed, MMPositionX, 0, 0);
    TestAdd(delayed, MMPositionX, 2, 80);
    TestLinkPose(delayed, MMPositionLink, 0, YES);
    TestLinkPose(delayed, MMPositionLink, 2, YES);
    delayed.deferCallbacks = YES;
    TestMove(delayed, MMPositionX, 1, 3);
    // Scrubbing off the pose publishes unchecked transient rows before the old
    // callbacks arrive.
    [dp refreshDurationAtTime:TestTime(2.5)];
    assert([delayed drainCallbacks]);
    d = TestData(delayed, MMPositionX, MMDurationData);
    uint64_t pair = ((MTDurationRecord *)d.bytes)[1].linkID;
    assert(pair != 0);
    d = TestData(delayed, MMScale, MMScaleDurationData);
    assert(((MTDurationRecord *)d.bytes)[1].linkID == pair);
    assert([delayed.lanes[@(MMScale)][1][@"time"] doubleValue] == 3);
    // Several drag updates can precede the partner's notifications.
    TestMove(delayed, MMPositionX, 1, 3.25);
    TestMove(delayed, MMPositionX, 1, 3.5);
    TestMove(delayed, MMPositionX, 1, 4);
    [dp refreshDurationAtTime:TestTime(3.75)];
    assert([delayed drainCallbacks]);
    assert([delayed.lanes[@(MMScale)][1][@"time"] doubleValue] == 4);
    d = TestData(delayed, MMScale, MMScaleDurationData);
    assert(((MTDurationRecord *)d.bytes)[1].linkID == pair);
    // A native drag burst must not write partner keys, blobs or inspector rows
    // until the mouse is released. Exercise raw callbacks, not TestMove's
    // convenience mouse release for completed edits.
    MockHost *burst = [MockHost new];
    MagicMovePlugin *burstPlugin = [[MagicMovePlugin alloc] initWithAPIManager:burst];
    burst.plugin = burstPlugin;
    TestAdd(burst, MMPositionX, 0, 0);
    TestAdd(burst, MMPositionX, 2, 80);
    TestLinkPose(burst, MMPositionLink, 2, YES);
    NSUInteger groupsBefore = burst.undoGroupsStarted;
    NSUInteger writesBefore = burst.hostWrites;
    NSUInteger flagsBefore = burst.flagWrites;
    NSUInteger blobsBefore = burst.blobWrites;
    NSUInteger mutationsBefore = burst.mutations;
    NSError *burstError = nil;
    for (NSNumber *arrival in @[@3, @3.5, @4]) {
      burst.plugin = nil;
      FxKeyframe movedKey;
      [burst keyframe:&movedKey forParameter:MMPositionX channel:0 andIndex:1];
      movedKey.time = TestTime(arrival.doubleValue);
      [burst setKeyframeIndex:1 withKeyframe:&movedKey forParameter:MMPositionX andChannel:0];
      burst.plugin = burstPlugin;
      assert([burstPlugin parameterChanged:MMPositionX atTime:TestTime(2) error:&burstError]);
      [burstPlugin refreshDurationAtTime:TestTime(2)];
      assert([burstPlugin commitPendingEditsWithMouseDown:YES atTime:TestTime(2) error:&burstError]);
      assert([burst.lanes[@(MMScale)][0][@"time"] doubleValue] == 2);
      assert(burst.hostWrites == writesBefore && burst.flagWrites == flagsBefore && burst.blobWrites == blobsBefore);
    }
    assert(burst.mutations == mutationsBefore+3); // User's three moves only.
    burst.deferCallbacks = YES;
    NSUInteger readsBeforeRelease = burst.nativeKeyReads;
    assert([burstPlugin commitPendingEditsWithMouseDown:NO atTime:TestTime(2) error:&burstError]);
    assert(!burstError);
    assert(burst.nativeKeyReads == readsBeforeRelease);
    assert(burst.undoGroupsStarted == groupsBefore+1);
    assert(burst.undoGroupsStarted == burst.undoGroupsEnded && burst.undoDepth == 0);
    assert([burst.lanes[@(MMScale)][0][@"time"] doubleValue] == 4);
    assert(burst.mutations == mutationsBefore+5); // One remove and one add.
    assert(!burstPlugin.hasPendingNativeEdits && !burstPlugin.timingLanes[0].pendingDestinations);
    // The host sends our native/blob notifications after the group has closed.
    // These must not rewrite identical inspector values outside that group.
    NSUInteger writesAfterRelease = burst.hostWrites;
    assert([burst drainCallbacks]);
    [burstPlugin refreshDurationAtTime:TestTime(2)];
    assert(burst.hostWrites == writesAfterRelease);
    NSUInteger afterSettlement = burst.mutations;
    assert([burstPlugin commitPendingEditsWithMouseDown:NO atTime:TestTime(2) error:&burstError]);
    assert(burst.mutations == afterSettlement);

    // Real inspector changes still work with delayed notifications enabled.
    [dp refreshDurationAtTime:TestTime(4)];
    assert([delayed drainCallbacks]);
    delayed.editors[@(MMTransitionDuration)] = @0.75;
    TestChange(delayed, MMTransitionDuration, 4);
    assert([delayed drainCallbacks]);
    d = TestData(delayed, MMScale, MMScaleDurationData);
    assert(((MTDurationRecord *)d.bytes)[1].duration == 0.75);
    TestLinkPose(delayed, MMScaleLink, 4, NO);
    assert([delayed drainCallbacks]);
    d = TestData(delayed, MMPositionX, MMDurationData);
    assert(((MTDurationRecord *)d.bytes)[1].linkID == 0);

    puts("Linked poses mock host: document-attachment lifecycle, per-pose "
         "controls, silent partners, independent keys, timing, moves, delete, "
         "unlink, persistence, rollback, delayed-callback draining and drag "
         "bursts passed");
  }
}
