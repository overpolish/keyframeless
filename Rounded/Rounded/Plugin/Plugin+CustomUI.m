/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation RoundedPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSC {
  return [NSSet setWithObjects:@"Radius", @"Crop", nil];
}

- (NSArray<NSNumber *> *)currentValuesForLaneLabel:(NSString *)label
                                          groupKey:(NSString *)groupKey
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
               groupKey:(NSString *)groupKey
                 atTime:(CMTime)time {
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!setAPI)
    return NO;
  // setFloatValue:atTime: registers a host undo entry even when the value
  // is unchanged, so a same-value write (e.g. selecting a segment whose
  // stored value already matches the live param) creates a phantom cmd-Z
  // step. Read first and skip writes whose value is already current.
  void (^writeIfChanged)(double, UInt32) = ^(double want, UInt32 pid) {
    double cur = 0;
    if (getAPI)
      [getAPI getFloatValue:&cur fromParameter:pid atTime:time];
    if (fabs(cur - want) > 1e-6)
      [setAPI setFloatValue:want toParameter:pid atTime:time];
  };
  if ([label isEqualToString:@"Radius"] && values.count >= 1) {
    [self _rdSetEnabled:@[ @(kParamRadius) ] setAPI:setAPI];
    writeIfChanged(values[0].doubleValue, kParamRadius);
    return YES;
  }
  if ([label isEqualToString:@"Crop"] && values.count >= 4) {
    [self _rdSetEnabled:@[
      @(kParamCropTop), @(kParamCropBottom), @(kParamCropLeft),
      @(kParamCropRight)
    ]
                 setAPI:setAPI];
    writeIfChanged(values[0].doubleValue, kParamCropTop);
    writeIfChanged(values[1].doubleValue, kParamCropBottom);
    writeIfChanged(values[2].doubleValue, kParamCropLeft);
    writeIfChanged(values[3].doubleValue, kParamCropRight);
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

- (void)setEditingDisabled:(BOOL)disabled
              forLaneLabel:(NSString *)label
                  groupKey:(NSString *)groupKey {
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

- (KKTimeline *)defaultTimelineAtTime:(CMTime)time
                          paramGetAPI:
                              (id<FxParameterRetrievalAPI_v6>)paramGetAPI {
  double radius = 0;
  [paramGetAPI getFloatValue:&radius fromParameter:kParamRadius atTime:time];
  KKLane *radiusLane = [KKLane laneWithLabel:@"Radius"];
  KKKeyPose *radiusKP = [KKKeyPose keyposeAtTime:0.0 values:@[ @(radius) ]];
  radiusKP.outgoing = nil;
  [radiusLane insertKeypose:radiusKP];

  double t = 0, b = 0, l = 0, r = 0;
  [paramGetAPI getFloatValue:&t fromParameter:kParamCropTop atTime:time];
  [paramGetAPI getFloatValue:&b fromParameter:kParamCropBottom atTime:time];
  [paramGetAPI getFloatValue:&l fromParameter:kParamCropLeft atTime:time];
  [paramGetAPI getFloatValue:&r fromParameter:kParamCropRight atTime:time];
  KKLane *cropLane = [KKLane laneWithLabel:@"Crop"];
  KKKeyPose *cropKP = [KKKeyPose keyposeAtTime:0.0
                                        values:@[ @(t), @(b), @(l), @(r) ]];
  cropKP.outgoing = nil;
  [cropLane insertKeypose:cropKP];

  KKTimeline *timeline = [KKTimeline timeline];
  timeline.lanes = @[ radiusLane, cropLane ];
  return timeline;
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
