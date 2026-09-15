/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */

#import "MockHost.h"
#import "MMCombinedPose.h"
#import "MMMatchEndpoints.h"
#import "MMNativeLinks.h"
#import "MMPoseTiming.h"
#import "MMPropertyLane.h"
#import "MMScalarPose.h"
#import "MMTimingEditorModel.h"

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
  if (result && parameter != MMHostRefreshToken)
    for (NSMutableDictionary *record in [self lane:parameter])
      if (fabs([record[@"time"] doubleValue] - CMTimeGetSeconds(time)) < 1e-6)
        record[@"value"] = value;
  return result;
}
@end

static id poseFor(UInt32 parameter, double value, MMPoseTiming *timing, MTEasing easing) {
  if (parameter == MMCustomControls)
    return [[[MMCombinedPose alloc] initWithPositionX:value positionY:value + 1
        scale:100 authored:YES easing:easing addedMotion:MTAddedMotionNone]
        poseByReplacingTiming:timing];
  return [[[MMScalarPose alloc] initWithValue:value authored:YES easing:easing
      addedMotion:MTAddedMotionNone] poseByReplacingTiming:timing];
}

static void installCaches(MatchHost *host) {
  MMCombinedPoseCache *combined = MMCreateCombinedPoseCache();
  MMPropertyPoseCache *opacity = [MMOpacityLane() createCache];
  host.staticValues[@(MMCombinedCacheToken)] = combined.token;
  host.staticValues[@(MMOpacityCacheToken)] = opacity.token;
}

static void addPose(MatchHost *host, UInt32 parameter, double time, double value,
                    MMPoseTiming *timing, MTEasing easing) {
  id pose = poseFor(parameter, value, timing ?: [MMPoseTiming new], easing);
  FxKeyframe key; FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
  key.time = TestTime(time);
  [[host lane:parameter] addObject:[@{
    @"time" : @(time), @"value" : pose,
    @"key" : [NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)]
  } mutableCopy]];
  host.blobs[@(parameter)] = pose;
}

static void refreshCaches(MatchHost *host) {
  MMRefreshCombinedPoseCache(host, TestTime(0));
  [MMOpacityLane() refreshCacheForManager:host time:TestTime(0)];
}

static MMPropertyPoseCache *opacityCache(MatchHost *host) {
  return [MMOpacityLane() cacheForManager:host];
}

static NSArray *entries(MatchHost *host, UInt32 parameter) {
  id cache = parameter == MMCustomControls ? (id)MMCombinedCacheForManager(host)
                                           : (id)opacityCache(host);
  return [cache snapshotEntries];
}

static id<MMPropertyPose> poseAt(MatchHost *host, NSUInteger index) {
  return entries(host, MMOpacityControls)[index][@"pose"];
}
static MMCombinedPose *positionAt(MatchHost *host, NSUInteger index) {
  return entries(host, MMCustomControls)[index][@"pose"];
}

// Duration 1 at the first key, 2 at the second, 3 at the third, so a paired
// transition is visible in the value itself.
static MMPoseTiming *timingWithDuration(double duration, BOOL available) {
  return [[MMPoseTiming alloc] initWithDuration:duration available:available amount:1 speed:1];
}

static MatchHost *fixture(NSUInteger keys) {
  MatchHost *host = [MatchHost new];
  installCaches(host);
  double times[] = {0, 1, 2};
  for (NSUInteger i = 0; i < keys; i++)
    addPose(host, MMOpacityControls, times[i], 10 * (i + 1),
            timingWithDuration(i + 1, i == 1), i == 1 ? MTEasingEaseIn : MTEasingLinear);
  refreshCaches(host);
  return host;
}

static void testTwoKeysMirrorValuesOnly(void) {
  MatchHost *host = fixture(2);
  assert(MMPropertyMatchAvailable(host, MMOpacityControls));
  assert(!MMPropertyMatchEnabled(host, MMOpacityControls));
  assert(MMSetPropertyMatch(host, MMOpacityControls, YES, NULL));
  assert(MMPropertyMatchEnabled(host, MMOpacityControls));
  assert([poseAt(host, 1) value] == 10);
  // One incoming transition cannot pair with itself.
  assert([poseAt(host, 1).timing duration] == 2);
  assert([host lane:MMOpacityControls].count == 2);
}

static void testThreeKeysPairTransitionAndLeaveInteriorAlone(void) {
  MatchHost *host = fixture(3);
  assert(MMSetPropertyMatch(host, MMOpacityControls, YES, NULL));
  id<MMPropertyPose> first = poseAt(host, 0), middle = poseAt(host, 1),
                     last = poseAt(host, 2);
  assert([last value] == [first value]);
  assert([last.timing duration] == [middle.timing duration]);
  assert([last.timing available] == [[middle timing] available]);
  assert([last easing] == [middle easing]);
  assert([middle value] == 20); // Interior values stay independent.
}

static void testSoleKeyGainsItsPartner(void) {
  MatchHost *host = fixture(1);
  assert(MMSetPropertyMatch(host, MMOpacityControls, YES, NULL));
  NSArray *after = entries(host, MMOpacityControls);
  assert(after.count == 2);
  // The Out lands on the effect's last frame, one frame before its end.
  assert(fabs([after.lastObject[@"time"] doubleValue] - (10 - 1.0 / 30.0)) < 1e-6);
  id<MMPropertyPose> created = after.lastObject[@"pose"];
  assert([created value] == 10);
  assert(!created.timing.linkID.length);

  MatchHost *atEnd = [MatchHost new];
  installCaches(atEnd);
  addPose(atEnd, MMOpacityControls, 10 - 1.0 / 30.0, 42, nil, MTEasingLinear);
  refreshCaches(atEnd);
  assert(MMSetPropertyMatch(atEnd, MMOpacityControls, YES, NULL));
  assert(fabs([entries(atEnd, MMOpacityControls).firstObject[@"time"] doubleValue]) < 1e-6);

  MatchHost *tight = [MatchHost new];
  installCaches(tight);
  tight.effectDuration = TestTime(1.0 / 30.0);
  addPose(tight, MMOpacityControls, 0, 5, nil, MTEasingLinear);
  refreshCaches(tight);
  NSError *error = nil;
  assert(!MMPropertyMatchAvailable(tight, MMOpacityControls));
  assert(!MMSetPropertyMatch(tight, MMOpacityControls, YES, &error) && error);
  assert(!MMPropertyMatchEnabled(tight, MMOpacityControls));
  assert(entries(tight, MMOpacityControls).count == 1);
}

static void testUnkeyedPropertyCannotMatch(void) {
  MatchHost *host = [MatchHost new];
  installCaches(host);
  refreshCaches(host);
  assert(!MMPropertyMatchAvailable(host, MMOpacityControls));
  assert(!MMSetPropertyMatch(host, MMOpacityControls, YES, NULL));
  assert(!MMPropertyMatchEnabled(host, MMOpacityControls));
}

static void testValueEditsMirrorBothWays(void) {
  MatchHost *host = fixture(3);
  assert(MMSetPropertyMatch(host, MMOpacityControls, YES, NULL));
  assert([MMOpacityLane() writeComponent:0 value:55 manager:host
                                   cache:opacityCache(host) time:TestTime(0) explicit:YES]);
  assert([poseAt(host, 0) value] == 55);
  assert([poseAt(host, 2) value] == 55);
  assert([poseAt(host, 1) value] == 20);
  assert([MMOpacityLane() writeComponent:0 value:77 manager:host
                                   cache:opacityCache(host) time:TestTime(2) explicit:YES]);
  assert([poseAt(host, 0) value] == 77);
  assert([poseAt(host, 2) value] == 77);

  assert(MMSetPropertyMatch(host, MMOpacityControls, NO, NULL));
  assert([MMOpacityLane() writeComponent:0 value:33 manager:host
                                   cache:opacityCache(host) time:TestTime(0) explicit:YES]);
  assert([poseAt(host, 0) value] == 33);
  assert([poseAt(host, 2) value] == 77);
}

static void testTransitionEditsPairWhileMotionStaysPut(void) {
  MatchHost *host = fixture(3);
  assert(MMSetPropertyMatch(host, MMOpacityControls, YES, NULL));
  assert(MMWriteInspectorSetting(host, MMOpacityControls, TestTime(1), MMInspectorDuration, 0.75));
  assert([poseAt(host, 1).timing duration] == 0.75);
  assert([poseAt(host, 2).timing duration] == 0.75);
  assert(MMWriteInspectorSetting(host, MMOpacityControls, TestTime(2), MMInspectorEasing, MTEasingEaseOut));
  assert([poseAt(host, 1) easing] == MTEasingEaseOut);
  assert([poseAt(host, 2) easing] == MTEasingEaseOut);
  // Added Motion belongs to the key before a gap, so it never pairs.
  assert(MMWriteInspectorSetting(host, MMOpacityControls, TestTime(0.5), MMInspectorMotion, MTAddedMotionWave));
  assert([poseAt(host, 0) addedMotion] == MTAddedMotionWave);
  assert([poseAt(host, 1) addedMotion] == MTAddedMotionNone);
  assert([poseAt(host, 2) addedMotion] == MTAddedMotionNone);
}

static void testLinkedPartnerFollowsWithoutInheritingMatch(void) {
  MatchHost *host = fixture(3);
  for (NSUInteger i = 0; i < 3; i++)
    addPose(host, MMCustomControls, i, 100 * (i + 1), timingWithDuration(5, NO), MTEasingSmooth);
  refreshCaches(host);
  host.currentTime = TestTime(0);
  assert(MMSetNativePropertyLink(host, MMOpacityControls, MMCustomControls, TestTime(2), YES));
  assert(MMSetPropertyMatch(host, MMOpacityControls, YES, NULL));
  assert(MMWriteInspectorSetting(host, MMOpacityControls, TestTime(1), MMInspectorDuration, 0.4));
  assert([poseAt(host, 2).timing duration] == 0.4);
  // Reached through the link from the matched endpoint, not by matching Position.
  assert([positionAt(host, 2).timing duration] == 0.4);
  assert(!MMPropertyMatchEnabled(host, MMCustomControls));
  assert([positionAt(host, 0).timing duration] == 5);
  assert([positionAt(host, 0) positionX] == 100);
  assert([positionAt(host, 2) positionX] == 300);
}

static void testStructureChangeRepairsOnCommit(void) {
  MatchHost *host = fixture(3);
  assert(MMSetPropertyMatch(host, MMOpacityControls, YES, NULL));
  MMObserveNativeLinks(host, MMOpacityControls, NO);
  // A new last key inherits nothing, so the pairing must be re-applied.
  addPose(host, MMOpacityControls, 3, 99, timingWithDuration(4, NO), MTEasingSmooth);
  refreshCaches(host);
  MMObserveNativeLinks(host, MMOpacityControls, NO);
  NSError *error = nil;
  assert(MMCommitNativeLinkMoves(host, NO, &error) && !error);
  id<MMPropertyPose> first = poseAt(host, 0), second = poseAt(host, 1),
                     last = poseAt(host, 3);
  assert([last value] == [first value]);
  assert([last.timing duration] == [second.timing duration]);
  assert([last easing] == [second easing]);
}

static void testDeletedEndpointLeavesTheSoleKeyAlone(void) {
  MatchHost *host = fixture(2);
  assert(MMSetPropertyMatch(host, MMOpacityControls, YES, NULL));
  MMObserveNativeLinks(host, MMOpacityControls, NO);
  [[host lane:MMOpacityControls] removeLastObject];
  refreshCaches(host);
  MMObserveNativeLinks(host, MMOpacityControls, NO);
  assert(MMCommitNativeLinkMoves(host, NO, NULL));
  assert(entries(host, MMOpacityControls).count == 1);
  assert(MMPropertyMatchEnabled(host, MMOpacityControls));
}

static void testMenuOffersTheToggle(void) {
  MatchHost *host = fixture(2);
  host.currentTime = TestTime(0);
  NSMenu *menu = MMNativePropertyMenu(host, [NSView new], MMOpacityControls);
  NSMenuItem *item = nil;
  for (NSMenuItem *candidate in menu.itemArray)
    if ([candidate.title isEqualToString:@"Match In/Out"]) item = candidate;
  assert(item && item.enabled && item.state == NSControlStateValueOff);
  assert(MMSetPropertyMatch(host, MMOpacityControls, YES, NULL));
  NSMenu *again = MMNativePropertyMenu(host, [NSView new], MMOpacityControls);
  for (NSMenuItem *candidate in again.itemArray)
    if ([candidate.title isEqualToString:@"Match In/Out"]) item = candidate;
  assert(item.state == NSControlStateValueOn);
}

int main(void) { @autoreleasepool {
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
