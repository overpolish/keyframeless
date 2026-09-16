/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "MMAnchorPose.h"
#import "MMScalarPose.h"
#import "MMPropertyRow.h"
#import "MMTimingEditorModel.h"
#import "MMNativeLinks.h"
#import "MMResetParameter.h"
#import "ShaderTypes.h"

@interface PropertyHost : MockHost <FxCustomParameterActionAPI_v4>
@property CMTime currentTime;
@property NSUInteger actions;
@property NSUInteger ends;
@property NSMutableArray *order;
@end
@implementation PropertyHost
- (instancetype)init { if((self=[super init])) { _currentTime=TestTime(2); _order=[NSMutableArray new]; } return self; }
- (void)startAction:(id)sender { self.actions++; }
- (void)endAction:(id)sender { self.ends++; }
- (BOOL)addCustomParameterWithName:(NSString *)name parameterID:(UInt32)p defaultValue:(id)value parameterFlags:(FxParameterFlags)flags {
  [self.order addObject:@(p)]; return [super addCustomParameterWithName:name parameterID:p defaultValue:value parameterFlags:flags];
}
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding,NSCopying> **)value fromParameter:(UInt32)p atTime:(CMTime)t {
  if(self.failReadParameter==p) return NO;
  for(NSDictionary *entry in [self lane:p])
    if(fabs([entry[@"time"] doubleValue]-CMTimeGetSeconds(t))<1e-6) { *value=entry[@"value"]; return YES; }
  return [super getCustomParameterValue:value fromParameter:p atTime:t];
}
- (BOOL)setCustomParameterValue:(id)value toParameter:(UInt32)p atTime:(CMTime)t {
  if(self.failBlobOnce==p) return [super setCustomParameterValue:value toParameter:p atTime:t];
  for(NSMutableDictionary *entry in [self lane:p])
    if(fabs([entry[@"time"] doubleValue]-CMTimeGetSeconds(t))<1e-6) entry[@"value"]=value;
  return [super setCustomParameterValue:value toParameter:p atTime:t];
}
@end
static id<MMPropertyPose> pose(MMPropertyLane *lane,NSArray *values,MMPoseTiming *timing) {
  return [lane.defaultPose poseByReplacingValues:values authored:YES easing:MTEasingLinear addedMotion:MTAddedMotionNone timing:timing?:[MMPoseTiming new]];
}
static void key(PropertyHost *h,MMPropertyLane *lane,double t,id<MMPropertyPose> p) {
  FxKeyframe k; FxInitKeyframe(k,kFxKeyframe_CurrentVersion); k.time=TestTime(t);
  [[h lane:lane.parameterID] addObject:[@{@"time":@(t),@"value":p,@"key":[NSValue valueWithBytes:&k objCType:@encode(FxKeyframe)]} mutableCopy]];
  h.blobs[@(lane.parameterID)]=p;
}
static MMPropertyPoseCache *cache(PropertyHost *h,MMPropertyLane *lane) {
  MMPropertyPoseCache *cache=[lane createCache]; h.staticValues[@(lane.cacheTokenID)]=cache.token;
  [lane refreshCacheForManager:h time:TestTime(2)]; return cache;
}
static void coding(void) {
  MMPoseTiming *timing=[[[MMPoseTiming alloc] initWithDuration:.8 available:YES amount:2 speed:3] timingByReplacingLinkID:@"pair"];
  timing=[timing timingByReplacingMotionSeed:123 linked:NO componentMask:2];
  MMAnchorPose *p=(id)pose(MMAnchorLane(),@[@120,@(-45)],timing);
  NSError *error=nil;
  NSData *data=[NSKeyedArchiver archivedDataWithRootObject:p requiringSecureCoding:YES error:&error]; assert(data&&!error);
  MMAnchorPose *decoded=[NSKeyedUnarchiver unarchivedObjectOfClass:MMAnchorPose.class fromData:data error:&error];
  assert(decoded && [decoded isEqual:p] && [decoded.timing isEqual:timing]);
  MMAnchorPose *other=(id)pose(MMAnchorLane(),@[@200,@55],timing);
  MMAnchorPose *mid=(id)[p interpolateBetween:other withWeight:.5];
  assert(mid.x==160 && mid.y==5 && mid.timing.linkID.length==0);
  assert(![[MMAnchorPose alloc] initWithX:INFINITY y:0 authored:YES easing:MTEasingLinear addedMotion:MTAddedMotionNone]);
  assert(![p poseByReplacingValues:@[@1] authored:YES easing:MTEasingLinear addedMotion:MTAddedMotionNone timing:timing]);
}
static void timingAndWrites(void) {
  for(MMPropertyLane *lane in @[MMBlurLane(),MMAnchorLane()]) {
    PropertyHost *h=[PropertyHost new];
    NSArray *start=lane.componentCount==1 ? @[@0]:@[@0,@20];
    NSArray *end=lane.componentCount==1 ? @[@80]:@[@200,@120];
    key(h,lane,0,pose(lane,start,nil)); key(h,lane,4,pose(lane,end,nil));
    MMPropertyPoseCache *c=cache(h,lane);
    assert(MMWriteInspectorSetting(h,lane.parameterID,TestTime(2),MMInspectorDuration,2));
    assert([lane sampleEntries:c.snapshotEntries time:TestTime(1)].value==0);
    assert(fabs([lane sampleEntries:c.snapshotEntries time:TestTime(3)].value-[end[0] doubleValue]/2)<1e-6);
    assert(MMWriteInspectorSetting(h,lane.parameterID,TestTime(2),MMInspectorAvailable,YES));
    MMInspectorGap *gap=MMReadInspectorGap(h,lane.parameterID,TestTime(2));
    NSArray *points=MMInspectorGraphComponents(gap,5);
    assert(points.count==5 && [points[0] count]==lane.componentCount && [points.lastObject isEqual:end]);
    NSUInteger reads=h.nativeKeyReads;
    assert([lane writeComponent:lane.componentCount-1 value:45 manager:h cache:c time:TestTime(2) explicit:YES]);
    assert(h.nativeKeyReads==reads && [h lane:lane.parameterID].count==2);
    id<MMPropertyPose> changed=c.snapshotEntries.lastObject[@"pose"];
    assert(changed.values.lastObject.doubleValue==45);
    if(lane.componentCount==2) assert(changed.values[0].doubleValue==200);
    h.failBlobOnce=lane.parameterID;
    assert(![lane writeValue:67 manager:h cache:c time:TestTime(4) explicit:NO]);
    assert([c.snapshotEntries.lastObject[@"pose"] isEqual:changed]);
    // Added Motion is outgoing; incoming easing remains on the next key.
    assert(MMWriteInspectorSetting(h,lane.parameterID,TestTime(2),MMInspectorMotion,MTAddedMotionWave));
    assert(MMWriteInspectorSetting(h,lane.parameterID,TestTime(2),MMInspectorEasing,MTEasingEaseOut));
    id<MMPropertyPose> left=c.snapshotEntries.firstObject[@"pose"], right=c.snapshotEntries.lastObject[@"pose"];
    assert(left.addedMotion==MTAddedMotionWave && right.addedMotion==MTAddedMotionNone && right.easing==MTEasingEaseOut);
    if(lane==MMBlurLane()) {
      assert([lane writeValue:-5 manager:h cache:c time:TestTime(4) explicit:NO]);
      assert([(id<MMPropertyPose>)c.snapshotEntries.lastObject[@"pose"] value]==0);
    } else {
      assert([lane writeValue:-5000 manager:h cache:c time:TestTime(4) explicit:NO]);
      assert([(id<MMPropertyPose>)c.snapshotEntries.lastObject[@"pose"] value]==-5000);
    }
  }
}
static void linkingAndReset(void) {
  PropertyHost *h=[PropertyHost new];
  key(h,MMBlurLane(),0,pose(MMBlurLane(),@[@0],nil)); key(h,MMBlurLane(),4,pose(MMBlurLane(),@[@60],nil));
  key(h,MMAnchorLane(),1,pose(MMAnchorLane(),@[@0,@0],nil)); key(h,MMAnchorLane(),4,pose(MMAnchorLane(),@[@100,@40],nil));
  MMPropertyPoseCache *blur=cache(h,MMBlurLane()), *anchor=cache(h,MMAnchorLane());
  assert(MMSetNativePropertyLink(h,MMBlurControls,MMAnchorControls,TestTime(2),YES));
  assert(MMNativePropertyLinked(h,MMBlurControls,TestTime(2)) && MMNativePropertyLinked(h,MMAnchorControls,TestTime(2)));
  assert(MMWriteInspectorSetting(h,MMBlurControls,TestTime(2),MMInspectorDuration,.75));
  assert([(id<MMPropertyPose>)anchor.snapshotEntries.lastObject[@"pose"] timing].duration==.75);
  NSArray *gaps=MMReadInspectorGraphGaps(h,MMBlurControls,TestTime(2));
  assert(gaps.count==2 && MMInspectorGraphStartFractions(gaps).count==3);
  assert([MMInspectorCombinedGraphPoints(gaps,9,CGSizeMake(1920,1080))[0] count]==3);
  MMObserveNativeLinks(h,MMBlurControls,NO);
  FxKeyframe moved; [h keyframe:&moved forParameter:MMBlurControls channel:0 andIndex:1];
  moved.time=TestTime(5);
  assert(![h setKeyframeIndex:1 withKeyframe:&moved forParameter:MMBlurControls andChannel:0]);
  [MMBlurLane() refreshCacheForManager:h time:TestTime(2)];
  MMObserveNativeLinks(h,MMBlurControls,YES);
  assert(MMHasPendingNativeLinkMoves(h));
  assert(MMCommitNativeLinkMoves(h,YES,nil));
  assert([[h lane:MMAnchorControls].lastObject[@"time"] doubleValue]==4);
  assert(MMCommitNativeLinkMoves(h,NO,nil));
  assert([[h lane:MMAnchorControls].lastObject[@"time"] doubleValue]==5);
  for(MMPropertyLane *lane in @[MMBlurLane(),MMAnchorLane()]) {
    h.failBlobOnce=lane.parameterID;
    assert(!MMResetParameter(h,[NSView new],lane.parameterID));
    assert([h lane:lane.parameterID].count==2); // rollback restores keys on failure
    assert(MMResetParameter(h,[NSView new],lane.parameterID));
    assert([h lane:lane.parameterID].count==0 && h.undoDepth==0 && h.undoGroupsStarted==h.undoGroupsEnded);
    id<MMPropertyPose> p=[lane readValue:h time:TestTime(2)];
    assert([p.values isEqual:lane.defaultPose.values] && p.timing.linkID.length==0 && p.addedMotion==MTAddedMotionNone);
  }
  assert(blur.snapshotEntries.count==1 && anchor.snapshotEntries.count==1);
}
@interface MagicMovePlugin (Rows)
- (NSView *)createViewForParameterID:(UInt32)p;
@end
static void rowsAndRenderState(void) {
  PropertyHost *h=[PropertyHost new]; MagicMovePlugin *plugin=[[MagicMovePlugin alloc] initWithAPIManager:h];
  assert([plugin addParametersWithError:nil]);
  assert([h.order indexOfObject:@(MMBlurControls)]==[h.order indexOfObject:@(MMOpacityControls)]+1);
  assert([h.order indexOfObject:@(MMAnchorControls)]==[h.order indexOfObject:@(MMBlurControls)]+1);
  for(MMPropertyLane *lane in @[MMBlurLane(),MMAnchorLane()]) {
    FxParameterFlags flags=[h.flags[@(lane.parameterID)] unsignedIntValue];
    assert((flags & kFxParameterFlag_CUSTOM_UI) && !(flags & kFxParameterFlag_NOT_ANIMATABLE));
    ICInspectorRow *row=(id)[plugin createViewForParameterID:lane.parameterID];
    assert(row.fields.count==lane.componentCount);
    for(NSTextField *unit in row.unitLabels) assert([unit.stringValue isEqual:@"px"]);
    for(ICValueTextField *field in row.fields) assert([(NSNumberFormatter *)field.formatter maximumFractionDigits]==0);
    if(lane==MMBlurLane()) assert([(MMScalarRow *)row sliderView]!=nil);
  }
  h.blobs[@(MMBlurControls)]=pose(MMBlurLane(),@[@15],nil);
  h.blobs[@(MMAnchorControls)]=pose(MMAnchorLane(),@[@120,@(-60)],nil);
  NSData *data=nil; assert([plugin pluginState:&data atTime:TestTime(2) quality:kFxQuality_HIGH error:nil]);
  MMTransform t; [data getBytes:&t length:sizeof(t)];
  assert(t.blurPixels==15 && t.anchor.x==120 && t.anchor.y==-60);
  h.failReadParameter=MMBlurControls;
  assert(![plugin pluginState:&data atTime:TestTime(2) quality:kFxQuality_HIGH error:nil]);
  h.failReadParameter=MMAnchorControls;
  assert(![plugin pluginState:&data atTime:TestTime(2) quality:kFxQuality_HIGH error:nil]);
}
int main(void) { @autoreleasepool { [NSApplication sharedApplication]; coding(); timingAndWrites(); linkingAndReset(); rowsAndRenderState(); }
  puts("BlurAnchor: coding, timing, writes, linked graphs, reset rollback, inspector rows and render state passed"); return 0;
}
