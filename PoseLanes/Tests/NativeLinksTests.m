/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */

#import "TestLanes.h"

@class NativeHost;
static void addNativePose(NativeHost *host, UInt32 parameter, double time, double value, KFPoseTiming *timing);

@interface NativeHost : MockHost <FxCustomParameterActionAPI_v4>
@property(nonatomic) NSUInteger actionsStarted;
@property(nonatomic) NSUInteger actionsEnded;
@property(nonatomic) CMTime currentTime;
@property(nonatomic) NSUInteger refreshWrites;
@property(nonatomic,copy) BOOL (^historyCommand)(FxCommand);
@property(nonatomic) NSUInteger historyCommands;
@property(nonatomic) NSUInteger keyCountCalls;
@property(nonatomic) NSUInteger removeAllCalls;
@property(nonatomic) NSUInteger failLinkWriteAt;
@property(nonatomic) NSUInteger linkWriteCalls;
@property(nonatomic) UInt32 injectedParameter;
@end

@implementation NativeHost
- (NSError *)keyframeCount:(NSUInteger *)count forParameter:(NSUInteger)p andChannel:(NSUInteger)c {
  self.keyCountCalls++;
  return [super keyframeCount:count forParameter:p andChannel:c];
}
- (NSError *)removeAllKeyframesForParameter:(NSUInteger)p andChannel:(NSUInteger)c {
  self.removeAllCalls++;
  return [super removeAllKeyframesForParameter:p andChannel:c];
}
- (BOOL)performCommand:(FxCommand)command error:(NSError **)error {
  (void)error;
  assert(self.actionsStarted > self.actionsEnded && self.undoDepth==0);
  self.historyCommands++;
  return self.historyCommand ? self.historyCommand(command) : NO;
}
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
  if (self.failLinkWriteAt && [value respondsToSelector:@selector(timing)] && [value timing].linkID.length) {
    self.linkWriteCalls++;
    if (self.linkWriteCalls==self.failLinkWriteAt) {
      self.failLinkWriteAt=0;
      return NO;
    }
  }
  BOOL result = [super setCustomParameterValue:value toParameter:parameter atTime:time];
  if(result && parameter==KFTestHostRefreshToken) self.refreshWrites++;
  if (result && parameter != KFTestHostRefreshToken)
    for (NSMutableDictionary *record in [self lane:parameter])
      if (fabs([record[@"time"] doubleValue] - CMTimeGetSeconds(time)) < 1e-6)
        record[@"value"] = value;
  if (result && self.failLinkWriteAt && self.linkWriteCalls==1 && !self.injectedParameter) {
    self.injectedParameter=parameter;
    // Simulate an unrelated insertion not yet delivered to our cached snapshot.
    addNativePose(self,parameter,0.5,999,[KFPoseTiming new]);
    [[self lane:parameter] sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) { return [a[@"time"] compare:b[@"time"]]; }];
  }
  return result;
}
@end

static id poseForParameter(UInt32 parameter, double value, KFPoseTiming *timing) {
  KFPropertyLane *lane = KFPropertyLaneForParameter(parameter);
  NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:lane.componentCount];
  for (NSUInteger axis = 0; axis < lane.componentCount; axis++) [values addObject:@(value + axis)];
  return [lane.defaultPose poseByReplacingValues:values authored:YES easing:MTEasingLinear
                                     addedMotion:MTAddedMotionNone timing:timing];
}

static void installCaches(NativeHost *host) {
  KFPropertyPoseCache *position = [KFTestPositionLane() createCache];
  KFPropertyPoseCache *scale = [KFTestScaleLane() createCache];
  KFPropertyPoseCache *rotation = [KFTestRotationLane() createCache];
  KFPropertyPoseCache *opacity = [KFTestOpacityLane() createCache];
  host.staticValues[@(KFTestPositionCacheToken)] = position.token;
  host.staticValues[@(KFTestScaleCacheToken)] = scale.token;
  host.staticValues[@(KFTestRotationCacheToken)] = rotation.token;
  host.staticValues[@(KFTestOpacityCacheToken)] = opacity.token;
}

static void addNativePose(NativeHost *host, UInt32 parameter, double time, double value,
                          KFPoseTiming *timing) {
  id pose = poseForParameter(parameter, value, timing ?: [KFPoseTiming new]);
  FxKeyframe key; FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
  key.time = TestTime(time);
  [[host lane:parameter] addObject:[@{
      @"time":@(time), @"value":pose,
      @"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)]
  } mutableCopy]];
  host.blobs[@(parameter)] = pose;
}

static void refreshCaches(NativeHost *host) {
  CMTime now = TestTime(1);
  [KFTestPositionLane() refreshCacheForManager:host time:now];
  [KFTestScaleLane() refreshCacheForManager:host time:now];
  [KFTestRotationLane() refreshCacheForManager:host time:now];
  [KFTestOpacityLane() refreshCacheForManager:host time:now];
}

static NativeHost *fixture(void) {
  NativeHost *host = [NativeHost new];
  installCaches(host);
  KFPoseTiming *timing = [[KFPoseTiming alloc] initWithDuration:2 available:YES
      amount:3 speed:4];
  // Distinct per-property values, inside every lane's range, so a pose that
  // reaches the wrong property is visible.
  NSArray<NSNumber *> *properties=@[@(KFTestPosition), @(KFTestScale),
                                    @(KFTestRotation), @(KFTestOpacity)];
  for (NSUInteger index=0;index<properties.count;index++) {
    UInt32 parameter = properties[index].unsignedIntValue;
    addNativePose(host, parameter, 0, 10 * (index + 1), timing);
    addNativePose(host, parameter, 2, 10 * (index + 1) + 20, timing);
  }
  refreshCaches(host);
  return host;
}

static NSDictionary *entryAt(NativeHost *host, UInt32 parameter, double time) {
  id cache = nil;
  if (parameter == KFTestPosition) cache = [KFTestPositionLane() cacheForManager:host];
  else if (parameter == KFTestScale) cache = [KFTestScaleLane() cacheForManager:host];
  else cache = [((parameter == KFTestOpacity) ? KFTestOpacityLane() : KFTestRotationLane())
      cacheForManager:host];
  for (NSDictionary *entry in [cache snapshotEntries])
    if (fabs([entry[@"time"] doubleValue] - time) < 1e-6) return entry;
  return nil;
}

static NSMenuItem *menuItem(NSMenu *menu, NSString *title) {
  for (NSMenuItem *item in menu.itemArray)
    if ([item.title isEqualToString:title]) return item;
  return nil;
}

static void testPairTripleAndMenu(void) {
  NativeHost *host = fixture();
  assert(KFSetNativePropertyLink(host, KFTestPosition, KFTestScale,
                                 TestTime(0), YES));
  assert(KFNativePropertyLinked(host, KFTestPosition, TestTime(0)));
  assert(KFNativePropertyLinked(host, KFTestScale, TestTime(0)));
  host.currentTime = TestTime(0);
  NSMenu *menu = KFNativePropertyMenu(host, [NSView new], KFTestPosition);
  assert(menuItem(menu, @"Scale").state == NSControlStateValueOn);
  assert(menuItem(menu, @"Rotation").state == NSControlStateValueOff);
  assert(host.actionsStarted == 1 && host.actionsEnded == 1);

  assert(KFSetNativePropertyLink(host, KFTestPosition, KFTestRotation,
                                 TestTime(0), YES));
  assert(KFNativePropertyLinked(host, KFTestRotation, TestTime(0)));
  assert(KFSetNativePropertyLink(host, KFTestPosition, KFTestScale,
                                 TestTime(0), NO));
  assert(!KFNativePropertyLinked(host, KFTestScale, TestTime(0)));
  assert(KFNativePropertyLinked(host, KFTestPosition, TestTime(0)));
  assert(KFNativePropertyLinked(host, KFTestRotation, TestTime(0)));
  assert([host lane:KFTestPosition].count == 2 && [host lane:KFTestScale].count == 2);
}

static void testUnkeyedRowUsesChosenDestination(void) {
  NativeHost *host=fixture();
  [[host lane:KFTestScale] removeAllObjects];
  [[host lane:KFTestOpacity] removeAllObjects];
  refreshCaches(host);
  host.currentTime=TestTime(1);
  id<KFPropertyPose> constant=host.blobs[@(KFTestScale)];
  NSView *view=[NSView new];
  NSMenu *menu=KFNativePropertyMenu(host,view,KFTestScale);
  assert(menuItem(menu,@"Position").enabled);
  assert(menuItem(menu,@"Opacity").enabled); // Both unkeyed can start a pair.
  NSMenuItem *item=menuItem(menu,@"Position");
  NSUInteger groups=host.undoGroupsStarted;
  [NSApp sendAction:item.action to:item.target from:item];
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert([host lane:KFTestScale].count==1);
  assert(!entryAt(host,KFTestScale,1)); // Never creates at the playhead.
  id<KFPropertyPose> created=entryAt(host,KFTestScale,2)[@"pose"];
  assert(created && [created.values isEqualToArray:constant.values]);
  assert(KFNativePropertyLinked(host,KFTestScale,TestTime(1)));
  assert(KFNativePropertyLinked(host,KFTestPosition,TestTime(1)));
  assert(host.undoGroupsStarted==groups+1 && host.undoDepth==0);
  assert(host.actionsStarted==host.actionsEnded);

  NativeHost *empty=fixture();
  [[empty lane:KFTestScale] removeAllObjects];
  [[empty lane:KFTestPosition] removeAllObjects];
  refreshCaches(empty);
  id<KFPropertyPose> originalScale=empty.blobs[@(KFTestScale)];
  id<KFPropertyPose> originalPosition=empty.blobs[@(KFTestPosition)];
  empty.currentTime=TestTime(1);
  NSMenu *fresh=KFNativePropertyMenu(empty,view,KFTestScale);
  NSMenuItem *position=menuItem(fresh,@"Position");
  [fresh.delegate menuWillOpen:fresh];
  [(NSButton *)position.view performClick:nil];
  assert(empty.refreshWrites==0 && empty.undoGroupsStarted==0);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert([empty lane:KFTestScale].count==1 && [empty lane:KFTestPosition].count==1);
  assert(entryAt(empty,KFTestScale,1) && entryAt(empty,KFTestPosition,1));
  id<KFPropertyPose> newScale=entryAt(empty,KFTestScale,1)[@"pose"];
  id<KFPropertyPose> newPosition=entryAt(empty,KFTestPosition,1)[@"pose"];
  assert([newScale.values isEqualToArray:originalScale.values]);
  assert([newPosition.values isEqualToArray:originalPosition.values]);
  assert(position.state==NSControlStateValueOn);
  assert(empty.undoGroupsStarted==1 && empty.undoDepth==0);
  NSMenuItem *opacity=menuItem(fresh,@"Opacity");
  [(NSButton *)opacity.view performClick:nil];
  assert(empty.refreshWrites==1 && empty.undoGroupsStarted==1);
  assert(opacity.state==NSControlStateValueOff);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(position.state==NSControlStateValueOn && opacity.state==NSControlStateValueOn);
  [(NSButton *)position.view performClick:nil];
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(position.state==NSControlStateValueOff && opacity.state==NSControlStateValueOn);
  assert(empty.undoGroupsStarted==3 && empty.undoDepth==0);
  [fresh.delegate menuDidClose:fresh];
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(empty.refreshWrites==3);
}

static NSMutableDictionary *copyLanes(NSDictionary *lanes) {
  NSMutableDictionary *copy=[NSMutableDictionary new];
  for (NSNumber *p in lanes) {
    NSMutableArray *entries=[NSMutableArray new];
    for (NSDictionary *record in lanes[p]) [entries addObject:[record mutableCopy]];
    copy[p]=entries;
  }
  return copy;
}
static void testOpenMenuHistory(void) {
  NativeHost *host=fixture(); host.currentTime=TestTime(0);
  NSDictionary *before=copyLanes(host.lanes);
  NSView *view=[NSView new];
  NSMenu *menu=KFNativePropertyMenu(host,view,KFTestPosition);
  [menu.delegate menuWillOpen:menu];
  NSMenuItem *scale=menuItem(menu,@"Scale");
  [(NSButton *)scale.view performClick:nil];
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  NSDictionary *after=copyLanes(host.lanes);
  __weak NativeHost *weakHost=host;
  host.historyCommand=^BOOL(FxCommand command) {
    // Match the observed host: it reports NO, then applies history and sends
    // parameter callbacks after the command has already returned.
    dispatch_async(dispatch_get_main_queue(), ^{
      weakHost.lanes=copyLanes(command==kFxCommand_Undo ? before : after);
      refreshCaches(weakHost);
      KFPropertyMenuParametersChanged(weakHost);
    });
    return NO;
  };
  NSEvent *(^key)(NSEventModifierFlags)=^NSEvent *(NSEventModifierFlags flags) {
    return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:0 context:nil characters:@"z" charactersIgnoringModifiers:@"z" isARepeat:NO keyCode:6];
  };
  assert([menu performKeyEquivalent:key(NSEventModifierFlagCommand)]);
  assert(scale.state==NSControlStateValueOn); // No optimistic guessed state.
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(scale.state==NSControlStateValueOff);
  assert([menu performKeyEquivalent:key(NSEventModifierFlagCommand | NSEventModifierFlagShift)]);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(scale.state==NSControlStateValueOn);
  assert(host.historyCommands==2 && host.refreshWrites==1 && host.undoGroupsStarted==1);
  host.missingProtocols=[NSSet setWithObject:NSStringFromProtocol(@protocol(FxCommandAPI_v2))];
  assert(![menu performKeyEquivalent:key(NSEventModifierFlagCommand)]);
  assert(scale.state==NSControlStateValueOn && host.historyCommands==2);
  NSUInteger closedActions=host.actionsStarted;
  KFPropertyMenuParametersChanged(host); // Queued refresh must stop on close.
  [menu.delegate menuDidClose:menu];
  assert(![menu performKeyEquivalent:key(NSEventModifierFlagCommand)]);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(host.refreshWrites==1 && host.actionsStarted==host.actionsEnded);
  assert(host.actionsStarted==closedActions);
}

static void testQueuedLinkClicks(void) {
  NativeHost *host=fixture(); host.currentTime=TestTime(0);
  NSView *view=[NSView new];
  NSMenu *menu=KFNativePropertyMenu(host,view,KFTestPosition);
  [menu.delegate menuWillOpen:menu];
  NSMenuItem *scale=menuItem(menu,@"Scale");
  NSUInteger actions=host.actionsStarted, reads=host.nativeKeyReads;
  [(NSButton *)scale.view performClick:nil];
  [(NSButton *)scale.view performClick:nil];
  assert(host.actionsStarted==actions && host.nativeKeyReads==reads && host.refreshWrites==0);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(scale.state==NSControlStateValueOff); // Each queued click reads the latest state.
  assert(host.refreshWrites==2 && host.undoGroupsStarted==2 && host.undoDepth==0);
  [(NSButton *)scale.view performClick:nil];
  [menu.delegate menuDidClose:menu];
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(KFNativePropertyLinked(host,KFTestScale,TestTime(0)));
  assert(host.refreshWrites==3 && host.undoGroupsStarted==3);
  // A queued action must not outlive its inspector control.
  NSView *removed=[NSView new];
  NSMenu *orphan=KFNativePropertyMenu(host,removed,KFTestPosition);
  NSMenuItem *rotation=menuItem(orphan,@"Rotation");
  [(NSButton *)rotation.view performClick:nil];
  removed=nil;
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(host.refreshWrites==3 && host.undoGroupsStarted==3);
  assert(host.actionsStarted==host.actionsEnded);
}

static void testMenuCloseRefresh(void) {
  NativeHost *host=fixture(); host.currentTime=TestTime(0);
  NSView *view=[NSView new];
  NSMenu *menu=KFNativePropertyMenu(host,view,KFTestPosition);
  id<NSMenuDelegate> lifecycle=menu.delegate; assert(lifecycle);
  [lifecycle menuWillOpen:menu]; [lifecycle menuDidClose:menu];
  assert(host.refreshWrites==0);
  CFRunLoopRunInMode((__bridge CFStringRef)NSEventTrackingRunLoopMode,0.01,false);
  assert(host.refreshWrites==0);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(host.refreshWrites==1 && host.actionsStarted==host.actionsEnded);
  assert([host lane:KFTestPosition].count==2 && [host lane:KFTestScale].count==2);

  // didClose may precede action delivery. The action refresh must not be
  // followed by another scratch write (and another host undo entry).
  [lifecycle menuWillOpen:menu]; [lifecycle menuDidClose:menu];
  NSMenuItem *scale=menuItem(menu,@"Scale");
  [NSApp sendAction:scale.action to:scale.target from:scale];
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(host.refreshWrites==2 && host.undoGroupsStarted==1 && host.undoGroupsEnded==1);

  NSMenu *failed=KFNativePropertyMenu(host,view,KFTestPosition);
  [failed.delegate menuWillOpen:failed];
  host.failBlobOnce=KFTestRotation;
  NSMenuItem *rotation=menuItem(failed,@"Rotation");
  [NSApp sendAction:rotation.action to:rotation.target from:rotation];
  [failed.delegate menuDidClose:failed];
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(host.refreshWrites==3); // Failed menu operations still release repaint.
  assert(host.actionsStarted==host.actionsEnded && host.undoDepth==0);
}

static void testSamplingAndPersistence(void) {
  NativeHost *host = fixture();
  // The partner has no key at the requested time; linking creates one from its
  // displayed engine value while preserving the source key and its timing.
  addNativePose(host, KFTestPosition, 1, 10, [KFPoseTiming new]);
  refreshCaches(host);
  assert(KFSetNativePropertyLink(host, KFTestPosition, KFTestScale,
                                 TestTime(1), YES));
  NSDictionary *partner = entryAt(host, KFTestScale, 1);
  assert(partner && fabs([[partner[@"pose"] values][0] doubleValue] - 30) < 1e-6);
  NSString *link = [partner[@"pose"] timing].linkID;
  assert(link.length > 0);
  NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:partner[@"pose"]
                                         requiringSecureCoding:YES error:nil];
  id restored = [NSKeyedUnarchiver unarchivedObjectOfClass:KFPose.class
                                      fromData:archived error:nil];
  assert([restored isEqual:partner[@"pose"]] && [[restored timing].linkID isEqual:link]);
}

static void testLinkedTimingWritesAndInterpolation(void) {
  NativeHost *host = fixture();
  assert(KFSetNativePropertyLink(host, KFTestPosition, KFTestScale,
                                 TestTime(0), YES));
  assert(KFSetNativePropertyLink(host, KFTestPosition, KFTestScale,
                                 TestTime(2), YES));
  KFInspectorGap *gap = KFReadInspectorGap(host, KFTestPosition, TestTime(1));
  assert(gap && fabs(CMTimeGetSeconds(gap.destinationTime) - 2) < 1e-6);
  id<KFPropertyPose> interpolated = [KFTestScaleLane()
      sampleEntries:[KFTestScaleLane() cacheForManager:host].snapshotEntries time:TestTime(1)];
  assert(interpolated && interpolated.timing.linkID.length == 0);
  NSUInteger timingReads=host.nativeKeyReads;
  assert(KFWriteInspectorSetting(host, KFTestPosition, TestTime(1),
                                 KFInspectorDuration, 7));
  assert(host.nativeKeyReads==timingReads);
  assert([entryAt(host, KFTestPosition, 2)[@"pose"] timing].duration == 7);
  assert([entryAt(host, KFTestScale, 2)[@"pose"] timing].duration == 7);
  assert(KFWriteInspectorSetting(host, KFTestPosition, TestTime(1),
                                 KFInspectorAvailable, 0));
  assert(![entryAt(host, KFTestPosition, 2)[@"pose"] timing].available);
  assert(![entryAt(host, KFTestScale, 2)[@"pose"] timing].available);
  assert(KFWriteInspectorSetting(host, KFTestPosition, TestTime(1),
                                 KFInspectorEasing, MTEasingEaseIn));
  assert([entryAt(host, KFTestPosition, 2)[@"pose"] easing] == MTEasingEaseIn);
  assert([entryAt(host, KFTestScale, 2)[@"pose"] easing] == MTEasingEaseIn);
  assert(KFWriteInspectorSetting(host, KFTestPosition, TestTime(1),
                                 KFInspectorMotion, MTAddedMotionWave));
  assert([entryAt(host, KFTestPosition, 0)[@"pose"] addedMotion] == MTAddedMotionWave);
  assert([entryAt(host, KFTestScale, 0)[@"pose"] addedMotion] == MTAddedMotionWave);
  assert([entryAt(host, KFTestPosition, 2)[@"pose"] timing].linkID.length > 0);
  assert([entryAt(host, KFTestScale, 2)[@"pose"] timing].linkID.length > 0);
}

static void moveNativeKey(NativeHost *host, UInt32 parameter, NSUInteger index, double time) {
  NSMutableDictionary *record = [host lane:parameter][index];
  FxKeyframe key; [record[@"key"] getValue:&key]; key.time = TestTime(time);
  record[@"time"] = @(time);
  record[@"key"] = [NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)];
  [[host lane:parameter] sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                                  NSDictionary *b) {
    return [a[@"time"] compare:b[@"time"]];
  }];
}

static void moveNativeKeyFrom(NativeHost *host, UInt32 parameter, double from, double to) {
  for (NSMutableDictionary *record in [host lane:parameter])
    if (fabs([record[@"time"] doubleValue] - from) < 1e-6) {
      FxKeyframe key; [record[@"key"] getValue:&key]; key.time = TestTime(to);
      record[@"time"] = @(to);
      record[@"key"] = [NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)];
      break;
    }
  [[host lane:parameter] sortUsingComparator:^NSComparisonResult(NSDictionary *a,
                                                                  NSDictionary *b) {
    return [a[@"time"] compare:b[@"time"]];
  }];
}

static void testObservedMoveAndIndependentKeys(void) {
  NativeHost *host = fixture();
  assert(KFSetNativePropertyLink(host, KFTestPosition, KFTestScale,
                                 TestTime(0), YES));
  KFObserveNativeLinks(host, KFTestPosition, NO);
  assert(!KFHasPendingNativeLinkMoves(host));
  moveNativeKey(host, KFTestPosition, 0, 1);
  refreshCaches(host);
  KFObserveNativeLinks(host, KFTestPosition, YES);
  assert(KFHasPendingNativeLinkMoves(host));
  NSUInteger before = [host lane:KFTestScale].count;
  assert(KFCommitNativeLinkMoves(host, YES, nil));
  assert([host lane:KFTestScale].count == before &&
         fabs([entryAt(host, KFTestScale, 0)[@"time"] doubleValue]) < 1e-6);
  assert(KFCommitNativeLinkMoves(host, NO, nil));
  assert(!KFHasPendingNativeLinkMoves(host));
  assert(entryAt(host, KFTestScale, 1) != nil);
  assert(entryAt(host, KFTestScale, 0) == nil);
  moveNativeKey(host, KFTestPosition, 0, 0);
  refreshCaches(host);
  KFObserveNativeLinks(host, KFTestPosition, NO);
  assert(!KFHasPendingNativeLinkMoves(host));

  NativeHost *independent = fixture();
  KFObserveNativeLinks(independent, KFTestPosition, NO);
  moveNativeKey(independent, KFTestPosition, 0, 1);
  refreshCaches(independent);
  KFObserveNativeLinks(independent, KFTestPosition, NO);
  assert(!KFHasPendingNativeLinkMoves(independent));
}

static void testDuplicateCleanupAndMultiMove(void) {
  NativeHost *copyHost = fixture();
  assert(KFSetNativePropertyLink(copyHost, KFTestPosition, KFTestScale,
                                 TestTime(0), YES));
  NSDictionary *original = entryAt(copyHost, KFTestScale, 0);
  id copiedPose = original[@"pose"];
  FxKeyframe key; [original[@"nativeKey"] getValue:&key]; key.time = TestTime(3);
  [[copyHost lane:KFTestScale] addObject:[@{ @"time":@3, @"value":copiedPose,
      @"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)] } mutableCopy]];
  refreshCaches(copyHost);
  KFObserveNativeLinks(copyHost, KFTestScale, YES);
  assert(KFHasPendingNativeLinkMoves(copyHost));
  assert(KFCommitNativeLinkMoves(copyHost, NO, nil));
  assert([entryAt(copyHost, KFTestScale, 3)[@"pose"] timing].linkID.length == 0);
  assert([entryAt(copyHost, KFTestScale, 0)[@"pose"] timing].linkID.length > 0);

  NativeHost *multi = fixture();
  assert(KFSetNativePropertyLink(multi, KFTestPosition, KFTestScale,
                                 TestTime(0), YES));
  assert(KFSetNativePropertyLink(multi, KFTestPosition, KFTestScale,
                                 TestTime(2), YES));
  KFObserveNativeLinks(multi, KFTestPosition, NO);
  moveNativeKeyFrom(multi, KFTestPosition, 0, 2);
  moveNativeKeyFrom(multi, KFTestPosition, 2, 4);
  refreshCaches(multi);
  KFObserveNativeLinks(multi, KFTestPosition, YES);
  assert(KFCommitNativeLinkMoves(multi, NO, nil));
  assert(entryAt(multi, KFTestScale, 2) && entryAt(multi, KFTestScale, 4));
  assert(!entryAt(multi, KFTestScale, 0));
}

static void testLinkUsesCachedKeys(void) {
  NativeHost *host=fixture();
  NSUInteger counts=host.keyCountCalls, reads=host.nativeKeyReads;
  assert(KFSetNativePropertyLink(host,KFTestPosition,KFTestScale,TestTime(2),YES));
  assert(KFSetNativePropertyLink(host,KFTestPosition,KFTestScale,TestTime(2),NO));
  assert(host.keyCountCalls==counts && host.nativeKeyReads==reads);
  addNativePose(host,KFTestPosition,1,10,[KFPoseTiming new]); refreshCaches(host);
  counts=host.keyCountCalls; reads=host.nativeKeyReads;
  assert(KFSetNativePropertyLink(host,KFTestPosition,KFTestScale,TestTime(1),YES));
  assert(host.keyCountCalls==counts && host.nativeKeyReads==reads);
  // Structural moves retain the host preflight checks.
  KFObserveNativeLinks(host,KFTestPosition,NO);
  moveNativeKeyFrom(host,KFTestPosition,1,1.5); refreshCaches(host);
  KFObserveNativeLinks(host,KFTestPosition,YES);
  counts=host.keyCountCalls;
  assert(KFCommitNativeLinkMoves(host,NO,nil));
  assert(host.keyCountCalls>counts);
}
static void testLinkRollbackPreservesUnrelatedInsertion(void) {
  NativeHost *host=fixture();
  [[host lane:KFTestPosition] removeAllObjects];
  [[host lane:KFTestScale] removeAllObjects];
  refreshCaches(host);
  host.failLinkWriteAt=2;
  assert(!KFSetNativePropertyLink(host,KFTestPosition,KFTestScale,TestTime(1),YES));
  assert(host.injectedParameter!=0 && host.removeAllCalls==0);
  for (NSNumber *p in @[@(KFTestPosition),@(KFTestScale)]) {
    NSArray *keys=[host lane:p.unsignedIntValue];
    if (p.unsignedIntValue==host.injectedParameter) {
      assert(keys.count==1 && [keys[0][@"time"] doubleValue]==0.5);
      assert(entryAt(host,p.unsignedIntValue,0.5)); // Recovered cache includes it.
      assert(![keys[0][@"value"] timing].linkID.length);
    } else assert(keys.count==0);
    assert(!entryAt(host,p.unsignedIntValue,1));
  }
  assert(host.refreshWrites==0);
}

static void testLinkedGroupColors(void) {
  NativeHost *host=fixture();
  assert(!KFNativePropertyLinkColor(host,KFTestPosition,TestTime(2)));
  assert(KFSetNativePropertyLink(host,KFTestPosition,KFTestScale,TestTime(2),YES));
  NSColor *first=KFNativePropertyLinkColor(host,KFTestPosition,TestTime(2));
  assert(first && [first isEqual:KFNativePropertyLinkColor(host,KFTestScale,TestTime(2))]);
  assert(KFSetNativePropertyLink(host,KFTestRotation,KFTestOpacity,TestTime(2),YES));
  NSColor *second=KFNativePropertyLinkColor(host,KFTestRotation,TestTime(2));
  assert(second && ![first isEqual:second]);
  assert([second isEqual:KFNativePropertyLinkColor(host,KFTestOpacity,TestTime(2))]);
  NSUInteger reads=host.nativeKeyReads, counts=host.keyCountCalls;
  assert([first isEqual:KFNativePropertyLinkColor(host,KFTestPosition,TestTime(1))]);
  assert(host.nativeKeyReads==reads && host.keyCountCalls==counts);
  KFObserveNativeLinks(host,KFTestPosition,NO);
  moveNativeKeyFrom(host,KFTestPosition,2,3); refreshCaches(host);
  KFObserveNativeLinks(host,KFTestPosition,YES);
  assert(KFCommitNativeLinkMoves(host,NO,nil));
  assert([first isEqual:KFNativePropertyLinkColor(host,KFTestScale,TestTime(3))]);
  assert([second isEqual:KFNativePropertyLinkColor(host,KFTestOpacity,TestTime(2))]);
  NSDictionary *linked=copyLanes(host.lanes);
  assert(KFSetNativePropertyLink(host,KFTestPosition,KFTestScale,TestTime(3),NO));
  assert(!KFNativePropertyLinkColor(host,KFTestPosition,TestTime(3)));
  host.lanes=copyLanes(linked); refreshCaches(host);
  assert([first isEqual:KFNativePropertyLinkColor(host,KFTestPosition,TestTime(3))]);
}

static void testRollback(void) {
  NativeHost *failedAdd = fixture();
  addNativePose(failedAdd, KFTestPosition, 1, 10, [KFPoseTiming new]);
  refreshCaches(failedAdd);
  failedAdd.failAddOnce = KFTestScale;
  NSArray *beforeKeys = [[failedAdd lane:KFTestScale] copy];
  assert(!KFSetNativePropertyLink(failedAdd, KFTestPosition, KFTestScale,
                                  TestTime(1), YES));
  assert([[failedAdd lane:KFTestScale] isEqual:beforeKeys]);
  assert(!KFNativePropertyLinked(failedAdd, KFTestPosition, TestTime(1)));

  NativeHost *failedSet = fixture();
  assert(KFSetNativePropertyLink(failedSet, KFTestPosition, KFTestScale,
                                 TestTime(0), YES));
  id old = entryAt(failedSet, KFTestScale, 0)[@"pose"];
  failedSet.failBlobOnce = KFTestScale;
  id replacement = poseForParameter(KFTestPosition, 99, [KFPoseTiming new]);
  assert(!KFWriteNativeLinkedPose(failedSet, KFTestPosition, TestTime(0), replacement));
  assert([entryAt(failedSet, KFTestScale, 0)[@"pose"] isEqual:old]);
  assert([[entryAt(failedSet, KFTestPosition, 0)[@"pose"] values][0] doubleValue] != 99);
}

int main(void) {
  @autoreleasepool {
    KFTestRegisterLanes();
    [NSApplication sharedApplication];
    testPairTripleAndMenu();
    testSamplingAndPersistence();
    testOpenMenuHistory();
    testQueuedLinkClicks();
    testMenuCloseRefresh();
    testUnkeyedRowUsesChosenDestination();
    testLinkedTimingWritesAndInterpolation();
    testObservedMoveAndIndependentKeys();
    testDuplicateCleanupAndMultiMove();
    testLinkUsesCachedKeys();
    testLinkRollbackPreservesUnrelatedInsertion();
    testLinkedGroupColors();
    testRollback();
    puts("NativeLinksTests passed");
  }
  return 0;
}
