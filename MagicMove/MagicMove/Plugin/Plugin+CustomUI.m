/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/NSView.h>
#import <KeyframelessKit/KeyframelessKit.h>

@implementation MagicMovePlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSC {
  return [NSSet setWithObjects:@"Position", @"Scale", @"Rot Z", @"Rot X",
                               @"Rot Y", @"Opacity", nil];
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSCDefaultOff {
  return [NSSet setWithObjects:@"Rot X", @"Rot Y", nil];
}

/// Maps lane label → (paramID, isBool) so apply/read/disable can iterate.
/// Bool entries are skipped by `setEditingDisabled:` (per-segment toggles
/// stay editable even when surrounding lane is HTH-disabled).
- (NSArray<NSDictionary *> *)_mmParamMappingForLabel:(NSString *)label {
  if ([label isEqualToString:@"Position"])
    return @[
      @{@"pid" : @(kParamPoint), @"bool" : @NO},
      @{@"pid" : @(kParamRotateWithMotion), @"bool" : @YES},
    ];
  if ([label isEqualToString:@"Scale"])
    return @[
      @{@"pid" : @(kParamScale), @"bool" : @NO},
      @{@"pid" : @(kParamScaleY), @"bool" : @NO},
    ];
  if ([label isEqualToString:@"Rot Z"])
    return @[ @{@"pid" : @(kParamRotation), @"bool" : @NO} ];
  if ([label isEqualToString:@"Rot X"])
    return @[ @{@"pid" : @(kParamRotationX), @"bool" : @NO} ];
  if ([label isEqualToString:@"Rot Y"])
    return @[ @{@"pid" : @(kParamRotationY), @"bool" : @NO} ];
  if ([label isEqualToString:@"Opacity"])
    return @[ @{@"pid" : @(kParamOpacity), @"bool" : @NO} ];
  return nil;
}

- (NSArray<NSNumber *> *)currentValuesForLaneLabel:(NSString *)label
                                          groupKey:(NSString *)groupKey
                                            atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return nil;
  if ([label isEqualToString:@"Position"]) {
    double x = 0, y = 0;
    [getAPI getXValue:&x YValue:&y fromParameter:kParamPoint atTime:time];
    BOOL rwm = NO;
    [getAPI getBoolValue:&rwm fromParameter:kParamRotateWithMotion atTime:time];
    return @[ @(x), @(y), @(rwm ? 1.0 : 0.0) ];
  }
  if ([label isEqualToString:@"Scale"]) {
    double sx = 1, sy = 1;
    [getAPI getFloatValue:&sx fromParameter:kParamScale atTime:time];
    [getAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
    return @[ @(sx), @(sy) ];
  }
  if ([label isEqualToString:@"Rot Z"] || [label isEqualToString:@"Rot X"] ||
      [label isEqualToString:@"Rot Y"] || [label isEqualToString:@"Opacity"]) {
    UInt32 pid =
        [(NSNumber *)[self _mmParamMappingForLabel:label].firstObject[@"pid"]
            unsignedIntValue];
    double v = 0;
    [getAPI getFloatValue:&v fromParameter:pid atTime:time];
    return @[ @(v) ];
  }
  return nil;
}

- (BOOL)applyLaneValues:(NSArray<NSNumber *> *)values
               forLabel:(NSString *)label
               groupKey:(NSString *)groupKey
                 atTime:(CMTime)time {
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI)
    return NO;
  [self setEditingDisabled:NO forLaneLabel:label groupKey:groupKey];
  if ([label isEqualToString:@"Position"] && values.count >= 3) {
    [setAPI setXValue:values[0].doubleValue
               YValue:values[1].doubleValue
          toParameter:kParamPoint
               atTime:time];
    [setAPI setBoolValue:values[2].doubleValue >= 0.5
             toParameter:kParamRotateWithMotion
                  atTime:time];
    return YES;
  }
  if ([label isEqualToString:@"Scale"] && values.count >= 2) {
    [setAPI setFloatValue:values[0].doubleValue
              toParameter:kParamScale
                   atTime:time];
    [setAPI setFloatValue:values[1].doubleValue
              toParameter:kParamScaleY
                   atTime:time];
    return YES;
  }
  if (([label isEqualToString:@"Rot Z"] || [label isEqualToString:@"Rot X"] ||
       [label isEqualToString:@"Rot Y"] ||
       [label isEqualToString:@"Opacity"]) &&
      values.count >= 1) {
    UInt32 pid =
        [(NSNumber *)[self _mmParamMappingForLabel:label].firstObject[@"pid"]
            unsignedIntValue];
    [setAPI setFloatValue:values[0].doubleValue toParameter:pid atTime:time];
    return YES;
  }
  return NO;
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
  for (NSDictionary *entry in [self _mmParamMappingForLabel:label]) {
    if ([entry[@"bool"] boolValue])
      continue;
    UInt32 pid = [entry[@"pid"] unsignedIntValue];
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

  double px = 0.5, py = 0.5;
  [paramGetAPI getXValue:&px YValue:&py fromParameter:kParamPoint atTime:time];
  BOOL rwm = NO;
  [paramGetAPI getBoolValue:&rwm
              fromParameter:kParamRotateWithMotion
                     atTime:time];
  KKTimingLane *posLane =
      [KKTimingLane defaultLaneForLabel:@"Position"
                             baseValues:@[ @(px), @(py), @(rwm ? 1.0 : 0.0) ]];
  posLane.valueComponentKinds =
      @[ @(KKAnimatableParamKindPoint), @(KKAnimatableParamKindBool) ];
  posLane.hasOSC = YES;
  [out addObject:posLane];

  double sx = 1, sy = 1;
  [paramGetAPI getFloatValue:&sx fromParameter:kParamScale atTime:time];
  [paramGetAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
  KKTimingLane *scaleLane =
      [KKTimingLane defaultLaneForLabel:@"Scale" baseValues:@[ @(sx), @(sy) ]];
  scaleLane.valueComponentKinds =
      @[ @(KKAnimatableParamKindFloat), @(KKAnimatableParamKindFloat) ];
  scaleLane.hasOSC = YES;
  [out addObject:scaleLane];

  struct {
    NSString *label;
    UInt32 pid;
  } rots[] = {
      {@"Rot Z", kParamRotation},
      {@"Rot X", kParamRotationX},
      {@"Rot Y", kParamRotationY},
  };
  NSSet<NSString *> *oscOff = [self animatablePropertyLabelsWithOSCDefaultOff];
  for (size_t i = 0; i < sizeof(rots) / sizeof(rots[0]); i++) {
    double v = 0;
    [paramGetAPI getFloatValue:&v fromParameter:rots[i].pid atTime:time];
    KKTimingLane *lane = [KKTimingLane defaultLaneForLabel:rots[i].label
                                                baseValues:@[ @(v) ]];
    lane.valueComponentKinds = @[ @(KKAnimatableParamKindFloat) ];
    lane.hasOSC = YES;
    if ([oscOff containsObject:rots[i].label])
      lane.oscVisible = NO;
    [out addObject:lane];
  }

  double op = 1;
  [paramGetAPI getFloatValue:&op fromParameter:kParamOpacity atTime:time];
  KKTimingLane *opLane = [KKTimingLane defaultLaneForLabel:@"Opacity"
                                                baseValues:@[ @(op) ]];
  opLane.valueComponentKinds = @[ @(KKAnimatableParamKindFloat) ];
  opLane.hasOSC = YES;
  [out addObject:opLane];

  return out;
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

- (NSArray<KKHelpSection *> *)helpSections {
  KKHelpSection *magicMove = [KKHelpSection
      sectionWithTitle:@"Magic Move"
             tipMarkup:@[
               (@"<accent>Position</accent>, <accent>Scale</accent>, "
                @"<accent>Rotation</accent>, and <accent>Opacity</accent> "
                @"all animate from the clip's natural state to the values "
                @"set here - drive each one on canvas via the "
                @"<symbol arcade.stick.console.fill /> on-screen control."),
               (@"<accent>Anchor Point</accent> sets the pivot rotations "
                @"and scale swing around."),
               (@"Toggle <accent>Rotate with Motion</accent> to align the "
                @"clip's heading with its motion path."),
               (@"<symbol squareshape.fill color=white /> on the canvas "
                @"toggles Scale between 0% and 100%; "
                @"<symbol circle.fill color=white /> on the canvas "
                @"toggles Opacity between 0% and 100%."),
               (@"When the Position lane has multiple segments a bezier "
                @"<accent>path</accent> draws between them on canvas - "
                @"reshape it by dragging anchors or their handles."),
             ]
             shortcuts:@[
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + drag"
                               descMarkup:@"Constrain motion to X or Y axis"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌃</kbd> + drag"
                                           descMarkup:@"Disable snapping"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌥</kbd>"
                               descMarkup:@"Reveal X and Y rotation rings"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + scale"
                               descMarkup:@"Lock scale to X or Y axis"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"Double-click scale ring"
                                           descMarkup:@"Reset to 1:1"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"Double-click path anchor"
                               descMarkup:@"Toggle between smooth and corner"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click "
                                                      @"path anchor"
                                           descMarkup:@"Delete the anchor"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click "
                                                      @"path curve"
                                           descMarkup:@"Insert a new anchor "
                                                      @"at the nearest spot"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + drag "
                                                      @"handle"
                                           descMarkup:@"Break handle "
                                                      @"symmetry (move "
                                                      @"independently)"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click Scale slider"
                               descMarkup:@"Match X and Y scale values"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌘</kbd> + drag Scale slider"
                               descMarkup:@"Maintain X:Y aspect ratio"],
             ]];
  magicMove.icon =
      [NSImage imageWithSystemSymbolName:@"circle.dotted.and.circle"
                accessibilityDescription:nil];
  return @[ magicMove ];
}

- (KKClipWrappingMode)clipWrappingMode {
  return KKClipWrappingModeCompound;
}

@end
