/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "MMResetParameter.h"
#import "MMCombinedPose.h"
#import "MMScalePose.h"
#import "MMScalarPose.h"
#import "MMRotationPose.h"
@import InspectorControls;

@interface ResetHost : MockHost <FxCustomParameterActionAPI_v4>
@property NSUInteger starts;
@property NSUInteger ends;
@property BOOL failRemove;
@property BOOL failUndo;
@property NSUInteger keyInfoReads;
@property NSUInteger refreshWrites;
@end
@implementation ResetHost
- (id)apiForProtocol:(Protocol *)protocol {
  BOOL scoped=protocol==@protocol(FxKeyframeAPI_v3) || protocol==@protocol(FxParameterRetrievalAPI_v6) ||
      protocol==@protocol(FxParameterSettingAPI_v5) || protocol==@protocol(FxUndoAPI);
  if(scoped && self.starts==self.ends) return nil;
  return [super apiForProtocol:protocol];
}
- (NSError *)keyframe:(FxKeyframe *)key forParameter:(NSUInteger)p channel:(NSUInteger)c andIndex:(NSUInteger)i {
  self.keyInfoReads++;
  return [super keyframe:key forParameter:p channel:c andIndex:i];
}
- (void)startAction:(id)sender { self.starts++; }
- (void)endAction:(id)sender { self.ends++; }
- (CMTime)currentTime { return TestTime(1); }
- (BOOL)startUndoGroup:(NSString *)name { return self.failUndo ? NO:[super startUndoGroup:name]; }
- (NSError *)removeAllKeyframesForParameter:(NSUInteger)p andChannel:(NSUInteger)c {
  if(self.failRemove) return [NSError errorWithDomain:@"ResetTest" code:1 userInfo:nil];
  return [super removeAllKeyframesForParameter:p andChannel:c];
}
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding,NSCopying> **)value fromParameter:(UInt32)p atTime:(CMTime)t {
  if(self.failReadParameter==p) return NO;
  for(NSDictionary *entry in [self lane:p])
    if(fabs([entry[@"time"] doubleValue]-CMTimeGetSeconds(t))<1e-6) { *value=entry[@"value"]; return YES; }
  return [super getCustomParameterValue:value fromParameter:p atTime:t];
}
- (BOOL)setCustomParameterValue:(id)value toParameter:(UInt32)p atTime:(CMTime)t {
  if(p==MMHostRefreshToken) {
    assert(self.starts>self.ends && self.undoDepth==1);
    assert([value isKindOfClass:NSString.class] && [value length]>0);
    self.refreshWrites++;
  }
  if(self.failBlobOnce==p) return [super setCustomParameterValue:value toParameter:p atTime:t];
  for(NSMutableDictionary *entry in [self lane:p])
    if(fabs([entry[@"time"] doubleValue]-CMTimeGetSeconds(t))<1e-6) entry[@"value"]=value;
  // An unanimated parameter stays constant when set after all keys are removed.
  return [super setCustomParameterValue:value toParameter:p atTime:t];
}
@end
static id changedPose(UInt32 p) {
  switch(p) {
    case MMCustomControls: return [[MMCombinedPose alloc] initWithPositionX:40 positionY:30 scale:125 authored:YES easing:MTEasingLinear addedMotion:MTAddedMotionWave];
    case MMScaleControls: return [[MMScalePose alloc] initWithX:200 y:150 authored:YES easing:MTEasingLinear addedMotion:MTAddedMotionWave];
    case MMOpacityControls: return [[MMScalarPose alloc] initWithValue:30 authored:YES easing:MTEasingLinear addedMotion:MTAddedMotionWave];
    default: return [[MMRotationPose alloc] initWithX:45 y:90 z:720 authored:YES easing:MTEasingLinear addedMotion:MTAddedMotionWave];
  }
}
static void seed(ResetHost *host, UInt32 p) {
  id pose=[changedPose(p) poseByReplacingTiming:[[MMPoseTiming alloc] initWithDuration:3 available:YES amount:2 speed:4]]; host.blobs[@(p)]=pose;
  for(int t=0;t<3;t+=2) {
    FxKeyframe key; FxInitKeyframe(key,kFxKeyframe_CurrentVersion); key.time=TestTime(t);
    [[host lane:p] addObject:[@{@"time":@(t),@"value":pose,@"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)]} mutableCopy]];
  }
}
static void refreshSnapshots(ResetHost *host) {
  [host startAction:host];
  MMRefreshCombinedPoseCache(host,TestTime(1));
  MMRefreshScalePoseCache(host,TestTime(1));
  [MMOpacityLane() refreshCacheForManager:host time:TestTime(1)];
  [MMRotationLane() refreshCacheForManager:host time:TestTime(1)];
  [host endAction:host];
  host.starts=host.ends=0; host.keyInfoReads=0;
}
static void checkDefault(id pose, UInt32 p) {
  assert([pose authored]); assert([pose easing]==MTEasingSmooth); assert([pose addedMotion]==MTAddedMotionNone);
  MMPoseTiming *timing=[pose timing]; assert(!timing.available && timing.duration==1.2 && timing.amount==1 && timing.speed==1);
  if(p==MMCustomControls) { assert([pose positionX]==0 && [pose positionY]==0 && [(MMCombinedPose *)pose scale]==125); }
  else if(p==MMScaleControls) { assert([pose x]==100 && [pose y]==100); }
  else if(p==MMOpacityControls) { assert([(MMScalarPose *)pose value]==100); }
  else { assert([pose x]==0 && [pose y]==0 && [pose z]==0); }
}
@interface MagicMovePlugin (ResetTest)
- (NSView *)createViewForParameterID:(UInt32)p NS_RETURNS_RETAINED;
@end
int main(void) { @autoreleasepool {
  [NSApplication sharedApplication];
  NSArray *parameters=@[@(MMCustomControls),@(MMScaleControls),@(MMOpacityControls),@(MMRotationControls)];
  for(NSNumber *number in parameters) {
    UInt32 p=number.unsignedIntValue;
    ResetHost *host=[ResetHost new];
    for(NSNumber *other in parameters) seed(host,other.unsignedIntValue);
    MMCombinedPoseCache *position=MMCreateCombinedPoseCache(); host.staticValues[@(MMCombinedCacheToken)]=position.token;
    MMScalePoseCache *scale=MMCreateScalePoseCache(); host.staticValues[@(MMScaleCacheToken)]=scale.token;
    MMPropertyPoseCache *opacity=[MMOpacityLane() createCache]; host.staticValues[@(MMOpacityCacheToken)]=opacity.token;
    MMPropertyPoseCache *rotation=[MMRotationLane() createCache]; host.staticValues[@(MMRotationCacheToken)]=rotation.token;
    refreshSnapshots(host);
    assert(MMResetParameter(host,[NSView new],p));
    assert(host.keyInfoReads==0 && host.refreshWrites==1);
    NSString *firstToken=host.blobs[@(MMHostRefreshToken)];
    assert([host lane:p].count==0); checkDefault(host.blobs[number],p);
    assert(host.starts==1 && host.ends==1 && host.undoGroupsStarted==1 && host.undoGroupsEnded==1 && host.undoDepth==0);
    for(NSNumber *other in parameters) if(![other isEqual:number]) { assert([host lane:other.unsignedIntValue].count==2); assert([host.blobs[other] addedMotion]==MTAddedMotionWave); }
    NSArray *entries=p==MMCustomControls ? position.snapshotEntries:p==MMScaleControls ? scale.snapshotEntries:p==MMOpacityControls ? opacity.snapshotEntries:rotation.snapshotEntries;
    assert(entries.count==1 && !entries[0][@"nativeTime"]); checkDefault(entries[0][@"pose"],p);
    assert(MMResetParameter(host,[NSView new],p)); assert(![host lane:p].count); // repeated constant reset
    assert(host.refreshWrites==2 && ![firstToken isEqual:host.blobs[@(MMHostRefreshToken)]]);

    for(int failure=0;failure<4;failure++) {
      ResetHost *failed=[ResetHost new]; seed(failed,p);
      NSArray *before=[[NSArray alloc] initWithArray:[failed lane:p] copyItems:YES]; id old=failed.blobs[number];
      if(failure==0) failed.failBlobOnce=p;
      if(failure==1) failed.failReadParameter=p;
      if(failure==2) failed.failRemove=YES;
      if(failure==3) failed.failUndo=YES;
      assert(!MMResetParameter(failed,[NSView new],p));
      assert([[failed lane:p] isEqual:before] && failed.blobs[number]==old);
      assert(failed.starts==failed.ends && failed.undoDepth==0 && failed.refreshWrites==0);
    }
    ResetHost *rowHost=[ResetHost new];
    MagicMovePlugin *plugin=[[MagicMovePlugin alloc] initWithAPIManager:rowHost]; rowHost.plugin=plugin;
    ICInspectorRow *row=(ICInspectorRow *)[plugin createViewForParameterID:p];
    assert(row.titleMenuProvider); NSMenu *menu=row.titleMenuProvider();
    // Position, Scale, Rotation and Anchor carry their on-screen control toggle and a separator.
    BOOL hasOSC=p==MMCustomControls || p==MMScaleControls || p==MMRotationControls || p==MMAnchorControls;
    assert(menu.numberOfItems==(hasOSC ? 11:9) && [menu.itemArray[0].title isEqualToString:@"Reset Parameter"]);
    if(hasOSC) assert([menu.itemArray[1].title isEqualToString:@"On-Screen Control"] && menu.itemArray[2].isSeparatorItem);
    assert([menu.itemArray[hasOSC ? 3:1].title isEqualToString:@"Match In/Out"]);
    NSMenuItem *item=menu.itemArray[0];
    seed(rowHost,p);
    refreshSnapshots(rowHost);
    [NSApp sendAction:item.action to:item.target from:item];
    assert([rowHost lane:p].count==2); // Menu action does no synchronous host work.
    CFRunLoopRunInMode((__bridge CFStringRef)NSEventTrackingRunLoopMode,0.01,false);
    assert([rowHost lane:p].count==2); // It must wait until menu tracking ends.
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,false);
    assert(![rowHost lane:p].count); checkDefault(rowHost.blobs[number],p);
  }
  puts("ResetParameterTests passed");
} return 0; }
