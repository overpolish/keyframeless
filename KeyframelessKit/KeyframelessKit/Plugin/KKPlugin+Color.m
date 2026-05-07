/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../Math/KKGradientSampling.h"
#import "KKPlugin+Color.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKAlertView.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKGradientBarView.h>
#import <KeyframelessKit/KKGradientControl.h>
#import <KeyframelessKit/KKGradientFavoritesPopover.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>
#import <objc/runtime.h>

static const void *const kColorModesKey = &kColorModesKey;
static const void *const kGradientBarKey = &kGradientBarKey;
static const void *const kGradientFavPopoverKey = &kGradientFavPopoverKey;

static const FxParameterFlags kKKColorCustomUIBaseFlags =
    kFxParameterFlag_CUSTOM_UI;

static NSArray<NSNumber *> *_colorModes(KKPlugin *self) {
  return objc_getAssociatedObject([self class], kColorModesKey) ?: @[
    @(KKColorModeSolid), @(KKColorModeGradient), @(KKColorModeDynamic)
  ];
}

@implementation KKPlugin (Color)

- (BOOL)addColorParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                            modes:(NSArray<NSNumber *> *)modes
                            error:(NSError **)error {
  objc_setAssociatedObject([self class], kColorModesKey, modes,
                           OBJC_ASSOCIATION_COPY_NONATOMIC);

  if (![paramAPI
          addCustomParameterWithName:@""
                         parameterID:kKKParamColorGroup
                        defaultValue:@(kKKParamColorGroup)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH])
    return NO;

  if (![paramAPI addCustomParameterWithName:@""
                                parameterID:kKKParamColorExpanded
                               defaultValue:[KKDataBlob blobWithString:@"0"]
                             parameterFlags:kFxParameterFlag_HIDDEN |
                                            kFxParameterFlag_NOT_ANIMATABLE])
    return NO;

  BOOL hasSolid = [modes containsObject:@(KKColorModeSolid)];
  BOOL hasGradient = [modes containsObject:@(KKColorModeGradient)];

  if (modes.count > 1) {
    NSMutableArray *titles = [NSMutableArray new];
    for (NSNumber *m in modes) {
      switch (m.integerValue) {
      case KKColorModeSolid:
        [titles addObject:@"Solid"];
        break;
      case KKColorModeGradient:
        [titles addObject:@"Gradient"];
        break;
      case KKColorModeDynamic:
        [titles addObject:@"Dynamic"];
        break;
      }
    }
    if (![paramAPI addPopupMenuWithName:@"Color Mode"
                            parameterID:kKKParamColorMode
                           defaultValue:0
                            menuEntries:titles
                         parameterFlags:kFxParameterFlag_HIDDEN |
                                        kFxParameterFlag_NOT_ANIMATABLE])
      return NO;
  }

  if (hasSolid) {
    if (![paramAPI addColorParameterWithName:@"Color"
                                 parameterID:kKKParamColorSolid
                                  defaultRed:1.0
                                defaultGreen:1.0
                                 defaultBlue:1.0
                              parameterFlags:kFxParameterFlag_HIDDEN])
      return NO;
  }

  if (hasGradient) {
    // KKDataBlob custom param (was string param). Custom params route
    // through `setCustomParameterValue:atTime:` — same keyframe pipeline
    // as scalar animatable params — and ARE undoable. String param
    // writes are filtered off FCP's undo stack. See
    // project_kkdatablob_custom_param memory.
    NSString *defaultJSON = @"[{\"p\":0,\"r\":1,\"g\":1,\"b\":1},"
                            @"{\"p\":1,\"r\":1,\"g\":1,\"b\":1}]";
    if (![paramAPI
            addCustomParameterWithName:@"GradientData"
                           parameterID:kKKParamGradientData
                          defaultValue:[KKDataBlob blobWithString:defaultJSON]
                        parameterFlags:kFxParameterFlag_HIDDEN])
      return NO;

    if (![paramAPI addCustomParameterWithName:@"Gradient"
                                  parameterID:kKKParamColorCustomUI
                                 defaultValue:@(kKKParamColorCustomUI)
                               parameterFlags:kKKColorCustomUIBaseFlags |
                                              kFxParameterFlag_HIDDEN])
      return NO;
  }

  return YES;
}

- (KKColorMode)colorModeAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSArray<NSNumber *> *modes = _colorModes(self);
  if (!getAPI || modes.count <= 1)
    return (KKColorMode)modes.firstObject.integerValue;
  int idx = 0;
  [getAPI getIntValue:&idx fromParameter:kKKParamColorMode atTime:time];
  if (idx < 0 || idx >= (int)modes.count)
    return (KKColorMode)modes.firstObject.integerValue;
  return (KKColorMode)modes[idx].integerValue;
}

- (KKColorResult *)colorAtTime:(CMTime)renderTime {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI) {
    KKLogWarn(@"colorAtTime: paramGetAPI is nil");
    return [KKColorResult resultWithMode:KKColorModeSolid
                              solidColor:(simd_float3){1, 1, 1}];
  }

  NSArray<NSNumber *> *modes = _colorModes(self);
  int modeIndex = 0;
  if (modes.count > 1)
    [paramGetAPI getIntValue:&modeIndex
               fromParameter:kKKParamColorMode
                      atTime:renderTime];
  KKColorMode mode = (modeIndex >= 0 && modeIndex < (int)modes.count)
                         ? (KKColorMode)modes[modeIndex].integerValue
                         : (KKColorMode)modes.firstObject.integerValue;

  if (mode == KKColorModeGradient) {
    NSString *json = KKReadCustomParamString(paramGetAPI, kKKParamGradientData);
    NSArray<KKGradientStop *> *stops = KKGradientStopsFromJSON(json);
    simd_float3 lut[KK_GRADIENT_LUT_SIZE];
    if (stops.count >= 2) {
      KKGradientSampleStopsToLUT(stops, lut, KK_GRADIENT_LUT_SIZE);
    } else {
      for (int i = 0; i < KK_GRADIENT_LUT_SIZE; i++)
        lut[i] = (simd_float3){1, 1, 1};
    }
    return [KKColorResult resultWithGradientLUT:lut];
  }

  double r = 1, g = 1, b = 1;
  if (mode == KKColorModeSolid) {
    [paramGetAPI getRedValue:&r
                  greenValue:&g
                   blueValue:&b
               fromParameter:kKKParamColorSolid
                      atTime:renderTime];
  }

  return [KKColorResult
      resultWithMode:mode
          solidColor:(simd_float3){(float)r, (float)g, (float)b}];
}

- (void)updateColorParameterVisibility {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  NSArray<NSNumber *> *modes = _colorModes(self);
  if (modes.count <= 1)
    return;

  FxParameterFlags modeFlags = 0;
  [paramGetAPI getParameterFlags:&modeFlags fromParameter:kKKParamColorMode];
  if (modeFlags != kFxParameterFlag_NOT_ANIMATABLE)
    [paramSetAPI setParameterFlags:kFxParameterFlag_NOT_ANIMATABLE
                       toParameter:kKKParamColorMode];

  int modeIndex = 0;
  [paramGetAPI getIntValue:&modeIndex
             fromParameter:kKKParamColorMode
                    atTime:kCMTimeZero];
  KKColorMode mode = (modeIndex >= 0 && modeIndex < (int)modes.count)
                         ? (KKColorMode)modes[modeIndex].integerValue
                         : (KKColorMode)modes.firstObject.integerValue;

  BOOL hasSolid = [modes containsObject:@(KKColorModeSolid)];
  BOOL hasGradient = [modes containsObject:@(KKColorModeGradient)];

  if (hasSolid) {
    FxParameterFlags want = (mode == KKColorModeSolid)
                                ? kFxParameterFlag_DEFAULT
                                : kFxParameterFlag_HIDDEN;
    FxParameterFlags cur = 0;
    [paramGetAPI getParameterFlags:&cur fromParameter:kKKParamColorSolid];
    if (cur != want)
      [paramSetAPI setParameterFlags:want toParameter:kKKParamColorSolid];
  }

  if (hasGradient) {
    FxParameterFlags want =
        kKKColorCustomUIBaseFlags |
        ((mode == KKColorModeGradient) ? 0 : kFxParameterFlag_HIDDEN);
    FxParameterFlags cur = 0;
    [paramGetAPI getParameterFlags:&cur fromParameter:kKKParamColorCustomUI];
    if (cur != want)
      [paramSetAPI setParameterFlags:want toParameter:kKKParamColorCustomUI];
  }
}

- (NSView *)_createColorCustomUI:(UInt32)parameterID {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *gradientJson =
      KKReadCustomParamString(paramGetAPI, kKKParamGradientData);
  KKPluginInstanceState *instanceState =
      KKInstanceStateEnsureForAPI(self.apiManager);
  [actionAPI endAction:self];

  KKGradientControl *control =
      [[KKGradientControl alloc] initWithFrame:NSMakeRect(0, 0, 200, 36)];
  NSArray<KKGradientStop *> *stops = KKGradientStopsFromJSON(gradientJson);
  if (stops)
    control.stops = stops;

  instanceState.gradientControl = control;
  instanceState.gradientJSONSnapshot = gradientJson;

  __weak typeof(self) weakSelf = self;
  control.onStopsChanged = ^(NSArray<KKGradientStop *> *newStops) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    NSString *json = KKGradientJSONFromStops(newStops);
    if (!json)
      return;
    KKPluginInstanceState *s = KKInstanceStateForAPI(strongSelf.apiManager);
    s.gradientJSONSnapshot = json;
    BOOL inDrag = strongSelf.gradientDragUndoActive;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!inDrag)
      [actAPI startAction:strongSelf];
    BOOL ug =
        inDrag ? NO : KKBeginUndoGroup(strongSelf.apiManager, @"Edit Gradient");
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    KKWriteCustomParamString(setAPI, json, kKKParamGradientData);
    if (!inDrag) {
      KKEndUndoGroup(strongSelf.apiManager, ug);
      [actAPI endAction:strongSelf];
    }
  };

  control.onDragBegin = ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || strongSelf.gradientDragUndoActive)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!actAPI)
      return;
    [actAPI startAction:strongSelf];
    KKBeginUndoGroup(strongSelf.apiManager, @"Edit Gradient");
    strongSelf.gradientDragUndoActive = YES;
  };
  control.onDragEnd = ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.gradientDragUndoActive)
      return;
    KKEndUndoGroup(strongSelf.apiManager, YES);
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI endAction:strongSelf];
    strongSelf.gradientDragUndoActive = NO;
  };

  return control;
}

+ (void)colorSyncFromParams:(id<PROAPIAccessing>)apiManager {
  KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
  KKGradientControl *control = state.gradientControl;
  if (!control)
    return;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return;
  NSString *json = KKReadCustomParamString(getAPI, kKKParamGradientData);
  if (!json)
    return;
  if ([json isEqualToString:state.gradientJSONSnapshot])
    return;
  NSArray<KKGradientStop *> *stops = KKGradientStopsFromJSON(json);
  if (!stops)
    return;
  state.gradientJSONSnapshot = json;
  dispatch_async(dispatch_get_main_queue(), ^{
    control.stops = stops;
  });
}

@end
