/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKMarkup.h>
#import <objc/message.h>

@interface KKPlugin (TimingGraph)
- (void)timingGraphApplyState;
@end

@implementation GlowPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSC {
  return [NSSet setWithObjects:@"Radius", @"Position", nil];
}

/// Returns the FxPlug param IDs that back the lane labeled `label`. Used by
/// the apply / read / disable hooks. Order matches the lane's value layout.
- (NSArray<NSNumber *> *)_glParamIDsForLabel:(NSString *)label {
  if ([label isEqualToString:@"Radius"])
    return @[ @(kParamRadiusX), @(kParamRadiusY) ];
  if ([label isEqualToString:@"Intensity"])
    return @[ @(kParamIntensity) ];
  if ([label isEqualToString:@"Falloff"])
    return @[ @(kParamFalloff) ];
  if ([label isEqualToString:@"Noise"])
    return @[ @(kParamNoise) ];
  if ([label isEqualToString:@"Position"])
    return @[ @(kParamPosition) ];
  if ([label isEqualToString:@"Color"])
    return @[ @(kKKParamColorSolid) ];
  if ([label isEqualToString:@"Gradient"])
    return @[ @(kKKParamGradientData) ];
  if ([label isEqualToString:@"N. Offset"])
    return @[ @(kParamNoiseOffset) ];
  return nil;
}

- (NSArray<NSNumber *> *)currentValuesForLaneLabel:(NSString *)label
                                            atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return nil;
  if ([label isEqualToString:@"Radius"]) {
    double x = 0, y = 0;
    [getAPI getFloatValue:&x fromParameter:kParamRadiusX atTime:time];
    [getAPI getFloatValue:&y fromParameter:kParamRadiusY atTime:time];
    return @[ @(x), @(y) ];
  }
  if ([label isEqualToString:@"Intensity"] ||
      [label isEqualToString:@"Falloff"] || [label isEqualToString:@"Noise"] ||
      [label isEqualToString:@"N. Offset"]) {
    UInt32 pid = [self _glParamIDsForLabel:label].firstObject.unsignedIntValue;
    double v = 0;
    [getAPI getFloatValue:&v fromParameter:pid atTime:time];
    return @[ @(v) ];
  }
  if ([label isEqualToString:@"Position"]) {
    double x = 0, y = 0;
    [getAPI getXValue:&x YValue:&y fromParameter:kParamPosition atTime:time];
    return @[ @(x), @(y) ];
  }
  if ([label isEqualToString:@"Color"]) {
    double r = 0, g = 0, b = 0;
    [getAPI getRedValue:&r
             greenValue:&g
              blueValue:&b
          fromParameter:kKKParamColorSolid
                 atTime:time];
    return @[ @(r), @(g), @(b) ];
  }
  if ([label isEqualToString:@"Gradient"]) {
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamGradientData];
    NSArray<KKGradientStop *> *stops = KKGradientStopsFromJSON(json);
    return stops ? KKGradientFlatFromStops(stops) : @[];
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
  [self setEditingDisabled:NO forLaneLabel:label];
  if ([label isEqualToString:@"Radius"] && values.count >= 2) {
    [setAPI setFloatValue:values[0].doubleValue
              toParameter:kParamRadiusX
                   atTime:time];
    [setAPI setFloatValue:values[1].doubleValue
              toParameter:kParamRadiusY
                   atTime:time];
    return YES;
  }
  if (([label isEqualToString:@"Intensity"] ||
       [label isEqualToString:@"Falloff"] || [label isEqualToString:@"Noise"] ||
       [label isEqualToString:@"N. Offset"]) &&
      values.count >= 1) {
    UInt32 pid = [self _glParamIDsForLabel:label].firstObject.unsignedIntValue;
    [setAPI setFloatValue:values[0].doubleValue toParameter:pid atTime:time];
    return YES;
  }
  if ([label isEqualToString:@"Position"] && values.count >= 2) {
    [setAPI setXValue:values[0].doubleValue
               YValue:values[1].doubleValue
          toParameter:kParamPosition
               atTime:time];
    return YES;
  }
  if ([label isEqualToString:@"Color"] && values.count >= 3) {
    [setAPI setRedValue:values[0].doubleValue
             greenValue:values[1].doubleValue
              blueValue:values[2].doubleValue
            toParameter:kKKParamColorSolid
                 atTime:time];
    return YES;
  }
  if ([label isEqualToString:@"Gradient"]) {
    NSArray<KKGradientStop *> *stops = KKGradientStopsFromFlat(values);
    if (!stops)
      return NO;
    NSString *json = KKGradientJSONFromStops(stops);
    if (json)
      [setAPI setStringParameterValue:json toParameter:kKKParamGradientData];
    KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
    KKGradientControl *control = state.gradientControl;
    if (control) {
      state.gradientJSONSnapshot = json;
      dispatch_async(dispatch_get_main_queue(), ^{
        control.stops = stops;
      });
    }
    return YES;
  }
  return NO;
}

- (void)setEditingDisabled:(BOOL)disabled forLaneLabel:(NSString *)label {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!getAPI || !setAPI)
    return;
  for (NSNumber *p in [self _glParamIDsForLabel:label]) {
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
  NSMutableArray<KKTimingLane *> *out = [NSMutableArray array];

  double rx = 0, ry = 0;
  [paramGetAPI getFloatValue:&rx fromParameter:kParamRadiusX atTime:time];
  [paramGetAPI getFloatValue:&ry fromParameter:kParamRadiusY atTime:time];
  KKTimingLane *radius = [KKTimingLane defaultLaneForLabel:@"Radius"
                                                baseValues:@[ @(rx), @(ry) ]];
  radius.valueComponentKinds =
      @[ @(KKAnimatableParamKindFloat), @(KKAnimatableParamKindFloat) ];
  radius.hasOSC = YES;
  [out addObject:radius];

  double intensity = 0;
  [paramGetAPI getFloatValue:&intensity
               fromParameter:kParamIntensity
                      atTime:time];
  KKTimingLane *intLane = [KKTimingLane defaultLaneForLabel:@"Intensity"
                                                 baseValues:@[ @(intensity) ]];
  intLane.valueComponentKinds = @[ @(KKAnimatableParamKindFloat) ];
  [out addObject:intLane];

  double falloff = 0;
  [paramGetAPI getFloatValue:&falloff fromParameter:kParamFalloff atTime:time];
  KKTimingLane *falloffLane =
      [KKTimingLane defaultLaneForLabel:@"Falloff" baseValues:@[ @(falloff) ]];
  falloffLane.valueComponentKinds = @[ @(KKAnimatableParamKindFloat) ];
  [out addObject:falloffLane];

  double noise = 0;
  [paramGetAPI getFloatValue:&noise fromParameter:kParamNoise atTime:time];
  KKTimingLane *noiseLane = [KKTimingLane defaultLaneForLabel:@"Noise"
                                                   baseValues:@[ @(noise) ]];
  noiseLane.valueComponentKinds = @[ @(KKAnimatableParamKindFloat) ];
  [out addObject:noiseLane];

  double px = 0.5, py = 0.5;
  [paramGetAPI getXValue:&px
                  YValue:&py
           fromParameter:kParamPosition
                  atTime:time];
  KKTimingLane *posLane = [KKTimingLane defaultLaneForLabel:@"Position"
                                                 baseValues:@[ @(px), @(py) ]];
  posLane.valueComponentKinds = @[ @(KKAnimatableParamKindPoint) ];
  posLane.hasOSC = YES;
  [out addObject:posLane];

  double r = 1, g = 1, b = 1;
  [paramGetAPI getRedValue:&r
                greenValue:&g
                 blueValue:&b
             fromParameter:kKKParamColorSolid
                    atTime:time];
  KKTimingLane *colorLane =
      [KKTimingLane defaultLaneForLabel:@"Color"
                             baseValues:@[ @(r), @(g), @(b) ]];
  colorLane.valueComponentKinds = @[ @(KKAnimatableParamKindColor) ];
  [out addObject:colorLane];

  NSString *gradJSON = nil;
  [paramGetAPI getStringParameterValue:&gradJSON
                         fromParameter:kKKParamGradientData];
  NSArray<KKGradientStop *> *stops = KKGradientStopsFromJSON(gradJSON);
  NSArray<NSNumber *> *gradFlat = stops ? KKGradientFlatFromStops(stops) : @[];
  KKTimingLane *gradLane = [KKTimingLane defaultLaneForLabel:@"Gradient"
                                                  baseValues:gradFlat];
  gradLane.valueComponentKinds = @[ @(KKAnimatableParamKindGradient) ];
  [out addObject:gradLane];

  double noff = 0;
  [paramGetAPI getFloatValue:&noff fromParameter:kParamNoiseOffset atTime:time];
  KKTimingLane *noffLane = [KKTimingLane defaultLaneForLabel:@"N. Offset"
                                                  baseValues:@[ @(noff) ]];
  noffLane.valueComponentKinds = @[ @(KKAnimatableParamKindFloat) ];
  [out addObject:noffLane];

  return out;
}

- (NSSet<NSString *> *)hiddenAnimatablePropertyLabels {
  KKColorMode mode = [self colorModeAtTime:kCMTimeZero];
  NSMutableSet<NSString *> *hidden = [NSMutableSet set];
  // Color lane only makes sense in Solid mode; Gradient lane only in
  // Gradient mode. Dynamic mode hides both.
  if (mode != KKColorModeSolid)
    [hidden addObject:@"Color"];
  if (mode != KKColorModeGradient)
    [hidden addObject:@"Gradient"];
  return hidden;
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamNoiseGroup)
    return [self
        createGroupHeaderWithTitle:@"Noise"
                              icon:[NSImage
                                       imageWithSystemSymbolName:
                                           @"circle.bottomrighthalf.pattern"
                                           @".checkered"
                                        accessibilityDescription:nil]
                       parameterID:parameterID
                   expandedParamID:kParamNoiseExpanded];

  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

- (NSArray<KKHelpSection *> *)helpSections {
  KKHelpSection *glow = [KKHelpSection
      sectionWithTitle:@"Glow"
             tipMarkup:@[
               (@"<accent>Radius X / Y</accent> control how far the glow "
                @"spreads."),
               (@"<accent>Position</accent> moves where the glow appears - "
                @"move it via the "
                @"<symbol arcade.stick.console.fill /> on-screen control."),
               (@"<accent>Intensity</accent> is overall brightness; "
                @"<accent>Falloff</accent> shapes how sharply it fades to "
                @"the edge; <accent>Threshold</accent> makes the underlying "
                @"objects brighter."),
               (@"<accent>Color</accent> mode tints the glow: supports "
                @"Dynamic, Solid, and Gradient."),
               (@"The <accent>Noise</accent> group adds a flickering, "
                @"organic shimmer. <accent>Amount</accent> controls "
                @"strength; <accent>Speed</accent> animates it over time; "
                @"<accent>Offset</accent> shifts the noise field "
                @"(animatable for parallax-like motion)."),
             ]
             shortcuts:@[
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click Radius slider"
                               descMarkup:@"Match Radius X and Y values"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌘</kbd> + drag Radius slider"
                               descMarkup:@"Maintain Radius X:Y ratio"],
             ]];
  glow.icon = [NSImage imageWithSystemSymbolName:@"app.background.dotted"
                        accessibilityDescription:nil];
  return @[ glow ];
}

- (KKClipWrappingMode)clipWrappingMode {
  return KKClipWrappingModeAdjustmentOrCompound;
}

@end
