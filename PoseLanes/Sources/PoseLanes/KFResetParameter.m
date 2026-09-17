/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFResetParameter.h"
#import "KFPropertyLane.h"
#import "KFEffect.h"
#import "KFHostSettings.h"
#import "KFPropertyMenu.h"

// Reset restores the lane default and drops the property's keyposes. The
// authored flag keeps the restored value the lane's own, not a fallback.
static id KFDefaultPose(UInt32 parameter) {
  id<KFPropertyPose> pose=KFPropertyLaneForParameter(parameter).defaultPose;
  return [pose poseByReplacingValues:pose.values authored:YES easing:pose.easing addedMotion:pose.addedMotion timing:pose.timing];
}
static NSArray *KFResetCachedEntries(id<PROAPIAccessing> manager, UInt32 parameter) {
  return [[KFPropertyLaneForParameter(parameter) cacheForManager:manager] snapshotEntries];
}
static void KFPublishReset(id<PROAPIAccessing> manager, UInt32 parameter, id pose) {
  [[KFPropertyLaneForParameter(parameter) cacheForManager:manager] publishConstantPose:pose];
}
BOOL KFResetParameter(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameter) {
  if(!KFDefaultPose(parameter)) return NO;
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
    defaults=KFDefaultPose(parameter);
    // Snapshot before mutation so a rejected value write can restore the entire
    // curve, including native interpolation information and our pose metadata.
    NSUInteger count=0;
    NSError *failure=[keys keyframeCount:&count forParameter:parameter andChannel:0];
    if(failure) return NO;

    NSArray *cached=KFResetCachedEntries(manager,parameter);
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
        (void)KFRequestHostRefresh(manager,time);

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
    if(success) KFPublishReset(manager,parameter,defaults);
  } @finally { [action endAction:sender]; }

  return success;
}

@interface KFResetMenuTarget : NSObject
@property(nonatomic, strong) id<PROAPIAccessing> manager;
@property(nonatomic, weak) NSView *sender;
@property(nonatomic) UInt32 parameter;
@end
@implementation KFResetMenuTarget
- (void)resetParameter:(NSMenuItem *)sender {
  NSMenu *menu=sender.menu; KFPropertyMenuActionScheduled(menu);

  // Leave AppKit's menu-tracking loop before opening a remote host action.
  // The default-mode block cannot run inside menu tracking, and explicitly
  // waking the loop avoids depending on a subsequent mouse event.
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopDefaultMode, ^{
    NSView *view=self.sender;
    if(!view) return;
    BOOL ok=KFResetParameter(self.manager,view,self.parameter);
    KFPropertyMenuActionFinished(menu,ok);
    if(!ok) NSBeep();
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}
@end
NSMenu *KFResetParameterMenu(id<PROAPIAccessing> manager, NSView *sender, UInt32 parameter) {
  KFResetMenuTarget *target=[KFResetMenuTarget new];
  target.manager=manager; target.sender=sender; target.parameter=parameter;
  NSMenu *menu=KFCreatePropertyMenu(manager,sender);
  NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:@"Reset Parameter" action:@selector(resetParameter:) keyEquivalent:@""];
  item.target=target; item.representedObject=target;
  [menu addItem:item]; return menu;
}
