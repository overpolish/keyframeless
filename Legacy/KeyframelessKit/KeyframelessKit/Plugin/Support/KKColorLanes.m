/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKColorLanes.h"
#import "KKGradientBarView.h"
#import "KKGradientSampling.h"
#import "KKTimeline.h"
#import <AppKit/AppKit.h>

static NSString *_KKColorLabel(NSString *_Nullable baseName, NSString *suffix) {
  return baseName.length
             ? [NSString stringWithFormat:@"%@ %@", baseName, suffix]
             : suffix;
}

NSString *KKColorLanesModeLabel(NSString *baseName) {
  return _KKColorLabel(baseName, @"Mode");
}
NSString *KKColorLanesSolidLabel(NSString *baseName) {
  return _KKColorLabel(baseName, @"Solid");
}
NSString *KKColorLanesGradientLabel(NSString *baseName) {
  return _KKColorLabel(baseName, @"Gradient");
}

// Pill index of each mode given whether Dynamic is offered.
static NSInteger _KKSolidIndex(BOOL includesDynamic) {
  return includesDynamic ? 1 : 0;
}
static NSInteger _KKGradientIndex(BOOL includesDynamic) {
  return includesDynamic ? 2 : 1;
}

NSArray<KKLane *> *KKColorLanesMake(NSString *baseName, BOOL includesDynamic,
                                    BOOL animatable) {
  NSString *modeLabel = KKColorLanesModeLabel(baseName);

  // Mode: a structural enum pill (never animatable). Default 0 = Dynamic when
  // offered, else Solid.
  KKLane *mode = [KKLane laneWithKey:modeLabel label:modeLabel];
  mode.valueType = KKLaneValueTypeFloat;
  mode.integerValued = YES;
  mode.animatable = NO;
  mode.choiceLabels = includesDynamic ? @[ @"Dynamic", @"Solid", @"Gradient" ]
                                      : @[ @"Solid", @"Gradient" ];
  mode.componentMin = @[ @0.0 ];
  mode.componentMax = @[ @((double)(mode.choiceLabels.count - 1)) ];
  [mode insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]]];

  // Solid tint (sRGB [r,g,b,a]); shown only when Mode = Solid. Channel colours
  // tint the per-channel graph curves.
  KKLane *solid = [KKLane laneWithKey:KKColorLanesSolidLabel(baseName) label:KKColorLanesSolidLabel(baseName)];
  solid.valueType = KKLaneValueTypeColor;
  solid.componentMin = @[ @0.0, @0.0, @0.0, @0.0 ];
  solid.componentMax = @[ @1.0, @1.0, @1.0, @1.0 ];
  solid.animatable = animatable;
  solid.componentLabelColors = @[
    [NSColor colorWithSRGBRed:0.95 green:0.35 blue:0.35 alpha:1.0],
    [NSColor colorWithSRGBRed:0.40 green:0.85 blue:0.45 alpha:1.0],
    [NSColor colorWithSRGBRed:0.45 green:0.60 blue:0.95 alpha:1.0],
    [NSColor colorWithSRGBRed:0.70 green:0.70 blue:0.70 alpha:1.0],
  ];
  solid.visibleWhenKey = modeLabel;
  solid.visibleWhenValues = @[ @(_KKSolidIndex(includesDynamic)) ];
  [solid insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                         values:@[ @1.0, @1.0, @1.0, @1.0 ]]];

  // Gradient (composite [type, angle, <flat stops>]); shown only when Mode =
  // Gradient. Default white -> blue so it reads as a gradient out of the box.
  KKLane *gradient = [KKLane laneWithKey:KKColorLanesGradientLabel(baseName) label:KKColorLanesGradientLabel(baseName)];
  gradient.valueType = KKLaneValueTypeGradient;
  gradient.gradientShowsTypeAngle = YES;
  gradient.componentMin = @[];
  gradient.componentMax = @[];
  gradient.animatable = animatable;
  gradient.visibleWhenKey = modeLabel;
  gradient.visibleWhenValues = @[ @(_KKGradientIndex(includesDynamic)) ];
  NSArray<KKGradientStop *> *defStops = @[
    [KKGradientStop stopWithPosition:0.0
                               color:[NSColor colorWithSRGBRed:1.0
                                                         green:1.0
                                                          blue:1.0
                                                         alpha:1.0]],
    [KKGradientStop stopWithPosition:1.0
                               color:[NSColor colorWithSRGBRed:0.2
                                                         green:0.5
                                                          blue:1.0
                                                         alpha:1.0]]
  ];
  NSArray<NSNumber *> *gradDefault = [@[ @0.0, @0.0 ]
      arrayByAddingObjectsFromArray:KKGradientFlatFromStops(defStops)];
  [gradient insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:gradDefault]];

  return @[ mode, solid, gradient ];
}

KKColorLanesValue
KKColorLanesResolve(NSString *baseName, BOOL includesDynamic,
                    NSArray<NSNumber *> * (^valuesProvider)(NSString *label)) {
  KKColorLanesValue v;
  v.solidColor = (simd_float3){1.0f, 1.0f, 1.0f};
  v.gradientType = 0;
  v.gradientAngle = 0.0f;
  for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++)
    v.gradientLUT[i] = v.solidColor;

  NSArray<NSNumber *> *modeVals =
      valuesProvider(KKColorLanesModeLabel(baseName));
  NSInteger idx =
      modeVals.count >= 1 ? (NSInteger)llround(modeVals[0].doubleValue) : 0;
  if (includesDynamic)
    v.mode = idx == (NSInteger)_KKSolidIndex(YES)      ? KKColorModeSolid
             : idx == (NSInteger)_KKGradientIndex(YES) ? KKColorModeGradient
                                                       : KKColorModeDynamic;
  else
    v.mode = idx == (NSInteger)_KKGradientIndex(NO) ? KKColorModeGradient
                                                    : KKColorModeSolid;

  if (v.mode == KKColorModeSolid) {
    NSArray<NSNumber *> *s = valuesProvider(KKColorLanesSolidLabel(baseName));
    if (s.count >= 3)
      v.solidColor =
          (simd_float3){(float)s[0].doubleValue, (float)s[1].doubleValue,
                        (float)s[2].doubleValue};
  } else if (v.mode == KKColorModeGradient) {
    NSArray<NSNumber *> *g =
        valuesProvider(KKColorLanesGradientLabel(baseName));
    v.gradientType = g.count >= 1 ? (int)llround(g[0].doubleValue) : 0;
    v.gradientAngle =
        g.count >= 2 ? (float)(g[1].doubleValue * M_PI / 180.0) : 0.0f;
    NSArray<KKGradientStop *> *stops =
        g.count > 2 ? KKGradientStopsFromFlat(
                          [g subarrayWithRange:NSMakeRange(2, g.count - 2)])
                    : nil;
    if (stops)
      KKGradientSampleStopsToLUT(stops, v.gradientLUT, KK_GRADIENT_LUT_SIZE);
  }
  return v;
}
