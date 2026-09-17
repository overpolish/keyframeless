/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "Constants.h"
#import "MMLanes.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
@import InspectorControls;
#import <assert.h>
#import <math.h>

// The plugin's own wiring: what it registers with the host, the render state
// it derives from its lanes, and the rows it builds for them. Lane behaviour
// itself belongs to the PoseLanes suites.
@interface LaneHost : MockHost <FxCustomParameterActionAPI_v4>
@property CMTime currentTime;
@property NSUInteger actions;
@property NSUInteger ends;
@property NSMutableArray *order;
@property(nonatomic, copy) void (^readHook)(void);
@end
@implementation LaneHost
- (instancetype)init { if((self=[super init])) { _currentTime=TestTime(2); _order=[NSMutableArray new]; } return self; }
- (void)startAction:(id)sender { self.actions++; }
- (void)endAction:(id)sender { self.ends++; }
- (BOOL)addCustomParameterWithName:(NSString *)name parameterID:(UInt32)p defaultValue:(id)value parameterFlags:(FxParameterFlags)flags {
  [self.order addObject:@(p)];
  return [super addCustomParameterWithName:name parameterID:p defaultValue:value parameterFlags:flags];
}
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding,NSCopying> **)value fromParameter:(UInt32)p atTime:(CMTime)t {
  if(self.failReadParameter==p) return NO;
  for(NSDictionary *entry in [self lane:p])
    if(fabs([entry[@"time"] doubleValue]-CMTimeGetSeconds(t))<1e-6) {
      *value=entry[@"value"];
      if(self.readHook) { void (^hook)(void)=self.readHook; self.readHook=nil; hook(); }
      return YES;
    }
  return [super getCustomParameterValue:value fromParameter:p atTime:t];
}
- (BOOL)setCustomParameterValue:(id)value toParameter:(UInt32)p atTime:(CMTime)t {
  if(self.failBlobOnce==p) return [super setCustomParameterValue:value toParameter:p atTime:t];
  for(NSMutableDictionary *entry in [self lane:p])
    if(fabs([entry[@"time"] doubleValue]-CMTimeGetSeconds(t))<1e-6) entry[@"value"]=value;
  return [super setCustomParameterValue:value toParameter:p atTime:t];
}
@end

static id<KFPropertyPose> Pose(KFPropertyLane *lane, NSArray<NSNumber *> *values, KFPoseTiming *timing) {
  return [lane.defaultPose poseByReplacingValues:values authored:YES easing:MTEasingLinear
                                     addedMotion:MTAddedMotionNone timing:timing ?: [KFPoseTiming new]];
}
// Values inside the lane's own range, offset per component so a write that
// touches the wrong axis is visible.
static NSArray<NSNumber *> *Values(KFPropertyLane *lane, double fraction) {
  double span=lane.maximum-lane.minimum, base=lane.minimum+span*fraction;
  NSMutableArray<NSNumber *> *values=[NSMutableArray arrayWithCapacity:lane.componentCount];
  for(NSUInteger axis=0;axis<lane.componentCount;axis++) [values addObject:@(base+axis*span/16)];
  return values;
}
static void Key(LaneHost *host, KFPropertyLane *lane, double time, id<KFPropertyPose> pose) {
  FxKeyframe key; FxInitKeyframe(key,kFxKeyframe_CurrentVersion); key.time=TestTime(time);
  [[host lane:lane.parameterID] addObject:[@{@"time":@(time), @"value":pose,
      @"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)]} mutableCopy]];
  host.blobs[@(lane.parameterID)]=pose;
}
static KFPropertyPoseCache *Cache(LaneHost *host, KFPropertyLane *lane) {
  KFPropertyPoseCache *cache=[lane createCache];
  host.staticValues[@(lane.cacheTokenID)]=cache.token;
  [lane refreshCacheForManager:host time:TestTime(0)];
  return cache;
}

static void testRegistrationContract(void) {
  LaneHost *host=[LaneHost new];
  MagicMovePlugin *plugin=[[MagicMovePlugin alloc] initWithAPIManager:host];
  host.plugin=plugin;
  assert([plugin addParametersWithError:nil]);
  NSMutableArray *registered=[NSMutableArray new];
  for(NSNumber *parameter in host.order)
    if(KFPropertyLaneForParameter(parameter.unsignedIntValue)) [registered addObject:parameter];
  // Inspector order is the lane order; the row views are built from it.
  assert([registered isEqualToArray:KFProperties()]);
  NSMutableSet *colors=[NSMutableSet new];
  for(KFPropertyLane *lane in KFPropertyLanes()) {
    FxParameterFlags flags=[host.flags[@(lane.parameterID)] unsignedIntValue];
    assert((flags & kFxParameterFlag_CUSTOM_UI) && (flags & kFxParameterFlag_USE_FULL_VIEW_WIDTH));
    assert(!(flags & (kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE)));
    FxParameterFlags token=[host.flags[@(lane.cacheTokenID)] unsignedIntValue];
    assert((token & kFxParameterFlag_HIDDEN) && (token & kFxParameterFlag_NOT_ANIMATABLE) &&
           (token & kFxParameterFlag_DONT_SAVE));
    assert([host.definitions[@(lane.cacheTokenID)][@"kind"] isEqual:@"string"]);
    FxParameterFlags match=[host.flags[@(lane.matchToggleID)] unsignedIntValue];
    assert((match & kFxParameterFlag_HIDDEN) && (match & kFxParameterFlag_NOT_ANIMATABLE));
    assert(!(match & kFxParameterFlag_DONT_SAVE));
    assert(![host.definitions[@(lane.matchToggleID)][@"default"] boolValue]);
    assert(lane.matchToggleID==KFMatchToggleForProperty(lane.parameterID));
    assert(lane.componentColors.count==lane.componentCount);
    for(NSColor *color in lane.componentColors) assert(![colors containsObject:color]);
    [colors addObjectsFromArray:lane.componentColors];
    assert(lane.displayName.length && [KFPropertyDisplayName(lane.parameterID) isEqual:lane.displayName]);
    assert(KFPropertyLaneForParameter(lane.parameterID)==lane);
    NSSet<Class> *classes=[plugin classesForCustomParameterID:lane.parameterID];
    assert([classes containsObject:KFPose.class] && [classes containsObject:KFPoseTiming.class]);
    // Only Scale couples its axes, and only Position is a share of the image.
    assert((lane.proportionalToggleID!=0)==(lane==MMScaleLane()));
    assert(lane.percentOfImage==(lane==MMPositionLane()));
  }
  assert([host.definitions[@(MMScaleProportional)][@"default"] boolValue]);
  assert([host.flags[@(MMScaleProportional)] unsignedIntValue] & kFxParameterFlag_HIDDEN);
}

static void testRenderState(void) {
  LaneHost *host=[LaneHost new];
  MagicMovePlugin *plugin=[[MagicMovePlugin alloc] initWithAPIManager:host];
  host.plugin=plugin;
  assert([plugin addParametersWithError:nil]);
  // An unauthored effect renders as identity.
  NSData *state=nil;
  assert([plugin pluginState:&state atTime:TestTime(0) quality:kFxQuality_HIGH error:nil]);
  MMTransform transform; [state getBytes:&transform length:sizeof(transform)];
  assert(transform.offset.x==0 && transform.offset.y==0);
  assert(transform.scale==1 && transform.scaleY==1 && transform.opacity==1);
  assert(transform.blurPixels==0 && transform.anchor.x==0 && transform.anchor.y==0);
  host.blobs[@(MMPositionControls)]=Pose(MMPositionLane(),@[@25,@(-50)],nil);
  host.blobs[@(MMScaleControls)]=Pose(MMScaleLane(),@[@150,@120],nil);
  host.blobs[@(MMRotationControls)]=Pose(MMRotationLane(),@[@180,@90,@360],nil);
  host.blobs[@(MMOpacityControls)]=Pose(MMOpacityLane(),@[@50],nil);
  host.blobs[@(MMBlurControls)]=Pose(MMBlurLane(),@[@15],nil);
  host.blobs[@(MMAnchorControls)]=Pose(MMAnchorLane(),@[@120,@(-60)],nil);
  assert([plugin pluginState:&state atTime:TestTime(0) quality:kFxQuality_HIGH error:nil]);
  [state getBytes:&transform length:sizeof(transform)];
  assert(fabs(transform.offset.x-.25)<1e-6 && fabs(transform.offset.y+.5)<1e-6);
  assert(fabs(transform.scale-1.5)<1e-6 && fabs(transform.scaleY-1.2)<1e-6);
  assert(fabs(transform.rotationX-(float)M_PI)<1e-5 && fabs(transform.rotationY-(float)(M_PI/2))<1e-5);
  // Full turns are reduced for trigonometry only.
  assert(fabs(transform.rotation)<1e-5);
  assert(fabs(transform.opacity-.5)<1e-6);
  assert(transform.blurPixels==15 && transform.anchor.x==120 && transform.anchor.y==-60);
  for(KFPropertyLane *lane in KFPropertyLanes()) {
    host.failReadParameter=lane.parameterID;
    assert(![plugin pluginState:&state atTime:TestTime(0) quality:kFxQuality_HIGH error:nil]);
  }
  host.failReadParameter=0;
}

@interface MagicMovePlugin (LaneRows)
- (NSView *)createViewForParameterID:(UInt32)parameter;
@end
static void testRowsPerLane(void) {
  LaneHost *host=[LaneHost new];
  MagicMovePlugin *plugin=[[MagicMovePlugin alloc] initWithAPIManager:host];
  host.plugin=plugin;
  assert([plugin addParametersWithError:nil]);
  for(KFPropertyLane *lane in KFPropertyLanes()) {
    ICInspectorRow *row=(ICInspectorRow *)[plugin createViewForParameterID:lane.parameterID];
    assert(row && row.fields.count==lane.componentCount);
    assert([row.titleLabel.stringValue isEqual:lane.displayName]);
    assert([row.componentColors isEqualToArray:lane.componentColors]);
    // Only a coupled lane offers the proportional link button.
    assert((row.linkButton!=nil)==(lane.proportionalToggleID!=0));
    assert([row isKindOfClass:(lane.componentCount==1 ? KFScalarRow.class : KFVectorRow.class)]);
    NSString *unit=lane==MMRotationLane() ? @"°" : lane==MMScaleLane() || lane==MMOpacityLane() ? @"%" : @"px";
    for(NSTextField *label in row.unitLabels) assert([label.stringValue isEqual:unit]);
  }
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    testRegistrationContract();
    testRenderState();
    testRowsPerLane();
  }
  puts("Lane integration: registration contract, render state and inspector rows passed");
  return 0;
}
