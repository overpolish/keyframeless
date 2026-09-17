/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "TestLanes.h"
@import InspectorControls;
@import PluginPreferences;

static KFPropertyLane *MakeLane(UInt32 parameter, NSString *name, UInt32 cacheToken,
                                UInt32 matchToggle, UInt32 proportionalToggle,
                                UInt32 visibilityToggle, NSArray<NSString *> *labels,
                                NSString *suffix, NSUInteger digits, NSArray<NSNumber *> *values,
                                double minimum, double maximum, BOOL bounds, BOOL percentOfImage) {
  NSArray<NSColor *> *palette = ICInspectorTokens.curveColors;
  NSMutableArray<NSColor *> *colors = [NSMutableArray arrayWithCapacity:values.count];
  for (NSUInteger axis = 0; axis < values.count; axis++) [colors addObject:palette[axis]];
  KFPose *pose = [[KFPose alloc] initWithValues:values authored:NO easing:MTEasingSmooth
                                    addedMotion:MTAddedMotionNone];
  return [[KFPropertyLane alloc] initWithParameterID:parameter displayName:name
      cacheTokenID:cacheToken matchToggleID:matchToggle proportionalToggleID:proportionalToggle
      visibilityToggleID:visibilityToggle componentColors:colors componentLabels:labels
      unitSuffix:suffix fractionDigits:digits defaultPose:pose minimum:minimum maximum:maximum
      boundsValues:bounds percentOfImage:percentOfImage];
}

static NSArray<KFPropertyLane *> *TestLanes(void) {
  static NSArray<KFPropertyLane *> *lanes;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lanes = @[
      MakeLane(KFTestPosition, @"Position", KFTestPositionCacheToken, KFTestPositionMatchEnds, 0,
               KFTestShowPositionOSC, @[@"X", @"Y"], @"px", 0, @[@0, @0], -200, 200, NO, YES),
      MakeLane(KFTestScale, @"Scale", KFTestScaleCacheToken, KFTestScaleMatchEnds,
               KFTestScaleProportional, KFTestShowScaleOSC, @[@"X", @"Y"], @"%", 1,
               @[@100, @100], 0, 400, YES, NO),
      MakeLane(KFTestRotation, @"Rotation", KFTestRotationCacheToken, KFTestRotationMatchEnds, 0,
               KFTestShowRotationOSC, @[@"X", @"Y", @"Z"], @"°", 1, @[@0, @0, @0], -180, 180, NO, NO),
      MakeLane(KFTestOpacity, @"Opacity", KFTestOpacityCacheToken, KFTestOpacityMatchEnds, 0, 0,
               @[@"X"], @"%", 1, @[@100], 0, 100, YES, NO),
      MakeLane(KFTestBlur, @"Blur", KFTestBlurCacheToken, KFTestBlurMatchEnds, 0, 0,
               @[@"X"], @"px", 0, @[@0], 0, 100, YES, NO),
      MakeLane(KFTestAnchor, @"Anchor", KFTestAnchorCacheToken, KFTestAnchorMatchEnds, 0,
               KFTestShowAnchorOSC, @[@"X", @"Y"], @"px", 0, @[@0, @0], -1000, 1000, NO, NO),
    ];
  });
  return lanes;
}

KFPropertyLane *KFTestPositionLane(void) { return TestLanes()[0]; }
KFPropertyLane *KFTestScaleLane(void) { return TestLanes()[1]; }
KFPropertyLane *KFTestRotationLane(void) { return TestLanes()[2]; }
KFPropertyLane *KFTestOpacityLane(void) { return TestLanes()[3]; }
KFPropertyLane *KFTestBlurLane(void) { return TestLanes()[4]; }
KFPropertyLane *KFTestAnchorLane(void) { return TestLanes()[5]; }

// Factory values and validation belong to a plugin, so the tests supply the
// smallest store that satisfies the contract.
@interface TestDefaults : NSObject <KFDefaults>
@end
@implementation TestDefaults {
  PPDefaultStore *_store;
}
- (instancetype)init {
  if ((self = [super init])) {
    NSString *suite = NSProcessInfo.processInfo.environment[@"KF_PREFERENCES_SUITE"]
                          ?: @"co.overpolish.poselanes.tests";
    _store = [[PPDefaultStore alloc]
        initWithDefaults:[[NSUserDefaults alloc] initWithSuiteName:suite]
               namespace:@"defaults"];
  }
  return self;
}
- (NSDictionary *)factoryForKey:(NSString *)key {
  if ([key isEqual:KFDurationDefaultKey]) return @{@"value" : @1.2};
  if ([key isEqual:KFEasingDefaultKey]) return @{@"value" : @(MTEasingSmooth)};
  return @{@"amount" : @1, @"speed" : @1};
}
- (NSDictionary *)defaultForKey:(NSString *)key {
  return [_store valueForKey:key factory:[self factoryForKey:key]
                    validate:^BOOL(NSDictionary *value) { return value.count > 0; }];
}
- (BOOL)setDefault:(NSDictionary *)value forKey:(NSString *)key {
  return [_store setValue:value forKey:key
                 validate:^BOOL(NSDictionary *candidate) { return candidate.count > 0; }];
}
- (BOOL)restoreFactoryDefaultForKey:(NSString *)key {
  [_store restoreFactoryForKey:key];
  return YES;
}
@end

void KFTestRegisterLanes(void) {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    KFRegisterLanes(TestLanes());
    KFSetHostRefreshParameter(KFTestHostRefreshToken);
    KFSetExplicitCreationParameter(KFTestExplicitCreation);
    KFSetDefaults([TestDefaults new]);
  });
}

@implementation KFTestEffect
- (BOOL)addParameters {
  id<FxParameterCreationAPI_v5> api =
      [self.apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
  if (!api) return NO;
  BOOL ok = KFAddHostRefreshToken(api, @"Host Refresh", KFTestHostRefreshToken);
  for (KFPropertyLane *lane in KFPropertyLanes()) {
    ok = ok && KFAddCustomUIParameter(api, lane.parameterID,
                                      KFPoseWithCreationDefaults(lane.defaultPose));
    ok = ok && KFAddCacheToken(api, [lane.displayName stringByAppendingString:@" view cache"],
                               lane.cacheTokenID);
    ok = ok && KFAddHiddenToggle(api, [lane.displayName stringByAppendingString:@" Match In/Out"],
                                 lane.matchToggleID, NO);
    if (lane.proportionalToggleID)
      ok = ok && KFAddHiddenToggle(api, [lane.displayName stringByAppendingString:@" Proportional"],
                                   lane.proportionalToggleID, YES);
    if (lane.visibilityToggleID)
      ok = ok && KFAddHiddenToggle(api, [lane.displayName stringByAppendingString:@" On-Screen Control"],
                                   lane.visibilityToggleID, YES);
  }
  ok = ok && KFAddCustomUIPanel(api, KFTestTimingControls);
  ok = ok && KFAddHiddenToggle(api, @"Explicit Keypose Creation", KFTestExplicitCreation, NO);
  return ok;
}
- (NSView *)createViewForParameterID:(UInt32)parameterID {
  [self publishViewCaches];
  if (parameterID == KFTestTimingControls) return [[KFTimingEditor alloc] initWithEffect:self];
  KFPropertyLane *lane = KFPropertyLaneForParameter(parameterID);
  if (!lane) return nil;
  if (lane.componentCount == 1) return [[KFScalarRow alloc] initWithEffect:self lane:lane];
  return [[KFVectorRow alloc] initWithEffect:self lane:lane];
}
// The host's callback, as a plugin implements it: prime the creation tracker,
// refresh the lane's cache and fold in any observed native link move.
- (BOOL)parameterChanged:(UInt32)parameterID atTime:(CMTime)time error:(NSError **)error {
  for (KFPropertyLane *lane in KFPropertyLanes()) {
    if (parameterID != lane.parameterID && parameterID != lane.cacheTokenID) continue;
    KFPrimeDefaultKeyTracker(self.apiManager, lane.parameterID);
    [lane refreshCacheForManager:self.apiManager time:time];
    KFObserveNativeLinks(self.apiManager, lane.parameterID, NO);
    KFPropertyMenuParametersChanged(self.apiManager);
    break;
  }
  return YES;
}
- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  if (KFPropertyLaneForParameter(parameterID))
    return [NSSet setWithObjects:KFPose.class, KFPoseTiming.class, nil];
  return [NSSet setWithObject:NSString.class];
}
@end
