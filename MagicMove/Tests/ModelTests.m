/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "ShaderTypes.h"
#import <math.h>

@interface Fixture : NSObject
@property MockHost *host;
@property MagicMovePlugin *plugin;
@end
@implementation Fixture
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
static BOOL disabled(MockHost *h, UInt32 p) {
  return [h.flags[@(p)] unsignedIntValue] & kFxParameterFlag_DISABLED;
}
static void duration(Fixture *f, UInt32 editor, double time, double value) {
  [f.plugin refreshDurationAtTime:TestTime(time)];
  f.host.editors[@(editor)] = @(value);
  TestChange(f.host, editor, time);
}
static void available(Fixture *f, UInt32 editor, double time, BOOL value) {
  [f.plugin refreshDurationAtTime:TestTime(time)];
  f.host.editors[@(editor)] = @(value);
  TestChange(f.host, editor, time);
}
static void sample(Fixture *f, double time, double x, double scale) {
  NSData *state = nil;
  NSError *error = nil;
  NSUInteger writes = f.host.hostWrites, mutations = f.host.mutations;
  assert([f.plugin pluginState:&state
                        atTime:TestTime(time)
                       quality:0
                         error:&error] &&
         !error);
  assert(state.length == sizeof(MMTransform));
  MMTransform transform;
  [state getBytes:&transform length:sizeof(transform)];
  assert(fabs(transform.offset.x - x / 100) < 1e-6 &&
         fabs(transform.offset.y) < 1e-6);
  assert(fabs(transform.scale - scale / 100) < 1e-6);
  assert(f.host.hostWrites == writes &&
         f.host.mutations == mutations); // Rendering never edits host state.
}
static MTDurationRecord record(Fixture *f, UInt32 valueID, UInt32 dataID,
                               NSUInteger index) {
  NSData *d = TestData(f.host, valueID, dataID);
  assert(d && index < d.length / sizeof(MTDurationRecord));
  return ((const MTDurationRecord *)d.bytes)[index];
}
static void testParameterContract(void) {
  Fixture *f = [Fixture new];
  MockHost *h = f.host;
  NSUInteger visible = 0;
  for (NSNumber *key in h.definitions) {
    assert(key.unsignedIntValue >= 1 && key.unsignedIntValue <= 9999);
    if (!([h.flags[key] unsignedIntValue] & kFxParameterFlag_HIDDEN))
      visible++;
  }
  assert(
      visible ==
      10); // Five native rows per property, no groups or custom inspector rows.
  assert([h.definitions[@(MMPositionX)][@"default"] doubleValue] == 0);
  assert([h.definitions[@(MMScale)][@"default"] doubleValue] == 100);
  for (NSNumber *key in @[ @(MMPositionX), @(MMScale) ])
    assert(
        !([h.flags[key] unsignedIntValue] & kFxParameterFlag_NOT_ANIMATABLE));
  for (NSNumber *key in @[
         @(MMTransitionDuration), @(MMPositionAvailableTime), @(MMPositionLink),
         @(MMPositionMatch),
         @(MMScaleDuration), @(MMScaleAvailableTime), @(MMScaleLink),
         @(MMScaleMatch)
       ]) {
    UInt32 flags = [h.flags[key] unsignedIntValue];
    assert(flags & kFxParameterFlag_NOT_ANIMATABLE);
    assert(flags & kFxParameterFlag_DONT_SAVE);
    assert(flags & kFxParameterFlag_DISABLED);
  }
  for (NSNumber *key in @[ @(MMPositionLegacyMatchOut), @(MMScaleLegacyMatchOut) ])
    assert([h.flags[key] unsignedIntValue] & kFxParameterFlag_HIDDEN);
  for (NSNumber *key in @[ @(MMDurationData), @(MMScaleDurationData) ]) {
    UInt32 flags = [h.flags[key] unsignedIntValue];
    assert(flags & kFxParameterFlag_HIDDEN);
    assert(!(flags & kFxParameterFlag_DONT_SAVE));
    assert([f.plugin classesForCustomParameterID:key.unsignedIntValue] &&
           [h.blobs[key] isKindOfClass:KKDataBlob.class]);
  }
  NSDictionary *properties = nil;
  assert([f.plugin properties:&properties error:nil]);
  assert([properties[kFxPropertyKey_VariesWhenParamsAreStatic] boolValue]);
  assert(![properties[kFxPropertyKey_MayRemapTime] boolValue]);
}
static void testStaticSingleAndIndependentClocks(void) {
  Fixture *f = [Fixture new];
  sample(f, -10, 0, 100);
  f.host.staticValues[@(MMPositionX)] = @25;
  f.host.staticValues[@(MMScale)] = @50;
  sample(f, 10, 25, 50);
  TestAdd(f.host, MMPositionX, 5, -50);
  sample(f, -3, -50, 50);
  sample(f, 100, -50, 50);
  f = [Fixture new];
  TestAdd(f.host, MMPositionX, -2, -100);
  TestAdd(f.host, MMPositionX, 2, 100);
  available(f, MMPositionAvailableTime, 2, YES);
  TestAdd(f.host, MMScale, 0, 100);
  TestAdd(f.host, MMScale, 4, 200);
  duration(f, MMScaleDuration, 4, 2);
  sample(f, 0, 0, 100);
  sample(f, 3, 100, 150);
  sample(f, -3, -100, 100);
  sample(f, 5, 100, 200);
  // Reordered render requests produce exactly the same samples.
  sample(f, 3, 100, 150);
  sample(f, 0, 0, 100);
}
static void testIncomingOwnershipAndAvailableTime(void) {
  Fixture *f = [Fixture new];
  TestAdd(f.host, MMPositionX, 0, 0);
  TestAdd(f.host, MMPositionX, 4, 100);
  TestAdd(f.host, MMPositionX, 8, 200);
  duration(f, MMTransitionDuration, 4, 2);
  duration(f, MMTransitionDuration, 8, 1);
  sample(f, 1, 0, 100);
  sample(f, 3, 50, 100);
  sample(f, 6, 100, 100);
  sample(f, 7.5, 150, 100);
  double native = 0;
  [f.host getFloatValue:&native fromParameter:MMPositionX atTime:TestTime(1)];
  assert(native == 25); // Native interpolation is not rendered motion.
  duration(f, MMTransitionDuration, 4, 0.5);
  sample(f, 6, 100, 100);
  sample(f, 7.5, 150, 100);
  available(f, MMPositionAvailableTime, 4, YES);
  sample(f, 2, 50, 100);
  assert(record(f, MMPositionX, MMDurationData, 1).duration == 0.5);
  assert(disabled(f.host, MMTransitionDuration));
  available(f, MMPositionAvailableTime, 4, NO);
  sample(f, 2, 0, 100);
  assert(!disabled(f.host, MMTransitionDuration));
  assert([f.host.editors[@(MMTransitionDuration)] doubleValue] == 0.5);
  duration(f, MMTransitionDuration, 4, 0);
  sample(f, 3.99, 0, 100);
  sample(f, 4, 100, 100);
}
static void testInsertionClampsWithoutRewritingDuration(void) {
  Fixture *f = [Fixture new];
  TestAdd(f.host, MMPositionX, 0, 0);
  TestAdd(f.host, MMPositionX, 4, 100);
  duration(f, MMTransitionDuration, 4, 2);
  TestAdd(f.host, MMPositionX, 3, 25);
  duration(f, MMTransitionDuration, 3, 0.8);
  sample(f, 3.5, 62.5, 100);
  assert(record(f, MMPositionX, MMDurationData, 2).duration == 2);
  TestRemovePose(f.host, MMPositionX, 1, 3);
  sample(f, 3, 50, 100);
  assert(record(f, MMPositionX, MMDurationData, 1).duration == 2);
  available(f, MMPositionAvailableTime, 4, YES);
  TestMove(f.host, MMPositionX, 1, 8);
  sample(f, 4, 50, 100);
  assert(record(f, MMPositionX, MMDurationData, 1).duration == 2);
}
static void testContextualRowsAndBoundaryTimes(void) {
  Fixture *f = [Fixture new];
  [f.plugin refreshDurationAtTime:TestTime(0)];
  assert(disabled(f.host, MMPositionLink));
  TestAdd(f.host, MMPositionX, 0, 0);
  TestAdd(f.host, MMPositionX, 2, 100);
  TestAdd(f.host, MMScale, 0, 100);
  TestAdd(f.host, MMScale, 3, 200);
  [f.plugin refreshDurationAtTime:TestTime(0)];
  assert(!disabled(f.host, MMPositionLink));
  assert(disabled(f.host, MMTransitionDuration));
  [f.plugin refreshDurationAtTime:TestTime(2)];
  assert(!disabled(f.host, MMTransitionDuration));
  assert(disabled(f.host, MMScaleDuration));
  NSUInteger writes = f.host.hostWrites;
  [f.plugin refreshDurationAtTime:TestTime(2)];
  assert(f.host.hostWrites == writes);
  [f.plugin refreshDurationAtTime:TestTime(2 - 1.0 / 30)];
  assert(disabled(f.host, MMTransitionDuration));
  assert(disabled(f.host, MMPositionLink));
  NSData *d = TestData(f.host, MMPositionX, MMDurationData);
  assert(MMKeyposeAtTime(d, TestTime(0)) == 0 &&
         MMDestinationAtTime(d, TestTime(0)) == NSNotFound);
  assert(MMDestinationAtTime(d, CMTimeMake(20000004, 10000000)) == 1);
  assert(MMDestinationAtTime(d, CMTimeMake(20000020, 10000000)) == NSNotFound);
  assert(MMDestinationAtTime(d, kCMTimeInvalid) == NSNotFound &&
         MMKeyposeAtTime(d, kCMTimeIndefinite) == NSNotFound);
  // A stale edit while no pose exists must not create keys or alter saved
  // records.
  NSData *old = ((KKDataBlob *)f.host.blobs[@(MMDurationData)]).data;
  f.host.editors[@(MMTransitionDuration)] = @0.2;
  TestChange(f.host, MMTransitionDuration, 1);
  assert([((KKDataBlob *)f.host.blobs[@(MMDurationData)]).data isEqual:old]);
  assert([f.host lane:MMPositionX].count == 2);
}
static void testSavedRecordsRoundTripAndLegacy(void) {
  Fixture *f = [Fixture new];
  TestAdd(f.host, MMPositionX, 0, 0);
  TestAdd(f.host, MMPositionX, 2, 100);
  f.host.blobs[@(MMDurationData)] = [KKDataBlob
      blobWithString:@"[{\"time\":0,\"value\":0,\"duration\":1.2},{\"time\":2,"
                     @"\"value\":100,\"duration\":0.3}]"];
  MTDurationRecord legacy = record(f, MMPositionX, MMDurationData, 1);
  assert(legacy.duration == 0.3 && !legacy.useAvailableTime && !legacy.linkID);
  NSMutableData *d =
      [TestData(f.host, MMPositionX, MMDurationData) mutableCopy];
  MTDurationRecord *r = d.mutableBytes;
  r[1].linkID = UINT64_MAX - 123;
  r[1].useAvailableTime = true;
  assert(MMWriteDestinations(f.host, MMDurationData, d));
  NSUInteger writes = f.host.blobWrites;
  assert(MMWriteDestinations(f.host, MMDurationData, d));
  assert(writes == f.host.blobWrites); // Idempotent save.
  NSError *error = nil;
  NSData *archive = [NSKeyedArchiver
      archivedDataWithRootObject:f.host.blobs[@(MMDurationData)]
           requiringSecureCoding:YES
                           error:&error];
  assert(archive && !error);
  KKDataBlob *decoded =
      [NSKeyedUnarchiver unarchivedObjectOfClass:KKDataBlob.class
                                        fromData:archive
                                           error:&error];
  assert(decoded && !error);
  f.host.blobs[@(MMDurationData)] = decoded;
  MTDurationRecord restored = record(f, MMPositionX, MMDurationData, 1);
  assert(restored.linkID == UINT64_MAX - 123 && restored.useAvailableTime &&
         restored.duration == 0.3);
  // No transient correspondence field leaks into the stored document.
  NSArray *json = [NSJSONSerialization JSONObjectWithData:decoded.data
                                                  options:0
                                                    error:nil];
  assert(!json[1][@"previousIndex"]);
}
static void testCorruptDataAndUnavailableAPIs(void) {
  MockHost *unavailable = [MockHost new];
  unavailable.missingProtocols =
      [NSSet setWithObject:@"FxParameterCreationAPI_v5"];
  MagicMovePlugin *unconfigured =
      [[MagicMovePlugin alloc] initWithAPIManager:unavailable];
  NSError *creationError = nil;
  assert(![unconfigured addParametersWithError:&creationError] &&
         creationError);
  assert(unavailable.definitions.count == 0);
  Fixture *f = [Fixture new];
  TestAdd(f.host, MMPositionX, 0, 0);
  NSArray *invalid = @[
    @"not json", @"{}", @"[4]", @"[{\"time\":0,\"value\":0}]",
    @"[{\"time\":0,\"value\":0,\"duration\":-1}]",
    @"[{\"time\":0,\"value\":0,\"duration\":1,\"linkID\":\"bad\"}]"
  ];
  for (NSString *json in invalid) {
    f.host.blobs[@(MMDurationData)] = [KKDataBlob blobWithString:json];
    NSError *error = nil;
    assert(!MMReadDestinations(f.host, MMPositionX, MMDurationData, &error) &&
           error);
  }
  f.host.blobs[@(MMDurationData)] = (id) @"wrong secure type";
  NSError *error = nil;
  assert(!MMReadDestinations(f.host, MMPositionX, MMDurationData, &error) &&
         error);
  f.host.blobs[@(MMDurationData)] = [KKDataBlob blobWithString:@"[]"];
  for (NSString *name in
       @[ @"FxKeyframeAPI_v3", @"FxParameterRetrievalAPI_v6" ]) {
    f.host.missingProtocols = [NSSet setWithObject:name];
    error = nil;
    assert(!MMReadDestinations(f.host, MMPositionX, MMDurationData, &error) &&
           error);
  }
  f.host.missingProtocols = nil;
  f.host.failReadParameter = MMPositionX;
  error = nil;
  assert(!MMReadDestinations(f.host, MMPositionX, MMDurationData, &error) &&
         error);
  f = [Fixture new];
  f.host.staticValues[@(MMScale)] = @(NAN);
  NSData *sentinel = [@"unchanged" dataUsingEncoding:NSUTF8StringEncoding],
         *state = sentinel;
  error = nil;
  assert(![f.plugin pluginState:&state
                         atTime:TestTime(0)
                        quality:0
                          error:&error] &&
         error);
  assert(state == sentinel);
}
static void testRestoredSnapshotsAndRenderGeneration(void) {
  Fixture *f = [Fixture new];
  TestAdd(f.host, MMPositionX, 0, 0);
  TestAdd(f.host, MMPositionX, 2, 100);
  duration(f, MMTransitionDuration, 2, 0.5);
  KKDataBlob *before = f.host.blobs[@(MMDurationData)];
  duration(f, MMTransitionDuration, 2, 1);
  KKDataBlob *after = f.host.blobs[@(MMDurationData)];
  // Simulate the host restoring saved metadata for undo/redo, not its undo
  // grouping implementation.
  for (KKDataBlob *blob in @[ before, after ]) {
    f.host.blobs[@(MMDurationData)] = blob;
    NSUInteger writes = f.host.blobWrites;
    TestChange(f.host, MMDurationData, 2);
    assert(writes == f.host.blobWrites);
    double expected = blob == before ? 0.5 : 1;
    assert([f.host.editors[@(MMTransitionDuration)] doubleValue] == expected);
  }
  MMTimingLane *lane = f.plugin.timingLanes[0];
  NSUInteger old = lane.durationGeneration;
  NSData *stale = [NSData dataWithBytes:"old" length:3];
  [f.plugin invalidateTimingLane:lane];
  [lane publishDurationSnapshot:stale generation:old];
  assert(lane.durationSnapshot == nil);
  NSData *fresh = TestData(f.host, MMPositionX, MMDurationData);
  [lane publishDurationSnapshot:fresh generation:lane.durationGeneration];
  assert([lane.durationSnapshot isEqual:fresh]);
  [lane publishDurationSnapshot:stale generation:old];
  assert([lane.durationSnapshot isEqual:fresh]);
}
static void testLinkedCollisionPreservesPartner(void) {
  Fixture *f = [Fixture new];
  TestAdd(f.host, MMPositionX, 0, 0);
  TestAdd(f.host, MMPositionX, 2, 80);
  TestLinkPose(f.host, MMPositionLink, 2, YES);
  TestAdd(f.host, MMScale, 4, 200);
  NSData *saved = ((KKDataBlob *)f.host.blobs[@(MMScaleDurationData)]).data;
  TestFailedMove(f.host, 4);
  assert([f.host lane:MMScale].count == 2);
  assert([f.host.lanes[@(MMScale)][0][@"time"] doubleValue] == 2 &&
         [f.host.lanes[@(MMScale)][1][@"time"] doubleValue] == 4);
  assert([f.host.lanes[@(MMScale)][1][@"value"] doubleValue] == 200);
  assert([((KKDataBlob *)f.host.blobs[@(MMScaleDurationData)]).data
      isEqual:saved]);
}
static void testMultiSelectionMovesOnlyLinkedPartners(void) {
  Fixture *f = [Fixture new];
  for (NSUInteger i = 0; i < 5; i++)
    TestAdd(f.host, MMPositionX, 2 * i, (i == 1 || i == 3) ? 10 : 20 * i);
  TestLinkPose(f.host, MMPositionLink, 2, YES);
  TestLinkPose(f.host, MMPositionLink, 6, YES);
  duration(f, MMTransitionDuration, 2, 0.25);
  duration(f, MMTransitionDuration, 6, 0.75);
  uint64_t first = record(f, MMPositionX, MMDurationData, 1).linkID,
           second = record(f, MMPositionX, MMDurationData, 3).linkID;
  TestAdd(f.host, MMScale, 7, 200);
  f.host.deferCallbacks = YES;
  // One native multiselect edit: K2 and K4 pass unchanged keys, preserving
  // their order.
  f.host.plugin = nil;
  FxKeyframe key;
  [f.host keyframe:&key forParameter:MMPositionX channel:0 andIndex:3];
  key.time = TestTime(9);
  [f.host setKeyframeIndex:3
              withKeyframe:&key
              forParameter:MMPositionX
                andChannel:0];
  [f.host keyframe:&key forParameter:MMPositionX channel:0 andIndex:1];
  key.time = TestTime(5);
  [f.host setKeyframeIndex:1
              withKeyframe:&key
              forParameter:MMPositionX
                andChannel:0];
  f.host.plugin = f.plugin;
  TestChange(f.host, MMPositionX, 5);
  assert([f.host drainCallbacks]);
  assert([f.host lane:MMScale].count == 3);
  MTDurationRecord a = record(f, MMScale, MMScaleDurationData, 0),
                   b = record(f, MMScale, MMScaleDurationData, 2);
  assert(a.time == 5 && a.linkID == first && a.duration == 0.25);
  assert(b.time == 9 && b.linkID == second && b.duration == 0.75);
  MTDurationRecord independent = record(f, MMScale, MMScaleDurationData, 1);
  assert(independent.time == 7 && independent.value == 200 &&
         !independent.linkID);
}
static void testDuplicatedEffectsStayIndependent(void) {
  Fixture *original = [Fixture new];
  TestAdd(original.host, MMPositionX, 0, 0);
  TestAdd(original.host, MMPositionX, 2, 100);
  TestLinkPose(original.host, MMPositionLink, 0, YES);
  TestLinkPose(original.host, MMPositionLink, 2, YES);
  duration(original, MMTransitionDuration, 2, 0.3);
  Fixture *copy = [Fixture new];
  for (NSNumber *p in @[ @(MMPositionX), @(MMScale) ]) {
    NSMutableArray *keys = [NSMutableArray array];
    for (NSDictionary *key in [original.host lane:p.unsignedIntValue])
      [keys addObject:[key mutableCopy]];
    copy.host.lanes[p] = keys;
  }
  // Round-trip through secure coding, as separate document instances would.
  for (NSNumber *p in @[ @(MMDurationData), @(MMScaleDurationData) ]) {
    NSError *error = nil;
    NSData *archive =
        [NSKeyedArchiver archivedDataWithRootObject:original.host.blobs[p]
                              requiringSecureCoding:YES
                                              error:&error];
    assert(archive && !error);
    copy.host.blobs[p] =
        [NSKeyedUnarchiver unarchivedObjectOfClass:KKDataBlob.class
                                          fromData:archive
                                             error:&error];
    assert(!error);
  }
  TestMove(copy.host, MMPositionX, 1, 3);
  duration(copy, MMTransitionDuration, 3, 0.7);
  assert(record(copy, MMScale, MMScaleDurationData, 1).time == 3 &&
         record(copy, MMScale, MMScaleDurationData, 1).duration == 0.7);
  assert(record(original, MMScale, MMScaleDurationData, 1).time == 2 &&
         record(original, MMScale, MMScaleDurationData, 1).duration == 0.3);
}
@interface TileBoundsDouble : NSObject
@property FxRect imagePixelBounds;
@end
@implementation TileBoundsDouble
@end
static void testRenderInputAndTileContracts(void) {
  Fixture *f = [Fixture new];
  TileBoundsDouble *tile = [TileBoundsDouble new];
  tile.imagePixelBounds =
      (FxRect){.left = -10, .right = 1920, .top = 1080, .bottom = -20};
  FxRect requested = {0};
  FxRect smallTile = {.left = 0, .right = 20, .top = 20, .bottom = 0};
  NSError *error = nil;
  assert([f.plugin sourceTileRect:&requested
                 sourceImageIndex:0
                     sourceImages:@[ (id)tile ]
              destinationTileRect:smallTile
                 destinationImage:(id)tile
                      pluginState:nil
                           atTime:TestTime(0)
                            error:&error]);
  assert(!error && requested.left == -10 && requested.right == 1920 &&
         requested.top == 1080 && requested.bottom == -20);
  assert(![f.plugin sourceTileRect:&requested
                  sourceImageIndex:1
                      sourceImages:@[ (id)tile ]
               destinationTileRect:(FxRect){0}
                  destinationImage:(id)tile
                       pluginState:nil
                            atTime:TestTime(0)
                             error:&error] &&
         error);
  error = nil;
  assert(![f.plugin renderDestinationImage:(id)tile
                              sourceImages:@[]
                               pluginState:[NSData data]
                                    atTime:TestTime(0)
                                     error:&error] &&
         error);
}
#define RUN(test)                                                              \
  do {                                                                         \
    @autoreleasepool {                                                         \
      printf("  %s ... ", #test);                                              \
      fflush(stdout);                                                          \
      test();                                                                  \
      puts("passed");                                                          \
    }                                                                          \
  } while (0)
int main(void) {
  RUN(testParameterContract);
  RUN(testStaticSingleAndIndependentClocks);
  RUN(testIncomingOwnershipAndAvailableTime);
  RUN(testInsertionClampsWithoutRewritingDuration);
  RUN(testContextualRowsAndBoundaryTimes);
  RUN(testSavedRecordsRoundTripAndLegacy);
  RUN(testCorruptDataAndUnavailableAPIs);
  RUN(testRestoredSnapshotsAndRenderGeneration);
  RUN(testLinkedCollisionPreservesPartner);
  RUN(testMultiSelectionMovesOnlyLinkedPartners);
  RUN(testDuplicatedEffectsStayIndependent);
  RUN(testRenderInputAndTileContracts);
  puts("MagicMove model: 12 test groups passed");
}
