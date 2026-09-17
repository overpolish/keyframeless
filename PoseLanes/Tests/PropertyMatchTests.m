/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */

#import "TestLanes.h"

@interface MatchHost : MockHost <FxCustomParameterActionAPI_v4>
@property(nonatomic) CMTime currentTime;
@property(nonatomic) NSUInteger actionsStarted;
@property(nonatomic) NSUInteger actionsEnded;
@end

@implementation MatchHost
- (void)startAction:(id)sender { self.actionsStarted++; }
- (void)endAction:(id)sender { self.actionsEnded++; }
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding, NSCopying> **)value
                  fromParameter:(UInt32)parameter atTime:(CMTime)time {
  for (NSDictionary *record in [self lane:parameter])
    if (fabs([record[@"time"] doubleValue] - CMTimeGetSeconds(time)) < 1e-6) {
      *value = record[@"value"];
      return YES;
    }
  return [super getCustomParameterValue:value fromParameter:parameter atTime:time];
}
- (BOOL)setCustomParameterValue:(id)value toParameter:(UInt32)parameter atTime:(CMTime)time {
  BOOL result = [super setCustomParameterValue:value toParameter:parameter atTime:time];
  if (result && parameter != KFTestHostRefreshToken)
    for (NSMutableDictionary *record in [self lane:parameter])
      if (fabs([record[@"time"] doubleValue] - CMTimeGetSeconds(time)) < 1e-6)
        record[@"value"] = value;
  return result;
}
@end

static id poseFor(UInt32 parameter, double value, KFPoseTiming *timing, MTEasing easing) {
  KFPropertyLane *lane = KFPropertyLaneForParameter(parameter);
  NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:lane.componentCount];
  for (NSUInteger axis = 0; axis < lane.componentCount; axis++) [values addObject:@(value + axis)];
  return [lane.defaultPose poseByReplacingValues:values authored:YES easing:easing
                                     addedMotion:MTAddedMotionNone timing:timing];
}

static void installCaches(MatchHost *host) {
  KFPropertyPoseCache *position = [KFTestPositionLane() createCache];
  KFPropertyPoseCache *opacity = [KFTestOpacityLane() createCache];
  host.staticValues[@(KFTestPositionCacheToken)] = position.token;
  host.staticValues[@(KFTestOpacityCacheToken)] = opacity.token;
}

static void addPose(MatchHost *host, UInt32 parameter, double time, double value,
                    KFPoseTiming *timing, MTEasing easing) {
  id pose = poseFor(parameter, value, timing ?: [KFPoseTiming new], easing);
  FxKeyframe key; FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
  key.time = TestTime(time);
  [[host lane:parameter] addObject:[@{
    @"time" : @(time), @"value" : pose,
    @"key" : [NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)]
  } mutableCopy]];
  host.blobs[@(parameter)] = pose;
}

static void refreshCaches(MatchHost *host) {
  [KFTestPositionLane() refreshCacheForManager:host time:TestTime(0)];
  [KFTestOpacityLane() refreshCacheForManager:host time:TestTime(0)];
}

static KFPropertyPoseCache *opacityCache(MatchHost *host) {
  return [KFTestOpacityLane() cacheForManager:host];
}

static NSArray *entries(MatchHost *host, UInt32 parameter) {
  id cache = parameter == KFTestPosition ? (id)[KFTestPositionLane() cacheForManager:host]
                                           : (id)opacityCache(host);
  return [cache snapshotEntries];
}

static id<KFPropertyPose> poseAt(MatchHost *host, NSUInteger index) {
  return entries(host, KFTestOpacity)[index][@"pose"];
}
static id<KFPropertyPose> positionAt(MatchHost *host, NSUInteger index) {
  return entries(host, KFTestPosition)[index][@"pose"];
}

// Duration 1 at the first key, 2 at the second, 3 at the third, so a paired
// transition is visible in the value itself.
static KFPoseTiming *timingWithDuration(double duration, BOOL available) {
  return [[KFPoseTiming alloc] initWithDuration:duration available:available amount:1 speed:1];
}

static MatchHost *fixture(NSUInteger keys) {
  MatchHost *host = [MatchHost new];
  installCaches(host);
  double times[] = {0, 1, 2};
  for (NSUInteger i = 0; i < keys; i++)
    addPose(host, KFTestOpacity, times[i], 10 * (i + 1),
            timingWithDuration(i + 1, i == 1), i == 1 ? MTEasingEaseIn : MTEasingLinear);
  refreshCaches(host);
  return host;
}

static void testTwoKeysMirrorValuesOnly(void) {
  MatchHost *host = fixture(2);
  assert(KFPropertyMatchAvailable(host, KFTestOpacity));
  assert(!KFPropertyMatchEnabled(host, KFTestOpacity));
  assert(KFSetPropertyMatch(host, KFTestOpacity, YES, NULL));
  assert(KFPropertyMatchEnabled(host, KFTestOpacity));
  assert([poseAt(host, 1) value] == 10);
  // One incoming transition cannot pair with itself.
  assert([poseAt(host, 1).timing duration] == 2);
  assert([host lane:KFTestOpacity].count == 2);
}

static void testThreeKeysPairTransitionAndLeaveInteriorAlone(void) {
  MatchHost *host = fixture(3);
  assert(KFSetPropertyMatch(host, KFTestOpacity, YES, NULL));
  id<KFPropertyPose> first = poseAt(host, 0), middle = poseAt(host, 1),
                     last = poseAt(host, 2);
  assert([last value] == [first value]);
  assert([last.timing duration] == [middle.timing duration]);
  assert([last.timing available] == [[middle timing] available]);
  assert([last easing] == [middle easing]);
  assert([middle value] == 20); // Interior values stay independent.
}

static void testSoleKeyGainsItsPartner(void) {
  MatchHost *host = fixture(1);
  assert(KFSetPropertyMatch(host, KFTestOpacity, YES, NULL));
  NSArray *after = entries(host, KFTestOpacity);
  assert(after.count == 2);
  // The Out lands on the effect's last frame, one frame before its end.
  assert(fabs([after.lastObject[@"time"] doubleValue] - (10 - 1.0 / 30.0)) < 1e-6);
  id<KFPropertyPose> created = after.lastObject[@"pose"];
  assert([created value] == 10);
  assert(!created.timing.linkID.length);

  MatchHost *atEnd = [MatchHost new];
  installCaches(atEnd);
  addPose(atEnd, KFTestOpacity, 10 - 1.0 / 30.0, 42, nil, MTEasingLinear);
  refreshCaches(atEnd);
  assert(KFSetPropertyMatch(atEnd, KFTestOpacity, YES, NULL));
  assert(fabs([entries(atEnd, KFTestOpacity).firstObject[@"time"] doubleValue]) < 1e-6);

  MatchHost *tight = [MatchHost new];
  installCaches(tight);
  tight.effectDuration = TestTime(1.0 / 30.0);
  addPose(tight, KFTestOpacity, 0, 5, nil, MTEasingLinear);
  refreshCaches(tight);
  NSError *error = nil;
  assert(!KFPropertyMatchAvailable(tight, KFTestOpacity));
  assert(!KFSetPropertyMatch(tight, KFTestOpacity, YES, &error) && error);
  assert(!KFPropertyMatchEnabled(tight, KFTestOpacity));
  assert(entries(tight, KFTestOpacity).count == 1);
}

static void testUnkeyedPropertyCannotMatch(void) {
  MatchHost *host = [MatchHost new];
  installCaches(host);
  refreshCaches(host);
  assert(!KFPropertyMatchAvailable(host, KFTestOpacity));
  assert(!KFSetPropertyMatch(host, KFTestOpacity, YES, NULL));
  assert(!KFPropertyMatchEnabled(host, KFTestOpacity));
}

static void testValueEditsMirrorBothWays(void) {
  MatchHost *host = fixture(3);
  assert(KFSetPropertyMatch(host, KFTestOpacity, YES, NULL));
  assert([KFTestOpacityLane() writeComponent:0 value:55 manager:host
                                   cache:opacityCache(host) time:TestTime(0) explicit:YES]);
  assert([poseAt(host, 0) value] == 55);
  assert([poseAt(host, 2) value] == 55);
  assert([poseAt(host, 1) value] == 20);
  assert([KFTestOpacityLane() writeComponent:0 value:77 manager:host
                                   cache:opacityCache(host) time:TestTime(2) explicit:YES]);
  assert([poseAt(host, 0) value] == 77);
  assert([poseAt(host, 2) value] == 77);

  assert(KFSetPropertyMatch(host, KFTestOpacity, NO, NULL));
  assert([KFTestOpacityLane() writeComponent:0 value:33 manager:host
                                   cache:opacityCache(host) time:TestTime(0) explicit:YES]);
  assert([poseAt(host, 0) value] == 33);
  assert([poseAt(host, 2) value] == 77);
}

static void testTransitionEditsPairWhileMotionStaysPut(void) {
  MatchHost *host = fixture(3);
  assert(KFSetPropertyMatch(host, KFTestOpacity, YES, NULL));
  assert(KFWriteInspectorSetting(host, KFTestOpacity, TestTime(1), KFInspectorDuration, 0.75));
  assert([poseAt(host, 1).timing duration] == 0.75);
  assert([poseAt(host, 2).timing duration] == 0.75);
  assert(KFWriteInspectorSetting(host, KFTestOpacity, TestTime(2), KFInspectorEasing, MTEasingEaseOut));
  assert([poseAt(host, 1) easing] == MTEasingEaseOut);
  assert([poseAt(host, 2) easing] == MTEasingEaseOut);
  // Added Motion belongs to the key before a gap, so it never pairs.
  assert(KFWriteInspectorSetting(host, KFTestOpacity, TestTime(0.5), KFInspectorMotion, MTAddedMotionWave));
  assert([poseAt(host, 0) addedMotion] == MTAddedMotionWave);
  assert([poseAt(host, 1) addedMotion] == MTAddedMotionNone);
  assert([poseAt(host, 2) addedMotion] == MTAddedMotionNone);
}

static void testLinkedPartnerFollowsWithoutInheritingMatch(void) {
  MatchHost *host = fixture(3);
  for (NSUInteger i = 0; i < 3; i++)
    addPose(host, KFTestPosition, i, 100 * (i + 1), timingWithDuration(5, NO), MTEasingSmooth);
  refreshCaches(host);
  host.currentTime = TestTime(0);
  assert(KFSetNativePropertyLink(host, KFTestOpacity, KFTestPosition, TestTime(2), YES));
  assert(KFSetPropertyMatch(host, KFTestOpacity, YES, NULL));
  assert(KFWriteInspectorSetting(host, KFTestOpacity, TestTime(1), KFInspectorDuration, 0.4));
  assert([poseAt(host, 2).timing duration] == 0.4);
  // Reached through the link from the matched endpoint, not by matching Position.
  assert([positionAt(host, 2).timing duration] == 0.4);
  assert(!KFPropertyMatchEnabled(host, KFTestPosition));
  assert([positionAt(host, 0).timing duration] == 5);
  assert(positionAt(host, 0).values[0].doubleValue == 100);
  assert(positionAt(host, 2).values[0].doubleValue == 300);
}

static void testStructureChangeRepairsOnCommit(void) {
  MatchHost *host = fixture(3);
  assert(KFSetPropertyMatch(host, KFTestOpacity, YES, NULL));
  KFObserveNativeLinks(host, KFTestOpacity, NO);
  // A new last key inherits nothing, so the pairing must be re-applied.
  addPose(host, KFTestOpacity, 3, 99, timingWithDuration(4, NO), MTEasingSmooth);
  refreshCaches(host);
  KFObserveNativeLinks(host, KFTestOpacity, NO);
  NSError *error = nil;
  assert(KFCommitNativeLinkMoves(host, NO, &error) && !error);
  id<KFPropertyPose> first = poseAt(host, 0), second = poseAt(host, 1),
                     last = poseAt(host, 3);
  assert([last value] == [first value]);
  assert([last.timing duration] == [second.timing duration]);
  assert([last easing] == [second easing]);
}

static void testDeletedEndpointLeavesTheSoleKeyAlone(void) {
  MatchHost *host = fixture(2);
  assert(KFSetPropertyMatch(host, KFTestOpacity, YES, NULL));
  KFObserveNativeLinks(host, KFTestOpacity, NO);
  [[host lane:KFTestOpacity] removeLastObject];
  refreshCaches(host);
  KFObserveNativeLinks(host, KFTestOpacity, NO);
  assert(KFCommitNativeLinkMoves(host, NO, NULL));
  assert(entries(host, KFTestOpacity).count == 1);
  assert(KFPropertyMatchEnabled(host, KFTestOpacity));
}

static void testMenuOffersTheToggle(void) {
  MatchHost *host = fixture(2);
  host.currentTime = TestTime(0);
  NSMenu *menu = KFNativePropertyMenu(host, [NSView new], KFTestOpacity);
  NSMenuItem *item = nil;
  for (NSMenuItem *candidate in menu.itemArray)
    if ([candidate.title isEqualToString:@"Match In/Out"]) item = candidate;
  assert(item && item.enabled && item.state == NSControlStateValueOff);
  assert(KFSetPropertyMatch(host, KFTestOpacity, YES, NULL));
  NSMenu *again = KFNativePropertyMenu(host, [NSView new], KFTestOpacity);
  for (NSMenuItem *candidate in again.itemArray)
    if ([candidate.title isEqualToString:@"Match In/Out"]) item = candidate;
  assert(item.state == NSControlStateValueOn);
}

int main(void) { @autoreleasepool {
  KFTestRegisterLanes();
  testTwoKeysMirrorValuesOnly();
  testThreeKeysPairTransitionAndLeaveInteriorAlone();
  testSoleKeyGainsItsPartner();
  testUnkeyedPropertyCannotMatch();
  testValueEditsMirrorBothWays();
  testTransitionEditsPairWhileMotionStaysPut();
  testLinkedPartnerFollowsWithoutInheritingMatch();
  testStructureChangeRepairsOnCommit();
  testDeletedEndpointLeavesTheSoleKeyAlone();
  testMenuOffersTheToggle();
  puts("PropertyMatchTests passed");
} return 0; }
