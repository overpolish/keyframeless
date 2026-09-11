/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import <math.h>

@interface MatchFixture : NSObject
@property MockHost *host;
@property MagicMovePlugin *plugin;
@end

@implementation MatchFixture
- (instancetype)init {
  if ((self = [super init])) {
    _host = [MockHost new];
    _plugin = [[MagicMovePlugin alloc] initWithAPIManager:_host];
    _host.plugin = _plugin;
    assert([_plugin addParametersWithError:nil]);
  }
  return self;
}
@end

static BOOL isDisabled(MockHost *h, UInt32 p) {
  return [h.flags[@(p)] unsignedIntValue] & kFxParameterFlag_DISABLED;
}
static UInt32 matchID(UInt32 value) { return value == MMPositionX ? MMPositionMatch : MMScaleMatch; }
static UInt32 dataID(UInt32 value) { return value == MMPositionX ? MMDurationData : MMScaleDurationData; }
static MTDurationRecord rec(MatchFixture *f, UInt32 value, NSUInteger i) {
  NSData *data = TestData(f.host, value, dataID(value));
  assert(data && i < data.length / sizeof(MTDurationRecord));
  return ((MTDurationRecord *)data.bytes)[i];
}
static void toggle(MatchFixture *f, UInt32 p, double time, BOOL enabled) {
  [f.plugin refreshDurationAtTime:TestTime(time)];
  f.host.editors[@(p)] = @(enabled);
  TestChange(f.host, p, time);
}
static BOOL tryToggle(MatchFixture *f, UInt32 p, double time, BOOL enabled) {
  NSError *error = nil;
  [f.plugin refreshDurationAtTime:TestTime(time)];
  f.host.editors[@(p)] = @(enabled);
  BOOL changed = [f.plugin parameterChanged:p atTime:TestTime(time) error:&error];
  if (!changed || error) return NO;
  return [f.plugin commitPendingEditsWithMouseDown:NO atTime:TestTime(time) error:&error] && !error;
}
static void setDuration(MatchFixture *f, double time, double value) {
  [f.plugin refreshDurationAtTime:TestTime(time)];
  f.host.editors[@(MMTransitionDuration)] = @(value);
  TestChange(f.host, MMTransitionDuration, time);
}
static void setNativeValue(MatchFixture *f, UInt32 value, double time, double number) {
  MagicMovePlugin *plugin = f.host.plugin;
  f.host.plugin = nil;
  [f.host setFloatValue:number toParameter:value atTime:TestTime(time)];
  f.host.plugin = plugin;
  TestChange(f.host, value, time);
}
static void makeKeys(MatchFixture *f, UInt32 value, NSUInteger count) {
  for (NSUInteger i = 0; i < count; i++) TestAdd(f.host, value, (double)i * 2, (double)(i + 1) * 10);
}

static void testContractAndBoundaryAvailability(void) {
  MatchFixture *f = [MatchFixture new];
  for (NSNumber *number in @[ @(MMPositionX), @(MMScale) ]) {
    UInt32 value = number.unsignedIntValue;
    UInt32 sharedID = matchID(value);
    UInt32 flags = [f.host.flags[@(sharedID)] unsignedIntValue];
    assert(flags & kFxParameterFlag_NOT_ANIMATABLE);
    assert(flags & kFxParameterFlag_DONT_SAVE);
    assert(flags & kFxParameterFlag_DISABLED);
    TestAdd(f.host, value, 0, 10);
    TestAdd(f.host, value, 2, 20);
    [f.plugin refreshDurationAtTime:TestTime(0)];
    assert(!isDisabled(f.host, sharedID));
    [f.plugin refreshDurationAtTime:TestTime(2)];
    assert(!isDisabled(f.host, sharedID));
    [f.plugin refreshDurationAtTime:TestTime(1)];
    assert(isDisabled(f.host, sharedID));
  }
}

static void testEnableFromEitherEndAndValuePropagation(void) {
  MatchFixture *f = [MatchFixture new];
  makeKeys(f, MMPositionX, 3);
  toggle(f, MMPositionMatch, 0, YES);
  assert(rec(f, MMPositionX, 0).value == rec(f, MMPositionX, 2).value);
  assert(rec(f, MMPositionX, 0).linkID == 0); // Matching is lane-local.
  setNativeValue(f, MMPositionX, 0, 77);
  assert([f.host.lanes[@(MMPositionX)][0][@"value"] doubleValue] == 77);
  assert([f.host.lanes[@(MMPositionX)][2][@"value"] doubleValue] == 77);
  setNativeValue(f, MMPositionX, 4, 91);
  assert([f.host.lanes[@(MMPositionX)][0][@"value"] doubleValue] == 91);
  assert([f.host.lanes[@(MMPositionX)][2][@"value"] doubleValue] == 91);

  f = [MatchFixture new];
  makeKeys(f, MMScale, 3);
  toggle(f, MMScaleMatch, 4, YES);
  assert(rec(f, MMScale, 0).value == rec(f, MMScale, 2).value);
}

static void testTimingPropagationAndInteriorIsolation(void) {
  MatchFixture *f = [MatchFixture new];
  makeKeys(f, MMPositionX, 4);
  double firstDuration = rec(f, MMPositionX, 0).duration;
  double middleDuration = rec(f, MMPositionX, 2).duration;
  toggle(f, MMPositionMatch, 6, YES);
  setDuration(f, 6, 1.25);
  assert(rec(f, MMPositionX, 3).duration == 1.25);
  assert(rec(f, MMPositionX, 0).duration == firstDuration); // KP1 timing is not mirrored.
  setDuration(f, 0, 2.0);
  assert(rec(f, MMPositionX, 3).duration == 1.25); // KP1 timing never mirrors.
  setDuration(f, 2, 0.4);
  assert(rec(f, MMPositionX, 1).duration == 0.4);
  assert(rec(f, MMPositionX, 3).duration == 0.4);
  assert(rec(f, MMPositionX, 2).duration == middleDuration);
}

static void testTwoToThreeInsertionAndDisable(void) {
  MatchFixture *f = [MatchFixture new];
  makeKeys(f, MMPositionX, 2);
  setDuration(f, 2, 0.8);
  toggle(f, MMPositionMatch, 0, YES);
  assert(rec(f, MMPositionX, 1).duration == 0.8);
  TestAdd(f.host, MMPositionX, 1, 15);
  assert(rec(f, MMPositionX, 2).duration == 0.8);
  double matchedValue = rec(f, MMPositionX, 2).value;
  toggle(f, MMPositionMatch, 0, NO);
  assert(rec(f, MMPositionX, 2).value == matchedValue);
  assert(rec(f, MMPositionX, 2).duration == 0.8);
}

static void testSingleKeyTimingBoundaries(void) {
  MatchFixture *f = [MatchFixture new];
  double lastFrame = 10 - 1.0 / 30.0;
  TestAdd(f.host, MMPositionX, lastFrame, 42);
  toggle(f, MMPositionMatch, lastFrame, YES);
  assert([f.host lane:MMPositionX].count == 2);
  assert(fabs([f.host.lanes[@(MMPositionX)][0][@"time"] doubleValue]) < 1e-6);
  f = [MatchFixture new];
  TestAdd(f.host, MMScale, lastFrame, 99);
  toggle(f, MMScaleMatch, lastFrame, YES);
  assert([f.host lane:MMScale].count == 2);
  assert([f.host.lanes[@(MMScale)][0][@"time"] doubleValue] == 0);
}

static void testFailureRollsBackNativeAndBlobMutations(void) {
  MatchFixture *f = [MatchFixture new];
  TestAdd(f.host, MMPositionX, 0, 10);
  NSUInteger oldCount = [f.host lane:MMPositionX].count;
  NSData *oldData = [((KKDataBlob *)f.host.blobs[@(MMDurationData)]).data copy];
  f.host.failAddOnce = 1;
  assert(!tryToggle(f, MMPositionMatch, 0, YES));
  assert([f.host lane:MMPositionX].count == oldCount);
  assert([((KKDataBlob *)f.host.blobs[@(MMDurationData)]).data isEqual:oldData]);
  f.host.failBlobOnce = MMDurationData;
  assert(!tryToggle(f, MMPositionMatch, 0, YES));
  assert([f.host lane:MMPositionX].count == oldCount);
}

static void testPersistenceAndLegacyDefaults(void) {
  MatchFixture *f = [MatchFixture new];
  makeKeys(f, MMPositionX, 2);
  toggle(f, MMPositionMatch, 0, YES);
  MTDurationRecord a = rec(f, MMPositionX, 0), b = rec(f, MMPositionX, 1);
  assert(a.matchEndpoints && b.matchEndpoints);
  NSArray *saved = [NSJSONSerialization JSONObjectWithData:
      ((KKDataBlob *)f.host.blobs[@(MMDurationData)]).data options:0 error:nil];
  NSMutableArray *legacy = [NSMutableArray array];
  for (NSDictionary *entry in saved) {
    NSMutableDictionary *copy = [entry mutableCopy];
    [copy removeObjectForKey:@"matchEndpoints"];
    [legacy addObject:copy];
  }
  NSData *legacyData = [NSJSONSerialization dataWithJSONObject:legacy options:0 error:nil];
  f.host.blobs[@(MMDurationData)] = [KKDataBlob blobWithData:legacyData];
  assert(!rec(f, MMPositionX, 0).matchEndpoints);
}

static void testMatchingDoesNotCoupleOtherLane(void) {
  MatchFixture *f = [MatchFixture new];
  makeKeys(f, MMPositionX, 2);
  TestAdd(f.host, MMScale, 0, 100);
  TestAdd(f.host, MMScale, 2, 200);
  TestLinkPose(f.host, MMPositionLink, 2, YES);
  toggle(f, MMPositionMatch, 0, YES);
  assert([f.host lane:MMScale].count == 2);
  assert([f.host.lanes[@(MMScale)][0][@"value"] doubleValue] == 100);
  assert([f.host.lanes[@(MMScale)][1][@"value"] doubleValue] == 200);
  assert(rec(f, MMPositionX, 0).matchEndpoints && rec(f, MMPositionX, 1).matchEndpoints);

  // A linked pose can still propagate timing across lanes, while matching
  // remains value-local to each lane.
  f = [MatchFixture new];
  makeKeys(f, MMPositionX, 3);
  makeKeys(f, MMScale, 3);
  TestLinkPose(f.host, MMPositionLink, 4, YES);
  toggle(f, MMPositionMatch, 0, YES);
  setDuration(f, 2, 0.65);
  assert(rec(f, MMPositionX, 2).duration == 0.65);
  assert(rec(f, MMScale, 2).duration == 0.65);
  assert([f.host.lanes[@(MMScale)][0][@"value"] doubleValue] == 10);
}

static void testTimingRejectionAndBoundaryRollback(void) {
  MatchFixture *f = [MatchFixture new];
  TestAdd(f.host, MMPositionX, 2, 42);
  NSUInteger count = [f.host lane:MMPositionX].count, mutations = f.host.mutations;
  NSUInteger writes = f.host.hostWrites, blobs = f.host.blobWrites;
  f.host.missingProtocols = [NSSet setWithObject:@"FxTimingAPI_v4"];
  assert(!tryToggle(f, MMPositionMatch, 2, YES));
  assert([f.host lane:MMPositionX].count == count && f.host.mutations == mutations &&
         f.host.hostWrites == writes && f.host.blobWrites == blobs);

  f = [MatchFixture new];
  TestAdd(f.host, MMPositionX, 2, 42);
  count = [f.host lane:MMPositionX].count; mutations = f.host.mutations;
  f.host.frameDuration = TestTime(0);
  assert(!tryToggle(f, MMPositionMatch, 2, YES));
  assert([f.host lane:MMPositionX].count == count && f.host.mutations == mutations);

  f = [MatchFixture new];
  TestAdd(f.host, MMPositionX, 0, 42);
  f.host.effectDuration = f.host.frameDuration;
  count = [f.host lane:MMPositionX].count; mutations = f.host.mutations;
  assert(!tryToggle(f, MMPositionMatch, 0, YES));
  assert([f.host lane:MMPositionX].count == count && f.host.mutations == mutations);
}

static void testDisableRestoresIndependentEdits(void) {
  MatchFixture *f = [MatchFixture new];
  makeKeys(f, MMPositionX, 2);
  toggle(f, MMPositionMatch, 0, YES);
  toggle(f, MMPositionMatch, 0, NO);
  double last = [f.host.lanes[@(MMPositionX)][1][@"value"] doubleValue];
  setNativeValue(f, MMPositionX, 0, 88);
  assert([f.host.lanes[@(MMPositionX)][0][@"value"] doubleValue] == 88);
  assert([f.host.lanes[@(MMPositionX)][1][@"value"] doubleValue] == last);
}

static void testAvailableTimeConnectedAcrossLinkedMatchingLanes(void) {
  MatchFixture *f = [MatchFixture new];
  makeKeys(f, MMPositionX, 3);
  makeKeys(f, MMScale, 3);
  TestLinkPose(f.host, MMPositionLink, 2, YES);
  toggle(f, MMPositionMatch, 0, YES);
  toggle(f, MMScaleMatch, 0, YES);
  [f.plugin refreshDurationAtTime:TestTime(2)];
  f.host.editors[@(MMPositionAvailableTime)] = @YES;
  TestChange(f.host, MMPositionAvailableTime, 2);
  assert(rec(f, MMPositionX, 1).useAvailableTime && rec(f, MMPositionX, 2).useAvailableTime);
  assert(rec(f, MMScale, 1).useAvailableTime && rec(f, MMScale, 2).useAvailableTime);
}

static void testMatchedEndpointReleaseDoesNotReadNativeKeys(void) {
  MatchFixture *f = [MatchFixture new];
  makeKeys(f, MMPositionX, 3);
  toggle(f, MMPositionMatch, 0, YES);
  MagicMovePlugin *plugin = f.host.plugin;
  f.host.plugin = nil;
  [f.host setFloatValue:66 toParameter:MMPositionX atTime:TestTime(0)];
  f.host.plugin = plugin;
  NSError *error = nil;
  assert([plugin parameterChanged:MMPositionX atTime:TestTime(0) error:&error] && !error);
  NSUInteger reads = f.host.nativeKeyReads;
  assert([plugin commitPendingEditsWithMouseDown:NO atTime:TestTime(0) error:&error] && !error);
  assert(f.host.nativeKeyReads == reads);
}

#define RUN(test) do { @autoreleasepool { printf("  %s ... ", #test); fflush(stdout); test(); puts("passed"); } } while (0)
int main(void) {
  RUN(testContractAndBoundaryAvailability);
  RUN(testEnableFromEitherEndAndValuePropagation);
  RUN(testTimingPropagationAndInteriorIsolation);
  RUN(testTwoToThreeInsertionAndDisable);
  RUN(testSingleKeyTimingBoundaries);
  RUN(testFailureRollsBackNativeAndBlobMutations);
  RUN(testPersistenceAndLegacyDefaults);
  RUN(testMatchingDoesNotCoupleOtherLane);
  RUN(testTimingRejectionAndBoundaryRollback);
  RUN(testDisableRestoresIndependentEdits);
  RUN(testAvailableTimeConnectedAcrossLinkedMatchingLanes);
  RUN(testMatchedEndpointReleaseDoesNotReadNativeKeys);
  puts("MagicMove match endpoints: 12 test groups passed");
}
