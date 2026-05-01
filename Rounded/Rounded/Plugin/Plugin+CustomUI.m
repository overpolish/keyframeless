/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>

@implementation RoundedPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSC {
  return [NSSet setWithObjects:@"Radius", @"Crop", nil];
}

- (NSArray<NSNumber *> *)currentValuesForLaneLabel:(NSString *)label
                                            atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return nil;
  if ([label isEqualToString:@"Radius"]) {
    double v = 0;
    [getAPI getFloatValue:&v fromParameter:kParamRadius atTime:time];
    return @[ @(v) ];
  }
  if ([label isEqualToString:@"Crop"]) {
    double t = 0, b = 0, l = 0, r = 0;
    [getAPI getFloatValue:&t fromParameter:kParamCropTop atTime:time];
    [getAPI getFloatValue:&b fromParameter:kParamCropBottom atTime:time];
    [getAPI getFloatValue:&l fromParameter:kParamCropLeft atTime:time];
    [getAPI getFloatValue:&r fromParameter:kParamCropRight atTime:time];
    return @[ @(t), @(b), @(l), @(r) ];
  }
  return nil;
}

- (BOOL)applyLaneValues:(NSArray<NSNumber *> *)values
               forLabel:(NSString *)label
                 atTime:(CMTime)time {
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI)
    return NO;
  if ([label isEqualToString:@"Radius"] && values.count >= 1) {
    [self _rdSetEnabled:@[ @(kParamRadius) ] setAPI:setAPI];
    [setAPI setFloatValue:values[0].doubleValue
              toParameter:kParamRadius
                   atTime:time];
    return YES;
  }
  if ([label isEqualToString:@"Crop"] && values.count >= 4) {
    [self _rdSetEnabled:@[
      @(kParamCropTop), @(kParamCropBottom), @(kParamCropLeft),
      @(kParamCropRight)
    ]
                 setAPI:setAPI];
    [setAPI setFloatValue:values[0].doubleValue
              toParameter:kParamCropTop
                   atTime:time];
    [setAPI setFloatValue:values[1].doubleValue
              toParameter:kParamCropBottom
                   atTime:time];
    [setAPI setFloatValue:values[2].doubleValue
              toParameter:kParamCropLeft
                   atTime:time];
    [setAPI setFloatValue:values[3].doubleValue
              toParameter:kParamCropRight
                   atTime:time];
    return YES;
  }
  return NO;
}

- (void)_rdSetEnabled:(NSArray<NSNumber *> *)pids
               setAPI:(id<FxParameterSettingAPI_v5>)setAPI {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  for (NSNumber *p in pids) {
    UInt32 pid = p.unsignedIntValue;
    FxParameterFlags cur = 0;
    [getAPI getParameterFlags:&cur fromParameter:pid];
    FxParameterFlags want = cur & ~kFxParameterFlag_DISABLED;
    if (cur != want)
      [setAPI setParameterFlags:want toParameter:pid];
  }
}

- (void)setEditingDisabled:(BOOL)disabled forLaneLabel:(NSString *)label {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!getAPI || !setAPI)
    return;
  NSArray<NSNumber *> *pids = nil;
  if ([label isEqualToString:@"Radius"])
    pids = @[ @(kParamRadius) ];
  else if ([label isEqualToString:@"Crop"])
    pids = @[
      @(kParamCropTop), @(kParamCropBottom), @(kParamCropLeft),
      @(kParamCropRight)
    ];
  for (NSNumber *p in pids) {
    UInt32 pid = p.unsignedIntValue;
    FxParameterFlags cur = 0;
    [getAPI getParameterFlags:&cur fromParameter:pid];
    FxParameterFlags want = disabled ? (cur | kFxParameterFlag_DISABLED)
                                     : (cur & ~kFxParameterFlag_DISABLED);
    if (cur != want)
      [setAPI setParameterFlags:want toParameter:pid];
  }
}

- (NSArray<KKTimingLane *> *)defaultLanesAtTime:(CMTime)time
                                    paramGetAPI:(id<FxParameterRetrievalAPI_v6>)
                                                    paramGetAPI {
  double radius = 0;
  [paramGetAPI getFloatValue:&radius fromParameter:kParamRadius atTime:time];
  KKTimingLane *radiusLane = [KKTimingLane defaultLaneForLabel:@"Radius"
                                                    baseValues:@[ @(radius) ]];
  radiusLane.valueComponentKinds = @[ @(KKAnimatableParamKindFloat) ];
  radiusLane.hasOSC = YES;

  double t = 0, b = 0, l = 0, r = 0;
  [paramGetAPI getFloatValue:&t fromParameter:kParamCropTop atTime:time];
  [paramGetAPI getFloatValue:&b fromParameter:kParamCropBottom atTime:time];
  [paramGetAPI getFloatValue:&l fromParameter:kParamCropLeft atTime:time];
  [paramGetAPI getFloatValue:&r fromParameter:kParamCropRight atTime:time];
  KKTimingLane *cropLane =
      [KKTimingLane defaultLaneForLabel:@"Crop"
                             baseValues:@[ @(t), @(b), @(l), @(r) ]];
  cropLane.valueComponentKinds = @[
    @(KKAnimatableParamKindFloat), @(KKAnimatableParamKindFloat),
    @(KKAnimatableParamKindFloat), @(KKAnimatableParamKindFloat)
  ];
  cropLane.hasOSC = YES;
  return @[ radiusLane, cropLane ];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamCropGroup) {
    return [self
        createGroupHeaderWithTitle:@"Crop"
                              icon:[NSImage imageWithSystemSymbolName:@"crop"
                                             accessibilityDescription:nil]
                       parameterID:parameterID
                   expandedParamID:kParamCropExpanded];
  }

  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

- (NSArray<KKHelpSection *> *)helpSections {
  KKHelpSection *rounded = [KKHelpSection
      sectionWithTitle:@"Rounded"
             tipMarkup:@[
               (@"Round the corners of any clip with an animatable "
                @"<accent>Radius</accent>."),
               (@"<accent>Crop</accent> trims each side independently - "
                @"animate it to reveal or hide content over time."),
             ]
             shortcuts:nil];
  rounded.icon = [NSImage imageWithSystemSymbolName:@"square.dotted"
                           accessibilityDescription:nil];
  return @[ rounded ];
}

@end
