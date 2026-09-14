/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Constants.h"
#import "MMDefaults.h"
#import "MMNativeLinks.h"
#import "MMTimingEditor.h"
#import "MMTimingEditorModel.h"
#import "MockHost.h"
#import "Plugin.h"
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
@interface MMTimingEditor (DefaultTests)
- (void)appendDefaults:(NSMenu *)menu
               setting:(MMInspectorSetting)setting
                   gap:(MMInspectorGap *)gap;
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
  [[host lane:MMCustomControls]
      addObject:[@{
        @"time" : @(seconds),
        @"value" : pose,
        @"key" : [NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)]
      } mutableCopy]];
  [[host lane:MMCustomControls] sortUsingComparator:^NSComparisonResult(
                                    NSDictionary *a, NSDictionary *b) {
    return [a[@"time"] compare:b[@"time"]];
  }];
}
static MMCombinedPose *pose(void) {
  return [[MMCombinedPose alloc] initWithPositionX:5 scale:100 authored:YES];
}
static void restoreDefaults(void) {
  for (NSString *key in
       @[ @"duration", @"easing", @"motion.1", @"motion.2", @"motion.3" ])
    [MMDefaultStore() restoreFactoryForKey:key];
}
static void testPreferencesAndCreation(void) {
  NSMutableDictionary *values = [@{@"amount" : @2, @"speed" : @3} mutableCopy];
  MMPoseTiming *immutable =
      [[MMPoseTiming new] timingByReplacingMotionSettings:@{@"1" : values}];
  values[@"amount"] = @9;
  assert([immutable.motionSettings[@"1"][@"amount"] doubleValue] == 2);
  assert(![[MMPoseTiming new] timingByReplacingMotionSettings:@{
    @"1" : @{@"amount" : @1}
  }]);

  MMCombinedPose *original = pose();
  assert((MMSaveDefault(@"duration", @{@"value" : @2.5})));
  assert((MMSaveDefault(@"easing", @{@"value" : @(MTEasingLinear)})));
  assert((!MMSaveDefault(@"duration", @{@"value" : @(-1)})));
  assert((!MMSaveDefault(@"duration", @{@"value" : @2, @"available" : @YES})));
  assert((!MMSaveDefault(@"easing", @{@"value" : @1.5})));
  assert((!MMSaveDefault(@"motion.1", @{@"amount" : @1, @"speed" : @0})));
  assert(
      (original.timing.duration == 1.2 && original.easing == MTEasingSmooth));
  NSError *error = nil;
  NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:original
                                          requiringSecureCoding:YES
                                                          error:&error];
  MMCombinedPose *decoded =
      [NSKeyedUnarchiver unarchivedObjectOfClass:MMCombinedPose.class
                                        fromData:archive
                                           error:&error];
  assert((decoded && !error && [decoded isEqual:original]));
  MMCombinedPose *created = MMPoseWithCreationDefaults(original);
  assert((created.timing.duration == 2.5 && created.easing == MTEasingLinear &&
          created.positionX == 5));
  assert((!created.timing.available));
  assert((!MMIsNewKeyTime(@[ @{@"pose" : original} ], TestTime(1))));
  assert((!MMIsNewKeyTime(@[ entry(1, original) ], TestTime(1))));
  assert((MMIsNewKeyTime(@[ entry(1, original) ], TestTime(2))));
  MMDefaultKeyTracker *tracker = [MMDefaultKeyTracker new];
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
  host.blobs[@(MMCustomControls)] = pose();
  MMCombinedPoseCache *cache = MMCreateCombinedPoseCache();
  host.staticValues[@(MMCombinedCacheToken)] = cache.token;
  MMRefreshCombinedPoseCache(host, host.playhead);
  assert((MMSaveDefault(@"motion.1", @{@"amount" : @1.8, @"speed" : @2.2})));
  assert((MMSaveDefault(@"motion.2", @{@"amount" : @.6, @"speed" : @3})));
  assert((MMWriteInspectorSetting(host, MMCustomControls, host.playhead,
                                  MMInspectorMotion, MTAddedMotionWave)));
  MMCombinedPose *wave = [host lane:MMCustomControls][0][@"value"];
  assert((wave.timing.amount == 1.8 && wave.timing.speed == 2.2));
  assert((MMWriteInspectorSetting(host, MMCustomControls, host.playhead,
                                  MMInspectorAmount, 2.4)));
  assert((MMWriteInspectorSetting(host, MMCustomControls, host.playhead,
                                  MMInspectorMotion, MTAddedMotionWiggle)));
  MMCombinedPose *wiggle = [host lane:MMCustomControls][0][@"value"];
  assert((wiggle.timing.amount == .6 && wiggle.timing.speed == 3));
  assert((MMSaveDefault(@"motion.1", @{@"amount" : @.2, @"speed" : @.5})));
  assert((MMWriteInspectorSetting(host, MMCustomControls, host.playhead,
                                  MMInspectorMotion, MTAddedMotionNone)));
  assert((MMWriteInspectorSetting(host, MMCustomControls, host.playhead,
                                  MMInspectorMotion, MTAddedMotionWave)));
  wave = [host lane:MMCustomControls][0][@"value"];
  assert((wave.timing.amount == 2.4 && wave.timing.speed == 2.2));
  NSError *error = nil;
  NSData *data = [NSKeyedArchiver archivedDataWithRootObject:wave
                                       requiringSecureCoding:YES
                                                       error:&error];
  MMCombinedPose *decoded =
      [NSKeyedUnarchiver unarchivedObjectOfClass:MMCombinedPose.class
                                        fromData:data
                                           error:&error];
  assert((!error && [decoded isEqual:wave] &&
          decoded.timing.motionSettings.count == 2));
  assert(([[[decoded.timing timingByReplacingLinkID:@"group"]
               timingByReplacingMotionSeed:32
                                    linked:NO
                             componentMask:1]
               .motionSettings isEqual:wave.timing.motionSettings]));
  MMCombinedPose *beforeFailure = [host lane:MMCustomControls][0][@"value"];
  host.failBlobOnce = MMCustomControls;
  assert(!MMWriteInspectorSetting(host, MMCustomControls, host.playhead,
                                  MMInspectorMotion, MTAddedMotionWiggle));
  assert([[host lane:MMCustomControls][0][@"value"] isEqual:beforeFailure]);
  MagicMovePlugin *plugin = [[MagicMovePlugin alloc] initWithAPIManager:host];
  MMTimingEditor *editor = [[MMTimingEditor alloc] initWithPlugin:plugin];
  MMInspectorGap *gap =
      MMReadInspectorGap(host, MMCustomControls, host.playhead);
  NSUInteger writes = host.hostWrites;
  for (NSNumber *setting in @[
         @(MMInspectorDuration), @(MMInspectorEasing), @(MMInspectorAmount)
       ]) {
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    [editor appendDefaults:menu setting:setting.integerValue gap:gap];
    NSMenuItem *save = [menu itemWithTitle:@"Set Default"];
    NSMenuItem *factory = [menu itemWithTitle:@"Restore Factory Default"];
    assert(save && factory);
    if (setting.integerValue != MMInspectorAmount)
      assert([menu itemWithTitle:@"Reset Parameter"]);
    [editor defaultContextAction:save];
    if (setting.integerValue == MMInspectorAmount)
      assert(([MMReadDefault(@"motion.1")[@"amount"] doubleValue] == 2.4));
    [editor defaultContextAction:factory];
  }
  assert((
      host.hostWrites ==
      writes)); // Preferences do not change this animation or its undo history.
  restoreDefaults();
}
static void testNativeCreation(void) {
  DefaultHost *host = [DefaultHost new];
  MMCombinedPose *original = pose();
  add(host, 0, original);
  add(host, 4, original);
  host.blobs[@(MMCustomControls)] = original;
  MMCombinedPoseCache *cache = MMCreateCombinedPoseCache();
  host.staticValues[@(MMCombinedCacheToken)] = cache.token;
  MMRefreshCombinedPoseCache(host, TestTime(1));
  MMObserveNativeLinks(host, MMCustomControls, NO);
  assert(MMSaveDefault(@"duration", @{@"value" : @2.5}));
  assert(MMSaveDefault(@"easing", @{@"value" : @(MTEasingEaseOut)}));
  add(host, 2, original);
  MMRefreshCombinedPoseCache(host, TestTime(2));
  MMObserveNativeLinks(host, MMCustomControls, YES);
  assert(MMHasPendingNativeLinkMoves(host));
  NSError *error = nil;
  NSUInteger reads = host.nativeKeyReads;
  assert(MMCommitNativeLinkMoves(host, YES, &error));
  assert([[[host lane:MMCustomControls][1][@"value"] timing] duration] == 1.2);
  assert(MMCommitNativeLinkMoves(host, NO, &error));
  assert(host.nativeKeyReads == reads);
  MMCombinedPose *created = [host lane:MMCustomControls][1][@"value"];
  assert(created.timing.duration == 2.5 && created.easing == MTEasingEaseOut);
  assert([[host lane:MMCustomControls][0][@"value"] isEqual:original]);
  assert([[host lane:MMCustomControls][2][@"value"] isEqual:original]);
  // Undo the metadata edit, then remove and restore the native key.
  [host lane:MMCustomControls][1][@"value"] = original;
  MMRefreshCombinedPoseCache(host, TestTime(2));
  MMObserveNativeLinks(host, MMCustomControls, NO);
  [[host lane:MMCustomControls] removeObjectAtIndex:1];
  MMRefreshCombinedPoseCache(host, TestTime(2));
  MMObserveNativeLinks(host, MMCustomControls, NO);
  assert(MMSaveDefault(@"duration", @{@"value" : @5}));
  add(host, 2, original);
  MMRefreshCombinedPoseCache(host, TestTime(2));
  MMObserveNativeLinks(host, MMCustomControls, NO);
  assert(!MMHasPendingNativeLinkMoves(host));
  assert([[[host lane:MMCustomControls][1][@"value"] timing] duration] == 1.2);
  // A queued insertion cannot overwrite a subsequent edit to the same key.
  add(host, 3, original);
  MMRefreshCombinedPoseCache(host, TestTime(3));
  MMObserveNativeLinks(host, MMCustomControls, YES);
  MMPoseTiming *manual = [[MMPoseTiming alloc] initWithDuration:7
                                                      available:NO
                                                         amount:1
                                                          speed:1];
  [host lane:MMCustomControls][2][@"value"] =
      [original poseByReplacingTiming:manual];
  MMRefreshCombinedPoseCache(host, TestTime(3));
  MMObserveNativeLinks(host, MMCustomControls, NO);
  assert(MMCommitNativeLinkMoves(host, NO, &error));
  assert([[[host lane:MMCustomControls][2][@"value"] timing] duration] == 7);
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
  MMPoseTiming *timing = [[MMPoseTiming alloc] initWithDuration:8
                                                      available:YES
                                                         amount:.4
                                                          speed:.5];
  MMCombinedPose *original = [[[MMCombinedPose alloc]
      initWithPositionX:20
                  scale:100
               authored:YES
                 easing:MTEasingEaseIn
            addedMotion:MTAddedMotionWave] poseByReplacingTiming:timing];
  add(host, 0, original);
  add(host, 4, original);
  host.blobs[@(MMCustomControls)] = original;
  MMCombinedPoseCache *cache = MMCreateCombinedPoseCache();
  host.staticValues[@(MMCombinedCacheToken)] = cache.token;
  MMRefreshCombinedPoseCache(host, host.playhead);
  MagicMovePlugin *plugin = [[MagicMovePlugin alloc] initWithAPIManager:host];
  MMTimingEditor *editor = [[MMTimingEditor alloc] initWithPlugin:plugin];
  NSWindow *window =
      [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 300)
                                  styleMask:NSWindowStyleMaskBorderless
                                    backing:NSBackingStoreBuffered
                                      defer:NO];
  window.releasedWhenClosed = NO;
  [window.contentView addSubview:editor];
  [editor setValue:@(MMCustomControls) forKey:@"displayedParameter"];
  assert(MMSaveDefault(@"duration", @{@"value" : @2.5}));
  assert(MMSaveDefault(@"easing", @{@"value" : @(MTEasingLinear)}));
  assert((MMSaveDefault(@"motion.1", @{@"amount" : @1.8, @"speed" : @2.2})));
  for (NSNumber *setting in @[ @(MMInspectorDuration), @(MMInspectorEasing) ]) {
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    [editor appendDefaults:menu
                   setting:setting.integerValue
                       gap:MMReadInspectorGap(host, MMCustomControls,
                                              host.playhead)];
    performReset(menu, host);
  }
  MMCombinedPose *destination = [host lane:MMCustomControls][1][@"value"];
  assert(destination.timing.duration == 2.5 && destination.timing.available &&
         destination.easing == MTEasingLinear);
  assert(destination.positionX == 20 && destination.timing.amount == .4);
  performReset([editor motionContextMenu:YES], host);
  MMCombinedPose *source = [host lane:MMCustomControls][0][@"value"];
  assert(source.timing.amount == 1.8 && source.timing.speed == 2.2 &&
         source.addedMotion == MTAddedMotionWave);
  assert(source.timing.duration == 8 && source.timing.available);
  restoreDefaults();
  performReset([editor motionContextMenu:YES], host);
  source = [host lane:MMCustomControls][0][@"value"];
  assert(source.timing.amount == 1 && source.timing.speed == 1);
  NSMenu *menu = [NSMenu new];
  menu.autoenablesItems = NO;
  [editor
      appendDefaults:menu
             setting:MMInspectorDuration
                 gap:MMReadInspectorGap(host, MMCustomControls, host.playhead)];
  performReset(menu, host);
  destination = [host lane:MMCustomControls][1][@"value"];
  assert(destination.timing.duration == 1.2 && destination.timing.available);
  [window close];
}
int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    restoreDefaults();
    testPreferencesAndCreation();
    testMotionHistoryAndMenus();
    testNativeCreation();
    testResetMenus();
    puts("DefaultsTests passed");
  }
  return 0;
}
