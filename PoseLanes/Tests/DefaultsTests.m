/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "TestLanes.h"
@import InspectorControls;
#import <assert.h>
@interface DefaultHost : MockHost <FxCustomParameterActionAPI_v4>
@property CMTime playhead;
@end
@implementation DefaultHost
- (void)startAction:(id)sender {
  (void)sender;
}
- (void)endAction:(id)sender {
  (void)sender;
}
- (CMTime)currentTime {
  return self.playhead;
}
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding, NSCopying> **)value
                  fromParameter:(UInt32)p
                         atTime:(CMTime)t {
  if (self.failReadParameter == p)
    return NO;
  for (NSDictionary *e in [self lane:p])
    if (fabs([e[@"time"] doubleValue] - CMTimeGetSeconds(t)) < 1e-6) {
      *value = e[@"value"];
      return YES;
    }
  return [super getCustomParameterValue:value fromParameter:p atTime:t];
}
- (BOOL)setCustomParameterValue:(id)value
                    toParameter:(UInt32)p
                         atTime:(CMTime)t {
  if (self.failBlobOnce == p)
    return [super setCustomParameterValue:value toParameter:p atTime:t];
  for (NSMutableDictionary *e in [self lane:p])
    if (fabs([e[@"time"] doubleValue] - CMTimeGetSeconds(t)) < 1e-6)
      e[@"value"] = value;
  return [super setCustomParameterValue:value toParameter:p atTime:t];
}
@end
@interface KFTimingEditor (DefaultTests)
- (void)appendDefaults:(NSMenu *)menu
               setting:(KFInspectorSetting)setting
                   gap:(KFInspectorGap *)gap;
- (void)defaultContextAction:(NSMenuItem *)item;
- (NSMenu *)motionContextMenu:(BOOL)controls;
@end
static NSDictionary *entry(double seconds, id pose) {
  CMTime t = TestTime(seconds);
  return @{
    @"time" : @(seconds),
    @"nativeTime" : [NSValue valueWithBytes:&t objCType:@encode(CMTime)],
    @"pose" : pose
  };
}
static void add(DefaultHost *host, double seconds, id pose) {
  FxKeyframe key;
  FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
  key.time = TestTime(seconds);
  [[host lane:KFTestPosition]
      addObject:[@{
        @"time" : @(seconds),
        @"value" : pose,
        @"key" : [NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)]
      } mutableCopy]];
  [[host lane:KFTestPosition] sortUsingComparator:^NSComparisonResult(
                                    NSDictionary *a, NSDictionary *b) {
    return [a[@"time"] compare:b[@"time"]];
  }];
}
static id<KFPropertyPose> pose(void) {
  return [KFTestPositionLane().defaultPose poseByReplacingValues:@[@5, @0] authored:YES
      easing:MTEasingSmooth addedMotion:MTAddedMotionNone timing:[KFPoseTiming new]];
}
static void restoreDefaults(void) {
  for (NSString *key in
       @[ @"duration", @"easing", @"motion.1", @"motion.2", @"motion.3" ])
    assert(KFRestoreFactoryDefault(key));
}
static void testPreferencesAndCreation(void) {
  NSMutableDictionary *values = [@{@"amount" : @2, @"speed" : @3} mutableCopy];
  KFPoseTiming *immutable =
      [[KFPoseTiming new] timingByReplacingMotionSettings:@{@"1" : values}];
  values[@"amount"] = @9;
  assert([immutable.motionSettings[@"1"][@"amount"] doubleValue] == 2);
  assert(![[KFPoseTiming new] timingByReplacingMotionSettings:@{
    @"1" : @{@"amount" : @1}
  }]);

  id<KFPropertyPose> original = pose();
  assert((KFSaveDefault(@"duration", @{@"value" : @2.5})));
  assert((KFSaveDefault(@"easing", @{@"value" : @(MTEasingLinear)})));
  assert(
      (original.timing.duration == 1.2 && original.easing == MTEasingSmooth));
  NSError *error = nil;
  NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:original
                                          requiringSecureCoding:YES
                                                          error:&error];
  KFPose *decoded =
      [NSKeyedUnarchiver unarchivedObjectOfClass:KFPose.class
                                        fromData:archive
                                           error:&error];
  assert((decoded && !error && [decoded isEqual:original]));
  id<KFPropertyPose> created = KFPoseWithCreationDefaults(original);
  assert((created.timing.duration == 2.5 && created.easing == MTEasingLinear &&
          created.values[0].doubleValue == 5));
  assert((!created.timing.available));
  assert((!KFIsNewKeyTime(@[ @{@"pose" : original} ], TestTime(1))));
  assert((!KFIsNewKeyTime(@[ entry(1, original) ], TestTime(1))));
  assert((KFIsNewKeyTime(@[ entry(1, original) ], TestTime(2))));
  KFDefaultKeyTracker *tracker = [KFDefaultKeyTracker new];
  NSDictionary *a = entry(1, original), *b = entry(3, original),
               *c = entry(2, original);
  assert(([tracker insertionsInEntries:@[ a, b ]].count == 0));
  assert(([tracker insertionsInEntries:@[ a, c, b ]].count == 1));
  assert(([tracker insertionsInEntries:@[ a, b ]].count == 0));
  assert(([tracker insertionsInEntries:@[ a, c, b ]].count ==
          0)); // Undo restores saved metadata.
  assert(([tracker insertionsInEntries:@[ entry(.5, original), c, b ]].count ==
          0));
  restoreDefaults();
}
static void testMotionHistoryAndMenus(void) {
  DefaultHost *host = [DefaultHost new];
  host.playhead = TestTime(1);
  add(host, 0, pose());
  add(host, 4, pose());
  host.blobs[@(KFTestPosition)] = pose();
  KFPropertyPoseCache *cache = [KFTestPositionLane() createCache];
  host.staticValues[@(KFTestPositionCacheToken)] = cache.token;
  [KFTestPositionLane() refreshCacheForManager:host time:host.playhead];
  assert((KFSaveDefault(@"motion.1", @{@"amount" : @1.8, @"speed" : @2.2})));
  assert((KFSaveDefault(@"motion.2", @{@"amount" : @.6, @"speed" : @3})));
  assert((KFWriteInspectorSetting(host, KFTestPosition, host.playhead,
                                  KFInspectorMotion, MTAddedMotionWave)));
  id<KFPropertyPose> wave = [host lane:KFTestPosition][0][@"value"];
  assert((wave.timing.amount == 1.8 && wave.timing.speed == 2.2));
  assert((KFWriteInspectorSetting(host, KFTestPosition, host.playhead,
                                  KFInspectorAmount, 2.4)));
  assert((KFWriteInspectorSetting(host, KFTestPosition, host.playhead,
                                  KFInspectorMotion, MTAddedMotionWiggle)));
  id<KFPropertyPose> wiggle = [host lane:KFTestPosition][0][@"value"];
  assert((wiggle.timing.amount == .6 && wiggle.timing.speed == 3));
  assert((KFSaveDefault(@"motion.1", @{@"amount" : @.2, @"speed" : @.5})));
  assert((KFWriteInspectorSetting(host, KFTestPosition, host.playhead,
                                  KFInspectorMotion, MTAddedMotionNone)));
  assert((KFWriteInspectorSetting(host, KFTestPosition, host.playhead,
                                  KFInspectorMotion, MTAddedMotionWave)));
  wave = [host lane:KFTestPosition][0][@"value"];
  assert((wave.timing.amount == 2.4 && wave.timing.speed == 2.2));
  NSError *error = nil;
  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:wave
                                       requiringSecureCoding:YES
                                                       error:&error];
  KFPose *decoded =
      [NSKeyedUnarchiver unarchivedObjectOfClass:KFPose.class
                                        fromData:data
                                           error:&error];
  assert((!error && [decoded isEqual:wave] &&
          decoded.timing.motionSettings.count == 2));
  assert(([[[decoded.timing timingByReplacingLinkID:@"group"]
               timingByReplacingMotionSeed:32
                                    linked:NO
                             componentMask:1]
               .motionSettings isEqual:wave.timing.motionSettings]));
  id<KFPropertyPose> beforeFailure = [host lane:KFTestPosition][0][@"value"];
  host.failBlobOnce = KFTestPosition;
  assert(!KFWriteInspectorSetting(host, KFTestPosition, host.playhead,
                                  KFInspectorMotion, MTAddedMotionWiggle));
  assert([[host lane:KFTestPosition][0][@"value"] isEqual:beforeFailure]);
  KFTestEffect *plugin = [[KFTestEffect alloc] initWithAPIManager:host];
  KFTimingEditor *editor = [[KFTimingEditor alloc] initWithEffect:plugin];
  KFInspectorGap *gap =
      KFReadInspectorGap(host, KFTestPosition, host.playhead);
  NSUInteger writes = host.hostWrites;
  for (NSNumber *setting in @[
         @(KFInspectorDuration), @(KFInspectorEasing), @(KFInspectorAmount)
       ]) {
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    [editor appendDefaults:menu setting:setting.integerValue gap:gap];
    NSMenuItem *save = [menu itemWithTitle:@"Set Default"];
    NSMenuItem *factory = [menu itemWithTitle:@"Restore Factory Default"];
    assert(save && factory);
    if (setting.integerValue != KFInspectorAmount)
      assert([menu itemWithTitle:@"Reset Parameter"]);
    [editor defaultContextAction:save];
    if (setting.integerValue == KFInspectorAmount)
      assert(([KFReadDefault(@"motion.1")[@"amount"] doubleValue] == 2.4));
    [editor defaultContextAction:factory];
  }
  assert((
      host.hostWrites ==
      writes)); // Preferences do not change this animation or its undo history.
  restoreDefaults();
}
static void testNativeCreation(void) {
  DefaultHost *host = [DefaultHost new];
  id<KFPropertyPose> original = pose();
  add(host, 0, original);
  add(host, 4, original);
  host.blobs[@(KFTestPosition)] = original;
  KFPropertyPoseCache *cache = [KFTestPositionLane() createCache];
  host.staticValues[@(KFTestPositionCacheToken)] = cache.token;
  [KFTestPositionLane() refreshCacheForManager:host time:TestTime(1)];
  KFObserveNativeLinks(host, KFTestPosition, NO);
  assert(KFSaveDefault(@"duration", @{@"value" : @2.5}));
  assert(KFSaveDefault(@"easing", @{@"value" : @(MTEasingEaseOut)}));
  add(host, 2, original);
  [KFTestPositionLane() refreshCacheForManager:host time:TestTime(2)];
  KFObserveNativeLinks(host, KFTestPosition, YES);
  assert(KFHasPendingNativeLinkMoves(host));
  NSError *error = nil;
  NSUInteger reads = host.nativeKeyReads;
  assert(KFCommitNativeLinkMoves(host, YES, &error));
  assert([[[host lane:KFTestPosition][1][@"value"] timing] duration] == 1.2);
  assert(KFCommitNativeLinkMoves(host, NO, &error));
  assert(host.nativeKeyReads == reads);
  id<KFPropertyPose> created = [host lane:KFTestPosition][1][@"value"];
  assert(created.timing.duration == 2.5 && created.easing == MTEasingEaseOut);
  assert([[host lane:KFTestPosition][0][@"value"] isEqual:original]);
  assert([[host lane:KFTestPosition][2][@"value"] isEqual:original]);
  // Undo the metadata edit, then remove and restore the native key.
  [host lane:KFTestPosition][1][@"value"] = original;
  [KFTestPositionLane() refreshCacheForManager:host time:TestTime(2)];
  KFObserveNativeLinks(host, KFTestPosition, NO);
  [[host lane:KFTestPosition] removeObjectAtIndex:1];
  [KFTestPositionLane() refreshCacheForManager:host time:TestTime(2)];
  KFObserveNativeLinks(host, KFTestPosition, NO);
  assert(KFSaveDefault(@"duration", @{@"value" : @5}));
  add(host, 2, original);
  [KFTestPositionLane() refreshCacheForManager:host time:TestTime(2)];
  KFObserveNativeLinks(host, KFTestPosition, NO);
  assert(!KFHasPendingNativeLinkMoves(host));
  assert([[[host lane:KFTestPosition][1][@"value"] timing] duration] == 1.2);
  // A queued insertion cannot overwrite a subsequent edit to the same key.
  add(host, 3, original);
  [KFTestPositionLane() refreshCacheForManager:host time:TestTime(3)];
  KFObserveNativeLinks(host, KFTestPosition, YES);
  KFPoseTiming *manual = [[KFPoseTiming alloc] initWithDuration:7
                                                      available:NO
                                                         amount:1
                                                          speed:1];
  [host lane:KFTestPosition][2][@"value"] =
      [original poseByReplacingValues:original.values authored:original.authored easing:original.easing addedMotion:original.addedMotion timing:manual];
  [KFTestPositionLane() refreshCacheForManager:host time:TestTime(3)];
  KFObserveNativeLinks(host, KFTestPosition, NO);
  assert(KFCommitNativeLinkMoves(host, NO, &error));
  assert([[[host lane:KFTestPosition][2][@"value"] timing] duration] == 7);
  restoreDefaults();
}
static void performReset(NSMenu *menu, DefaultHost *host) {
  if ([menu isKindOfClass:ICContextMenu.class]) {
    assert(!menu.allowsContextMenuPlugIns);
    if (@available(macOS 15.2,*)) assert(!menu.automaticallyInsertsWritingToolsItems);
  }
  NSMenuItem *item = [menu itemWithTitle:@"Reset Parameter"];
  assert(item && item.enabled);
  NSUInteger writes = host.hostWrites, groups = host.undoGroupsStarted;
  assert([NSApp sendAction:item.action to:item.target from:item]);
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1];
  while (host.hostWrites == writes && deadline.timeIntervalSinceNow > 0)
    [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode
                        beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
  assert(host.hostWrites > writes && host.undoGroupsStarted == groups + 1 &&
         host.undoDepth == 0);
}
static void testResetMenus(void) {
  DefaultHost *host = [DefaultHost new];
  host.playhead = TestTime(1);
  KFPoseTiming *timing = [[KFPoseTiming alloc] initWithDuration:8
                                                      available:YES
                                                         amount:.4
                                                          speed:.5];
  id<KFPropertyPose> original = [KFTestPositionLane().defaultPose poseByReplacingValues:@[@20, @0]
      authored:YES easing:MTEasingEaseIn addedMotion:MTAddedMotionWave timing:timing];
  add(host, 0, original);
  add(host, 4, original);
  host.blobs[@(KFTestPosition)] = original;
  KFPropertyPoseCache *cache = [KFTestPositionLane() createCache];
  host.staticValues[@(KFTestPositionCacheToken)] = cache.token;
  [KFTestPositionLane() refreshCacheForManager:host time:host.playhead];
  KFTestEffect *plugin = [[KFTestEffect alloc] initWithAPIManager:host];
  KFTimingEditor *editor = [[KFTimingEditor alloc] initWithEffect:plugin];
  NSWindow *window =
      [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300)
                                  styleMask:NSWindowStyleMaskBorderless
                                    backing:NSBackingStoreBuffered
                                      defer:NO];
  window.releasedWhenClosed = NO;
  [window.contentView addSubview:editor];
  [editor setValue:@(KFTestPosition) forKey:@"displayedParameter"];
  assert(KFSaveDefault(@"duration", @{@"value" : @2.5}));
  assert(KFSaveDefault(@"easing", @{@"value" : @(MTEasingLinear)}));
  assert((KFSaveDefault(@"motion.1", @{@"amount" : @1.8, @"speed" : @2.2})));
  for (NSNumber *setting in @[ @(KFInspectorDuration), @(KFInspectorEasing) ]) {
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    [editor appendDefaults:menu
                   setting:setting.integerValue
                       gap:KFReadInspectorGap(host, KFTestPosition,
                                              host.playhead)];
    performReset(menu, host);
  }
  id<KFPropertyPose> destination = [host lane:KFTestPosition][1][@"value"];
  assert(destination.timing.duration == 2.5 && destination.timing.available &&
         destination.easing == MTEasingLinear);
  assert(destination.values[0].doubleValue == 20 && destination.timing.amount == .4);
  performReset([editor motionContextMenu:YES], host);
  id<KFPropertyPose> source = [host lane:KFTestPosition][0][@"value"];
  assert(source.timing.amount == 1.8 && source.timing.speed == 2.2 &&
         source.addedMotion == MTAddedMotionWave);
  assert(source.timing.duration == 8 && source.timing.available);
  restoreDefaults();
  performReset([editor motionContextMenu:YES], host);
  source = [host lane:KFTestPosition][0][@"value"];
  assert(source.timing.amount == 1 && source.timing.speed == 1);
  NSMenu *menu = [NSMenu new];
  menu.autoenablesItems = NO;
  [editor
      appendDefaults:menu
             setting:KFInspectorDuration
                 gap:KFReadInspectorGap(host, KFTestPosition, host.playhead)];
  performReset(menu, host);
  destination = [host lane:KFTestPosition][1][@"value"];
  assert(destination.timing.duration == 1.2 && destination.timing.available);
  [window close];
}
int main(void) {
  @autoreleasepool {
    KFTestRegisterLanes();
    [NSApplication sharedApplication];
    restoreDefaults();
    testPreferencesAndCreation();
    testMotionHistoryAndMenus();
    testNativeCreation();
    testResetMenus();
    puts("Creation defaults: preferences on new keys, tracked insertions, motion history and reset menus passed");
  }
  return 0;
}
