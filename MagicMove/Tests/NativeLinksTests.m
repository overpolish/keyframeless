/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */

#import "MockHost.h"
#import "MMNativeLinks.h"
#import "MMResetParameter.h"
#import "MMCombinedPose.h"
#import "MMScalePose.h"
#import "MMScalarPose.h"
#import "MMRotationPose.h"
#import "MMPropertyLane.h"
#import "MMPoseTiming.h"
#import "MMTimingEditorModel.h"

@class NativeHost;
static void addNativePose(NativeHost *host, UInt32 parameter, double time, double value, MMPoseTiming *timing);

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
  if(result && parameter==MMHostRefreshToken) self.refreshWrites++;
  if (result && parameter != MMHostRefreshToken)
    for (NSMutableDictionary *record in [self lane:parameter])
      if (fabs([record[@"time"] doubleValue] - CMTimeGetSeconds(time)) < 1e-6)
        record[@"value"] = value;
  if (result && self.failLinkWriteAt && self.linkWriteCalls==1 && !self.injectedParameter) {
    self.injectedParameter=parameter;
    // Simulate an unrelated insertion not yet delivered to our cached snapshot.
    addNativePose(self,parameter,0.5,999,[MMPoseTiming new]);
    [[self lane:parameter] sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) { return [a[@"time"] compare:b[@"time"]]; }];
  }
  return result;
}
@end

static id poseForParameter(UInt32 parameter, double value, MMPoseTiming *timing) {
  switch (parameter) {
    case MMCustomControls:
      return [[[MMCombinedPose alloc] initWithPositionX:value
          positionY:value + 1 scale:value + 100 authored:YES easing:MTEasingLinear
          addedMotion:MTAddedMotionNone] poseByReplacingTiming:timing];
    case MMScaleControls:
      return [[[MMScalePose alloc] initWithX:value y:value + 1 authored:YES
          easing:MTEasingLinear addedMotion:MTAddedMotionNone]
          poseByReplacingTiming:timing];
    case MMRotationControls:
      return [[[MMRotationPose alloc] initWithX:value y:value + 1 z:value + 2
          authored:YES easing:MTEasingLinear addedMotion:MTAddedMotionNone]
          poseByReplacingTiming:timing];
    default:
      return [[[MMScalarPose alloc] initWithValue:value authored:YES
          easing:MTEasingLinear addedMotion:MTAddedMotionNone]
          poseByReplacingTiming:timing];
  }
}

static void installCaches(NativeHost *host) {
  MMCombinedPoseCache *combined = MMCreateCombinedPoseCache();
  MMScalePoseCache *scale = MMCreateScalePoseCache();
  MMPropertyPoseCache *rotation = [MMRotationLane() createCache];
  MMPropertyPoseCache *opacity = [MMOpacityLane() createCache];
  host.staticValues[@(MMCombinedCacheToken)] = combined.token;
  host.staticValues[@(MMScaleCacheToken)] = scale.token;
  host.staticValues[@(MMRotationCacheToken)] = rotation.token;
  host.staticValues[@(MMOpacityCacheToken)] = opacity.token;
}

static void addNativePose(NativeHost *host, UInt32 parameter, double time, double value,
                          MMPoseTiming *timing) {
  id pose = poseForParameter(parameter, value, timing ?: [MMPoseTiming new]);
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
  MMRefreshCombinedPoseCache(host, now);
  MMRefreshScalePoseCache(host, now);
  [MMRotationLane() refreshCacheForManager:host time:now];
  [MMOpacityLane() refreshCacheForManager:host time:now];
}

static NativeHost *fixture(void) {
  NativeHost *host = [NativeHost new];
  installCaches(host);
  MMPoseTiming *timing = [[MMPoseTiming alloc] initWithDuration:2 available:YES
      amount:3 speed:4];
  for (NSNumber *number in @[@(MMCustomControls), @(MMScaleControls),
                             @(MMRotationControls), @(MMOpacityControls)]) {
    UInt32 parameter = number.unsignedIntValue;
    addNativePose(host, parameter, 0, parameter / 10.0, timing);
    addNativePose(host, parameter, 2, parameter / 10.0 + 20, timing);
  }
  refreshCaches(host);
  return host;
}

static NSDictionary *entryAt(NativeHost *host, UInt32 parameter, double time) {
  id cache = nil;
  if (parameter == MMCustomControls) cache = MMCombinedCacheForManager(host);
  else if (parameter == MMScaleControls) cache = MMScaleCacheForManager(host);
  else cache = [((parameter == MMOpacityControls) ? MMOpacityLane() : MMRotationLane())
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
  assert(MMSetNativePropertyLink(host, MMCustomControls, MMScaleControls,
                                 TestTime(0), YES));
  assert(MMNativePropertyLinked(host, MMCustomControls, TestTime(0)));
  assert(MMNativePropertyLinked(host, MMScaleControls, TestTime(0)));
  host.currentTime = TestTime(0);
  NSMenu *menu = MMNativePropertyMenu(host, [NSView new], MMCustomControls);
  assert(menuItem(menu, @"Scale").state == NSControlStateValueOn);
  assert(menuItem(menu, @"Rotation").state == NSControlStateValueOff);
  assert(host.actionsStarted == 1 && host.actionsEnded == 1);

  assert(MMSetNativePropertyLink(host, MMCustomControls, MMRotationControls,
                                 TestTime(0), YES));
  assert(MMNativePropertyLinked(host, MMRotationControls, TestTime(0)));
  assert(MMSetNativePropertyLink(host, MMCustomControls, MMScaleControls,
                                 TestTime(0), NO));
  assert(!MMNativePropertyLinked(host, MMScaleControls, TestTime(0)));
  assert(MMNativePropertyLinked(host, MMCustomControls, TestTime(0)));
  assert(MMNativePropertyLinked(host, MMRotationControls, TestTime(0)));
  assert([host lane:MMCustomControls].count == 2 && [host lane:MMScaleControls].count == 2);
}

static void testUnkeyedRowUsesChosenDestination(void) {
  NativeHost *host=fixture();
  [[host lane:MMScaleControls] removeAllObjects];
  [[host lane:MMOpacityControls] removeAllObjects];
  refreshCaches(host);
  host.currentTime=TestTime(1);
  MMScalePose *constant=host.blobs[@(MMScaleControls)];
  NSView *view=[NSView new];
  NSMenu *menu=MMNativePropertyMenu(host,view,MMScaleControls);
  assert(menuItem(menu,@"Position").enabled);
  assert(menuItem(menu,@"Opacity").enabled); // Both unkeyed can start a pair.
  NSMenuItem *item=menuItem(menu,@"Position");
  NSUInteger groups=host.undoGroupsStarted;
  [NSApp sendAction:item.action to:item.target from:item];
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert([host lane:MMScaleControls].count==1);
  assert(!entryAt(host,MMScaleControls,1)); // Never creates at the playhead.
  MMScalePose *created=entryAt(host,MMScaleControls,2)[@"pose"];
  assert(created && created.x==constant.x && created.y==constant.y);
  assert(MMNativePropertyLinked(host,MMScaleControls,TestTime(1)));
  assert(MMNativePropertyLinked(host,MMCustomControls,TestTime(1)));
  assert(host.undoGroupsStarted==groups+1 && host.undoDepth==0);
  assert(host.actionsStarted==host.actionsEnded);

  NativeHost *empty=fixture();
  [[empty lane:MMScaleControls] removeAllObjects];
  [[empty lane:MMCustomControls] removeAllObjects];
  refreshCaches(empty);
  MMScalePose *originalScale=empty.blobs[@(MMScaleControls)];
  MMCombinedPose *originalPosition=empty.blobs[@(MMCustomControls)];
  empty.currentTime=TestTime(1);
  NSMenu *fresh=MMNativePropertyMenu(empty,view,MMScaleControls);
  NSMenuItem *position=menuItem(fresh,@"Position");
  [fresh.delegate menuWillOpen:fresh];
  [(NSButton *)position.view performClick:nil];
  assert(empty.refreshWrites==0 && empty.undoGroupsStarted==0);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert([empty lane:MMScaleControls].count==1 && [empty lane:MMCustomControls].count==1);
  assert(entryAt(empty,MMScaleControls,1) && entryAt(empty,MMCustomControls,1));
  MMScalePose *newScale=entryAt(empty,MMScaleControls,1)[@"pose"];
  MMCombinedPose *newPosition=entryAt(empty,MMCustomControls,1)[@"pose"];
  assert(newScale.x==originalScale.x && newScale.y==originalScale.y);
  assert(newPosition.positionX==originalPosition.positionX && newPosition.positionY==originalPosition.positionY);
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
  NSMenu *menu=MMNativePropertyMenu(host,view,MMCustomControls);
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
      MMPropertyMenuParametersChanged(weakHost);
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
  MMPropertyMenuParametersChanged(host); // Queued refresh must stop on close.
  [menu.delegate menuDidClose:menu];
  assert(![menu performKeyEquivalent:key(NSEventModifierFlagCommand)]);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(host.refreshWrites==1 && host.actionsStarted==host.actionsEnded);
  assert(host.actionsStarted==closedActions);
}

static void testQueuedLinkClicks(void) {
  NativeHost *host=fixture(); host.currentTime=TestTime(0);
  NSView *view=[NSView new];
  NSMenu *menu=MMNativePropertyMenu(host,view,MMCustomControls);
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
  assert(MMNativePropertyLinked(host,MMScaleControls,TestTime(0)));
  assert(host.refreshWrites==3 && host.undoGroupsStarted==3);
  // A queued action must not outlive its inspector control.
  NSView *removed=[NSView new];
  NSMenu *orphan=MMNativePropertyMenu(host,removed,MMCustomControls);
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
  NSMenu *menu=MMNativePropertyMenu(host,view,MMCustomControls);
  id<NSMenuDelegate> lifecycle=menu.delegate; assert(lifecycle);
  [lifecycle menuWillOpen:menu]; [lifecycle menuDidClose:menu];
  assert(host.refreshWrites==0);
  CFRunLoopRunInMode((__bridge CFStringRef)NSEventTrackingRunLoopMode,0.01,false);
  assert(host.refreshWrites==0);
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(host.refreshWrites==1 && host.actionsStarted==host.actionsEnded);
  assert([host lane:MMCustomControls].count==2 && [host lane:MMScaleControls].count==2);

  // didClose may precede action delivery. The action refresh must not be
  // followed by another scratch write (and another host undo entry).
  [lifecycle menuWillOpen:menu]; [lifecycle menuDidClose:menu];
  NSMenuItem *scale=menuItem(menu,@"Scale");
  [NSApp sendAction:scale.action to:scale.target from:scale];
  CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
  assert(host.refreshWrites==2 && host.undoGroupsStarted==1 && host.undoGroupsEnded==1);

  NSMenu *failed=MMNativePropertyMenu(host,view,MMCustomControls);
  [failed.delegate menuWillOpen:failed];
  host.failBlobOnce=MMRotationControls;
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
  addNativePose(host, MMCustomControls, 1, 10, [MMPoseTiming new]);
  refreshCaches(host);
  assert(MMSetNativePropertyLink(host, MMCustomControls, MMScaleControls,
                                 TestTime(1), YES));
  NSDictionary *partner = entryAt(host, MMScaleControls, 1);
  assert(partner && fabs([(MMScalePose *)partner[@"pose"] x] - 190) < 1e-6);
  NSString *link = [partner[@"pose"] timing].linkID;
  assert(link.length > 0);
  NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:partner[@"pose"]
                                         requiringSecureCoding:YES error:nil];
  id restored = [NSKeyedUnarchiver unarchivedObjectOfClass:MMScalePose.class
                                      fromData:archived error:nil];
  assert([restored isEqual:partner[@"pose"]] && [[restored timing].linkID isEqual:link]);
}

static void testLinkedTimingWritesAndInterpolation(void) {
  NativeHost *host = fixture();
  assert(MMSetNativePropertyLink(host, MMCustomControls, MMScaleControls,
                                 TestTime(0), YES));
  assert(MMSetNativePropertyLink(host, MMCustomControls, MMScaleControls,
                                 TestTime(2), YES));
  MMInspectorGap *gap = MMReadInspectorGap(host, MMCustomControls, TestTime(1));
  assert(gap && fabs(CMTimeGetSeconds(gap.destinationTime) - 2) < 1e-6);
  MMScalePose *interpolated = MMSampleScaleSnapshot(
      MMScaleCacheForManager(host).snapshotEntries, TestTime(1));
  assert(interpolated && interpolated.timing.linkID.length == 0);
  NSUInteger timingReads=host.nativeKeyReads;
  assert(MMWriteInspectorSetting(host, MMCustomControls, TestTime(1),
                                 MMInspectorDuration, 7));
  assert(host.nativeKeyReads==timingReads);
  assert([entryAt(host, MMCustomControls, 2)[@"pose"] timing].duration == 7);
  assert([entryAt(host, MMScaleControls, 2)[@"pose"] timing].duration == 7);
  assert(MMWriteInspectorSetting(host, MMCustomControls, TestTime(1),
                                 MMInspectorAvailable, 0));
  assert(![entryAt(host, MMCustomControls, 2)[@"pose"] timing].available);
  assert(![entryAt(host, MMScaleControls, 2)[@"pose"] timing].available);
  assert(MMWriteInspectorSetting(host, MMCustomControls, TestTime(1),
                                 MMInspectorEasing, MTEasingEaseIn));
  assert([entryAt(host, MMCustomControls, 2)[@"pose"] easing] == MTEasingEaseIn);
  assert([entryAt(host, MMScaleControls, 2)[@"pose"] easing] == MTEasingEaseIn);
  assert(MMWriteInspectorSetting(host, MMCustomControls, TestTime(1),
                                 MMInspectorMotion, MTAddedMotionWave));
  assert([entryAt(host, MMCustomControls, 0)[@"pose"] addedMotion] == MTAddedMotionWave);
  assert([entryAt(host, MMScaleControls, 0)[@"pose"] addedMotion] == MTAddedMotionWave);
  assert([entryAt(host, MMCustomControls, 2)[@"pose"] timing].linkID.length > 0);
  assert([entryAt(host, MMScaleControls, 2)[@"pose"] timing].linkID.length > 0);
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
  assert(MMSetNativePropertyLink(host, MMCustomControls, MMScaleControls,
                                 TestTime(0), YES));
  MMObserveNativeLinks(host, MMCustomControls, NO);
  assert(!MMHasPendingNativeLinkMoves(host));
  moveNativeKey(host, MMCustomControls, 0, 1);
  refreshCaches(host);
  MMObserveNativeLinks(host, MMCustomControls, YES);
  assert(MMHasPendingNativeLinkMoves(host));
  NSUInteger before = [host lane:MMScaleControls].count;
  assert(MMCommitNativeLinkMoves(host, YES, nil));
  assert([host lane:MMScaleControls].count == before &&
         fabs([entryAt(host, MMScaleControls, 0)[@"time"] doubleValue]) < 1e-6);
  assert(MMCommitNativeLinkMoves(host, NO, nil));
  assert(!MMHasPendingNativeLinkMoves(host));
  assert(entryAt(host, MMScaleControls, 1) != nil);
  assert(entryAt(host, MMScaleControls, 0) == nil);
  moveNativeKey(host, MMCustomControls, 0, 0);
  refreshCaches(host);
  MMObserveNativeLinks(host, MMCustomControls, NO);
  assert(!MMHasPendingNativeLinkMoves(host));

  NativeHost *independent = fixture();
  MMObserveNativeLinks(independent, MMCustomControls, NO);
  moveNativeKey(independent, MMCustomControls, 0, 1);
  refreshCaches(independent);
  MMObserveNativeLinks(independent, MMCustomControls, NO);
  assert(!MMHasPendingNativeLinkMoves(independent));
}

static void testDuplicateCleanupAndMultiMove(void) {
  NativeHost *copyHost = fixture();
  assert(MMSetNativePropertyLink(copyHost, MMCustomControls, MMScaleControls,
                                 TestTime(0), YES));
  NSDictionary *original = entryAt(copyHost, MMScaleControls, 0);
  id copiedPose = original[@"pose"];
  FxKeyframe key; [original[@"nativeKey"] getValue:&key]; key.time = TestTime(3);
  [[copyHost lane:MMScaleControls] addObject:[@{ @"time":@3, @"value":copiedPose,
      @"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)] } mutableCopy]];
  refreshCaches(copyHost);
  MMObserveNativeLinks(copyHost, MMScaleControls, YES);
  assert(MMHasPendingNativeLinkMoves(copyHost));
  assert(MMCommitNativeLinkMoves(copyHost, NO, nil));
  assert([entryAt(copyHost, MMScaleControls, 3)[@"pose"] timing].linkID.length == 0);
  assert([entryAt(copyHost, MMScaleControls, 0)[@"pose"] timing].linkID.length > 0);

  NativeHost *multi = fixture();
  assert(MMSetNativePropertyLink(multi, MMCustomControls, MMScaleControls,
                                 TestTime(0), YES));
  assert(MMSetNativePropertyLink(multi, MMCustomControls, MMScaleControls,
                                 TestTime(2), YES));
  MMObserveNativeLinks(multi, MMCustomControls, NO);
  moveNativeKeyFrom(multi, MMCustomControls, 0, 2);
  moveNativeKeyFrom(multi, MMCustomControls, 2, 4);
  refreshCaches(multi);
  MMObserveNativeLinks(multi, MMCustomControls, YES);
  assert(MMCommitNativeLinkMoves(multi, NO, nil));
  assert(entryAt(multi, MMScaleControls, 2) && entryAt(multi, MMScaleControls, 4));
  assert(!entryAt(multi, MMScaleControls, 0));
}

static void testLinkUsesCachedKeys(void) {
  NativeHost *host=fixture();
  NSUInteger counts=host.keyCountCalls, reads=host.nativeKeyReads;
  assert(MMSetNativePropertyLink(host,MMCustomControls,MMScaleControls,TestTime(2),YES));
  assert(MMSetNativePropertyLink(host,MMCustomControls,MMScaleControls,TestTime(2),NO));
  assert(host.keyCountCalls==counts && host.nativeKeyReads==reads);
  addNativePose(host,MMCustomControls,1,10,[MMPoseTiming new]); refreshCaches(host);
  counts=host.keyCountCalls; reads=host.nativeKeyReads;
  assert(MMSetNativePropertyLink(host,MMCustomControls,MMScaleControls,TestTime(1),YES));
  assert(host.keyCountCalls==counts && host.nativeKeyReads==reads);
  // Structural moves retain the host preflight checks.
  MMObserveNativeLinks(host,MMCustomControls,NO);
  moveNativeKeyFrom(host,MMCustomControls,1,1.5); refreshCaches(host);
  MMObserveNativeLinks(host,MMCustomControls,YES);
  counts=host.keyCountCalls;
  assert(MMCommitNativeLinkMoves(host,NO,nil));
  assert(host.keyCountCalls>counts);
}
static void testLinkRollbackPreservesUnrelatedInsertion(void) {
  NativeHost *host=fixture();
  [[host lane:MMCustomControls] removeAllObjects];
  [[host lane:MMScaleControls] removeAllObjects];
  refreshCaches(host);
  host.failLinkWriteAt=2;
  assert(!MMSetNativePropertyLink(host,MMCustomControls,MMScaleControls,TestTime(1),YES));
  assert(host.injectedParameter!=0 && host.removeAllCalls==0);
  for (NSNumber *p in @[@(MMCustomControls),@(MMScaleControls)]) {
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
  assert(!MMNativePropertyLinkColor(host,MMCustomControls,TestTime(2)));
  assert(MMSetNativePropertyLink(host,MMCustomControls,MMScaleControls,TestTime(2),YES));
  NSColor *first=MMNativePropertyLinkColor(host,MMCustomControls,TestTime(2));
  assert(first && [first isEqual:MMNativePropertyLinkColor(host,MMScaleControls,TestTime(2))]);
  assert(MMSetNativePropertyLink(host,MMRotationControls,MMOpacityControls,TestTime(2),YES));
  NSColor *second=MMNativePropertyLinkColor(host,MMRotationControls,TestTime(2));
  assert(second && ![first isEqual:second]);
  assert([second isEqual:MMNativePropertyLinkColor(host,MMOpacityControls,TestTime(2))]);
  NSUInteger reads=host.nativeKeyReads, counts=host.keyCountCalls;
  assert([first isEqual:MMNativePropertyLinkColor(host,MMCustomControls,TestTime(1))]);
  assert(host.nativeKeyReads==reads && host.keyCountCalls==counts);
  MMObserveNativeLinks(host,MMCustomControls,NO);
  moveNativeKeyFrom(host,MMCustomControls,2,3); refreshCaches(host);
  MMObserveNativeLinks(host,MMCustomControls,YES);
  assert(MMCommitNativeLinkMoves(host,NO,nil));
  assert([first isEqual:MMNativePropertyLinkColor(host,MMScaleControls,TestTime(3))]);
  assert([second isEqual:MMNativePropertyLinkColor(host,MMOpacityControls,TestTime(2))]);
  NSDictionary *linked=copyLanes(host.lanes);
  assert(MMSetNativePropertyLink(host,MMCustomControls,MMScaleControls,TestTime(3),NO));
  assert(!MMNativePropertyLinkColor(host,MMCustomControls,TestTime(3)));
  host.lanes=copyLanes(linked); refreshCaches(host);
  assert([first isEqual:MMNativePropertyLinkColor(host,MMCustomControls,TestTime(3))]);
}

static void testRollback(void) {
  NativeHost *failedAdd = fixture();
  addNativePose(failedAdd, MMCustomControls, 1, 10, [MMPoseTiming new]);
  refreshCaches(failedAdd);
  failedAdd.failAddOnce = MMScaleControls;
  NSArray *beforeKeys = [[failedAdd lane:MMScaleControls] copy];
  assert(!MMSetNativePropertyLink(failedAdd, MMCustomControls, MMScaleControls,
                                  TestTime(1), YES));
  assert([[failedAdd lane:MMScaleControls] isEqual:beforeKeys]);
  assert(!MMNativePropertyLinked(failedAdd, MMCustomControls, TestTime(1)));

  NativeHost *failedSet = fixture();
  assert(MMSetNativePropertyLink(failedSet, MMCustomControls, MMScaleControls,
                                 TestTime(0), YES));
  id old = entryAt(failedSet, MMScaleControls, 0)[@"pose"];
  failedSet.failBlobOnce = MMScaleControls;
  id replacement = poseForParameter(MMCustomControls, 99, [MMPoseTiming new]);
  assert(!MMWriteNativeLinkedPose(failedSet, MMCustomControls, TestTime(0), replacement));
  assert([entryAt(failedSet, MMScaleControls, 0)[@"pose"] isEqual:old]);
  assert([entryAt(failedSet, MMCustomControls, 0)[@"pose"] positionX] != 99);
}

int main(void) {
  @autoreleasepool {
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
