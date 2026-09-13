/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MMResetParameter.h"
#import "MMShortcut.h"
#import "Constants.h"
#import "MMCombinedPose.h"
#import "MMScalePose.h"
#import "MMScalarPose.h"
#import "MMRotationPose.h"
static id MMDefaultPose(UInt32 parameter, id previous) {
  switch(parameter) {
    case MMCustomControls:
      // The historical combined payload also stored scale. Preserve that value;
      // this command owns Position only. Authored prevents legacy fallback.
      return [[MMCombinedPose alloc] initWithPositionX:0 positionY:0
          scale:[previous isKindOfClass:MMCombinedPose.class] ? [(MMCombinedPose *)previous scale]:100 authored:YES];
    case MMScaleControls: return [[MMScalePose alloc] initWithX:100 y:100 authored:YES];
    case MMOpacityControls: return [[MMScalarPose alloc] initWithValue:100 authored:YES easing:MTEasingSmooth addedMotion:MTAddedMotionNone];
    case MMRotationControls: return [[MMRotationPose alloc] initWithX:0 y:0 z:0 authored:YES easing:MTEasingSmooth addedMotion:MTAddedMotionNone];
    default: return nil;
  }
}
static NSArray *MMResetCachedEntries(id<PROAPIAccessing> manager, UInt32 parameter) {
  switch(parameter) {
    case MMCustomControls: return [MMCombinedCacheForManager(manager) snapshotEntries];
    case MMScaleControls: return [MMScaleCacheForManager(manager) snapshotEntries];
    case MMOpacityControls: return [[MMOpacityLane() cacheForManager:manager] snapshotEntries];
    case MMRotationControls: return [[MMRotationLane() cacheForManager:manager] snapshotEntries];
    default: return nil;
  }
}
static void MMPublishReset(id<PROAPIAccessing> manager, UInt32 parameter, id pose) {
  switch(parameter) {
    case MMCustomControls: [MMCombinedCacheForManager(manager) publishConstantPose:pose]; break;
    case MMScaleControls: [MMScaleCacheForManager(manager) publishConstantPose:pose]; break;
    case MMOpacityControls: [[MMOpacityLane() cacheForManager:manager] publishConstantPose:pose]; break;
    case MMRotationControls: [[MMRotationLane() cacheForManager:manager] publishConstantPose:pose]; break;
  }
}
BOOL MMResetParameter(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameter) {
  if(!MMDefaultPose(parameter,nil)) return NO;
  id<FxCustomParameterActionAPI_v4> action=[manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if(!action) return NO;
  BOOL success=NO;
  id defaults=nil;
  [action startAction:sender];
  @try {
    // Motion only supplies these APIs while the custom parameter action is open.
    id<FxKeyframeAPI_v3> keys=[manager apiForProtocol:@protocol(FxKeyframeAPI_v3)];
    id<FxParameterRetrievalAPI_v6> get=[manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> set=[manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    id<FxUndoAPI> undo=[manager apiForProtocol:@protocol(FxUndoAPI)];

    if(!keys || !get || !set || !undo) return NO;
    CMTime time=[action currentTime]; if(!CMTIME_IS_NUMERIC(time)) return NO;
    NSObject<NSSecureCoding,NSCopying> *previous=nil;
    if(![get getCustomParameterValue:&previous fromParameter:parameter atTime:time]) return NO;
    defaults=MMDefaultPose(parameter,previous);
    // Snapshot before mutation so a rejected value write can restore the entire
    // curve, including native interpolation information and our pose metadata.
    NSUInteger count=0;
    NSError *failure=[keys keyframeCount:&count forParameter:parameter andChannel:0];
    if(failure) return NO;

    NSArray *cached=MMResetCachedEntries(manager,parameter);
    BOOL cachedKeys=cached.count==count;
    for(NSDictionary *entry in cached) if(!entry[@"nativeKey"]) cachedKeys=NO;

    NSMutableArray *snapshot=[NSMutableArray arrayWithCapacity:count];
    for(NSUInteger i=0;i<count;i++) {
      FxKeyframe key; FxInitKeyframe(key,kFxKeyframe_CurrentVersion);
      // The renderer/callback already captured the full native record. Asking
      // Motion for it again here adds unnecessary remote reads.
      // Retain a fallback for snapshots not yet populated after a new key write.
      if(cachedKeys) [cached[i][@"nativeKey"] getValue:&key];
      else {
        failure=[keys keyframe:&key forParameter:parameter channel:0 andIndex:i];
        if(failure) return NO;
      }
      NSObject<NSSecureCoding,NSCopying> *pose=nil;
      if(![get getCustomParameterValue:&pose fromParameter:parameter atTime:key.time] || !pose) return NO;
      [snapshot addObject:@{@"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)],@"pose":pose}];
    }
    if(![undo startUndoGroup:@"Reset Parameter"]) return NO;
    @try {
      failure=[keys removeAllKeyframesForParameter:parameter andChannel:0];
      if(failure) return NO;
      success=[set setCustomParameterValue:defaults toParameter:parameter atTime:time];

      if(success) {
        // A changed scratch parameter prompts host invalidation at a stationary
        // playhead. Keep it in this undo group; never touch input/accessibility.
        (void)[set setCustomParameterValue:NSUUID.UUID.UUIDString
            toParameter:MMHostRefreshToken atTime:time];

      }
      if(!success) {
        if(previous) [set setCustomParameterValue:previous toParameter:parameter atTime:time];
        for(NSDictionary *entry in snapshot) {
          FxKeyframe key; [entry[@"key"] getValue:&key];
          if(![keys addKeyframe:&key toParameter:parameter andChannel:0])
            [set setCustomParameterValue:entry[@"pose"] toParameter:parameter atTime:key.time];
        }
      }
    } @finally { [undo endUndoGroup]; }
    // Cache token lookup also needs the action. Publish directly, without any
    // post-write key enumeration while remote changes are still pending.
    if(success) MMPublishReset(manager,parameter,defaults);
  } @finally { [action endAction:sender]; }

  return success;
}

static NSString *const MMMenuParametersChanged=@"MMMenuParametersChanged";

@interface MMPropertyMenu : NSMenu <NSMenuDelegate>
@property(nonatomic,strong) id<PROAPIAccessing> manager;
@property(nonatomic,weak) NSView *sender;
@property(nonatomic) BOOL actionScheduled;
@property(nonatomic) BOOL tracking;
@property(nonatomic,strong) id eventMonitor;
@property(nonatomic,strong) id parameterObserver;
@property(nonatomic,copy) void (^stateHandler)(void);
- (void)refreshHost;
- (BOOL)performHistoryRedo:(BOOL)redo;
- (void)refreshMenuState;
@end
@implementation MMPropertyMenu
- (void)menuWillOpen:(NSMenu *)menu {
  self.actionScheduled=NO; self.tracking=YES;
  if (self.eventMonitor) [NSEvent removeMonitor:self.eventMonitor];
  __weak typeof(self) weakSelf=self;
  if (self.parameterObserver) [NSNotificationCenter.defaultCenter removeObserver:self.parameterObserver];
  self.parameterObserver=[NSNotificationCenter.defaultCenter addObserverForName:MMMenuParametersChanged object:self.manager queue:nil usingBlock:^(NSNotification *note) {
    // Never block a host callback thread waiting for the menu/main thread.
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refreshMenuState]; });
  }];
  [[MMShortcutCapture sharedCapture] beginMenuHistory:self action:^BOOL(BOOL redo) {
    return [weakSelf performHistoryRedo:redo];
  }];
  self.eventMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
    MMPropertyMenu *strong=weakSelf;
    if (!strong || !strong.tracking) return event;
    if (event.type==NSEventTypeKeyDown && [strong performKeyEquivalent:event]) return nil;
    return event;
  }];
}
- (void)dealloc {
  if (_eventMonitor) [NSEvent removeMonitor:_eventMonitor];
  if (_parameterObserver) [NSNotificationCenter.defaultCenter removeObserver:_parameterObserver];
}
- (void)refreshMenuState {
  if (!self.tracking || !self.stateHandler || !self.sender) return;
  NSView *view=self.sender;
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!action) return;
  [action startAction:view];
  @try { self.stateHandler(); }
  @finally { [action endAction:view]; }
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
  NSEventModifierFlags flags=event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  BOOL history=self.tracking && event.type==NSEventTypeKeyDown &&
      [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"z"] &&
      (flags & NSEventModifierFlagCommand) &&
      !(flags & (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagFunction));
  if (!history) return [super performKeyEquivalent:event];
  return [self performHistoryRedo:(flags & NSEventModifierFlagShift)!=0];
}
- (BOOL)performHistoryRedo:(BOOL)redo {
  if (!self.tracking) return NO;
  NSView *view=self.sender;
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!view || !action) return NO;
  BOOL ok=NO; NSError *error=nil;
  [action startAction:view];
  @try {
    id<FxCommandAPI_v2> command=[self.manager apiForProtocol:@protocol(FxCommandAPI_v2)];
    ok=[command performCommand:redo ? kFxCommand_Redo : kFxCommand_Undo error:&error];
    if (command) {
      // Some hosts return NO while applying undo asynchronously. Treat dispatch
      // as handled, then follow published parameter callbacks for final state.
      // Do not write the scratch parameter here: a new edit could clear redo.
      self.actionScheduled=YES;
      if (self.stateHandler) self.stateHandler();
    }
    if (command) ok=YES; // Avoid forwarding an already-dispatched undo twice.
  } @finally { [action endAction:view]; }
  return ok;
}
- (void)menuDidClose:(NSMenu *)menu {
  self.tracking=NO;
  if (self.parameterObserver) {
    [NSNotificationCenter.defaultCenter removeObserver:self.parameterObserver]; self.parameterObserver=nil;
  }
  [[MMShortcutCapture sharedCapture] endMenuHistory:self];
  if (self.eventMonitor) { [NSEvent removeMonitor:self.eventMonitor]; self.eventMonitor=nil; }
  // AppKit can deliver the action after didClose. Decide in the normal loop,
  // after the synchronous menu callbacks have finished selecting an action.
  CFRunLoopPerformBlock(CFRunLoopGetMain(),kCFRunLoopDefaultMode,^{
    if(!self.actionScheduled) [self refreshHost];
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}
- (void)refreshHost {
  NSView *view=self.sender; if(!view) return;
  id<FxCustomParameterActionAPI_v4> action=[self.manager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if(!action) return;
  [action startAction:view];
  @try {
    id<FxParameterSettingAPI_v5> set=[self.manager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [set setCustomParameterValue:NSUUID.UUID.UUIDString toParameter:MMHostRefreshToken atTime:[action currentTime]];
  } @finally { [action endAction:view]; }
}
@end
void MMPropertyMenuParametersChanged(id<PROAPIAccessing> manager) {
  [NSNotificationCenter.defaultCenter postNotificationName:MMMenuParametersChanged object:manager];
}
void MMPropertyMenuSetStateHandler(NSMenu *menu, void (^handler)(void)) {
  if ([menu isKindOfClass:MMPropertyMenu.class]) ((MMPropertyMenu *)menu).stateHandler=handler;
}
void MMPropertyMenuActionScheduled(NSMenu *menu) {
  if([menu isKindOfClass:MMPropertyMenu.class]) { ((MMPropertyMenu *)menu).actionScheduled=YES; }
}
void MMPropertyMenuActionFinished(NSMenu *menu,BOOL refreshed) {
  if(!refreshed && [menu isKindOfClass:MMPropertyMenu.class]) [(MMPropertyMenu *)menu refreshHost];
}

@interface MMResetMenuTarget : NSObject
@property(nonatomic, strong) id<PROAPIAccessing> manager;
@property(nonatomic, weak) NSView *sender;
@property(nonatomic) UInt32 parameter;
@end
@implementation MMResetMenuTarget
- (void)resetParameter:(NSMenuItem *)sender {
  NSMenu *menu=sender.menu; MMPropertyMenuActionScheduled(menu);

  // Leave AppKit's menu-tracking loop before opening a remote host action.
  // The default-mode block cannot run inside menu tracking, and explicitly
  // waking the loop avoids depending on a subsequent mouse event.
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
    NSView *view=self.sender;
    if(!view) return;
    BOOL ok=MMResetParameter(self.manager,view,self.parameter);
    MMPropertyMenuActionFinished(menu,ok);
    if(!ok) NSBeep();
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}
@end
NSMenu *MMCreatePropertyMenu(id<PROAPIAccessing> manager, NSView *sender) {
  MMPropertyMenu *menu=[MMPropertyMenu new];
  menu.manager=manager; menu.sender=sender; menu.delegate=menu;
  return menu;
}
NSMenu *MMResetParameterMenu(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameter) {

  MMResetMenuTarget *target=[MMResetMenuTarget new];
  target.manager=manager; target.sender=sender; target.parameter=parameter;
  NSMenu *menu=MMCreatePropertyMenu(manager,sender);
  NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:@"Reset Parameter" action:@selector(resetParameter:) keyEquivalent:@""];
  item.target=target; item.representedObject=target;
  [menu addItem:item]; return menu;
}
