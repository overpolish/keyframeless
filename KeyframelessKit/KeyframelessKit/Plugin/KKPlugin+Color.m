/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../Math/KKGradientSampling.h"
#import "../Views/KKAnimatableProperty.h"
#import "KKPlugin+Color.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKAlertView.h>
#import <KeyframelessKit/KKGradientBarView.h>
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

  if (![paramAPI addToggleButtonWithName:@""
                             parameterID:kKKParamColorExpanded
                            defaultValue:NO
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
    if (![paramAPI
            addStringParameterWithName:@"GradientData"
                           parameterID:kKKParamGradientData
                          defaultValue:@"[{\"p\":0,\"r\":1,\"g\":1,\"b\":1},"
                                       @"{\"p\":1,\"r\":1,\"g\":1,\"b\":1}]"
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
    NSString *json = nil;
    [paramGetAPI getStringParameterValue:&json
                           fromParameter:kKKParamGradientData];
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
  NSString *gradientJson = nil;
  [paramGetAPI getStringParameterValue:&gradientJson
                         fromParameter:kKKParamGradientData];
  [actionAPI endAction:self];

  CGFloat rowH = 36;
  NSView *container =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, rowH)];
  container.autoresizingMask = NSViewWidthSizable;

  KKGradientBarView *bar = [[KKGradientBarView alloc] initWithFrame:NSZeroRect];
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  NSArray<KKGradientStop *> *stops = KKGradientStopsFromJSON(gradientJson);
  if (stops)
    bar.stops = stops;
  objc_setAssociatedObject([self class], kGradientBarKey, bar,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  // Ensure the UUID exists — the timing-UI creation path normally generates
  // it, but the color custom UI can be mounted first on some inspector
  // layouts. Without a UUID, `state` would be nil and the bar would never
  // register, causing live updates to silently fail until a remount.
  id<FxCustomParameterActionAPI_v4> registerAction =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [registerAction startAction:self];
  KKPluginInstanceState *instanceState =
      KKInstanceStateEnsureForAPI(self.apiManager);
  [registerAction endAction:self];
  instanceState.gradientBar = bar;
  instanceState.gradientJSONSnapshot = gradientJson;

  NSImageSymbolConfiguration *starCfg = [NSImageSymbolConfiguration
      configurationWithPointSize:10.0
                          weight:NSFontWeightRegular];
  NSImage *starImg = [[NSImage imageWithSystemSymbolName:@"star"
                                accessibilityDescription:@"Favorites"]
      imageWithSymbolConfiguration:starCfg];
  NSButton *starBtn =
      [NSButton buttonWithImage:starImg
                         target:self
                         action:@selector(_kkGradientFavTapped:)];
  starBtn.bordered = NO;
  starBtn.contentTintColor =
      [NSColor.inspectorLabel colorWithAlphaComponent:0.5];
  starBtn.translatesAutoresizingMaskIntoConstraints = NO;

  KKGradientFavoritesPopover *favPopover =
      [[KKGradientFavoritesPopover alloc] init];
  favPopover.currentStops = bar.stops;
  objc_setAssociatedObject([self class], kGradientFavPopoverKey, favPopover,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  NSImage *reverseImg =
      [[NSImage imageWithSystemSymbolName:@"arrow.left.and.right"
                 accessibilityDescription:@"Reverse"]
          imageWithSymbolConfiguration:starCfg];
  NSButton *reverseBtn =
      [NSButton buttonWithImage:reverseImg
                         target:self
                         action:@selector(_kkGradientReverseTapped:)];
  reverseBtn.bordered = NO;
  reverseBtn.contentTintColor =
      [NSColor.inspectorLabel colorWithAlphaComponent:0.5];
  reverseBtn.translatesAutoresizingMaskIntoConstraints = NO;

  NSImage *distributeImg =
      [[NSImage imageWithSystemSymbolName:@"rectangle.split.3x1"
                 accessibilityDescription:@"Distribute"]
          imageWithSymbolConfiguration:starCfg];
  NSButton *distributeBtn =
      [NSButton buttonWithImage:distributeImg
                         target:self
                         action:@selector(_kkGradientDistributeTapped:)];
  distributeBtn.bordered = NO;
  distributeBtn.contentTintColor =
      [NSColor.inspectorLabel colorWithAlphaComponent:0.5];
  distributeBtn.translatesAutoresizingMaskIntoConstraints = NO;

  [container addSubview:bar];
  [container addSubview:starBtn];
  [container addSubview:reverseBtn];
  [container addSubview:distributeBtn];
  [NSLayoutConstraint activateConstraints:@[
    [starBtn.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
    [starBtn.topAnchor constraintEqualToAnchor:bar.topAnchor constant:5.0],
    [starBtn.widthAnchor constraintEqualToConstant:16.0],
    [starBtn.heightAnchor constraintEqualToConstant:16.0],

    [bar.leadingAnchor constraintEqualToAnchor:starBtn.trailingAnchor
                                      constant:KKSpacingSM],
    [bar.trailingAnchor constraintEqualToAnchor:reverseBtn.leadingAnchor
                                       constant:-KKSpacingSM],
    [bar.topAnchor constraintEqualToAnchor:container.topAnchor],
    [bar.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],

    [reverseBtn.trailingAnchor
        constraintEqualToAnchor:distributeBtn.leadingAnchor
                       constant:-KKSpacingSM],
    [reverseBtn.topAnchor constraintEqualToAnchor:bar.topAnchor constant:5.0],
    [reverseBtn.widthAnchor constraintEqualToConstant:16.0],
    [reverseBtn.heightAnchor constraintEqualToConstant:16.0],

    [distributeBtn.trailingAnchor
        constraintEqualToAnchor:container.trailingAnchor],
    [distributeBtn.topAnchor constraintEqualToAnchor:bar.topAnchor
                                            constant:5.0],
    [distributeBtn.widthAnchor constraintEqualToConstant:16.0],
    [distributeBtn.heightAnchor constraintEqualToConstant:16.0],
  ]];

  __weak typeof(self) weakSelf = self;
  bar.onStopsChanged = ^(NSArray<KKGradientStop *> *newStops) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    NSString *json = KKGradientJSONFromStops(newStops);
    if (!json)
      return;
    KKGradientFavoritesPopover *fp =
        objc_getAssociatedObject([strongSelf class], kGradientFavPopoverKey);
    fp.currentStops = newStops;
    KKPluginInstanceState *s = KKInstanceStateForAPI(strongSelf.apiManager);
    s.gradientJSONSnapshot = json;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setStringParameterValue:json toParameter:kKKParamGradientData];
    [actAPI endAction:strongSelf];
  };

  favPopover.onApplyFavorite = ^(NSArray<KKGradientStop *> *newStops) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    KKGradientBarView *b =
        objc_getAssociatedObject([strongSelf class], kGradientBarKey);
    b.stops = newStops;
    KKGradientFavoritesPopover *fp =
        objc_getAssociatedObject([strongSelf class], kGradientFavPopoverKey);
    fp.currentStops = newStops;
    NSString *json = KKGradientJSONFromStops(newStops);
    if (!json)
      return;
    KKPluginInstanceState *s = KKInstanceStateForAPI(strongSelf.apiManager);
    s.gradientJSONSnapshot = json;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setStringParameterValue:json toParameter:kKKParamGradientData];
    [actAPI endAction:strongSelf];
  };

  return container;
}

- (void)_kkGradientFavTapped:(NSButton *)sender {
  KKGradientFavoritesPopover *favPopover =
      objc_getAssociatedObject([self class], kGradientFavPopoverKey);
  if (!favPopover)
    return;
  [favPopover showRelativeToRect:sender.bounds ofView:sender];
}

- (void)_kkGradientReverseTapped:(NSButton *)sender {
  KKGradientBarView *bar =
      objc_getAssociatedObject([self class], kGradientBarKey);
  [bar reverseStops];
}

- (void)_kkGradientDistributeTapped:(NSButton *)sender {
  KKGradientBarView *bar =
      objc_getAssociatedObject([self class], kGradientBarKey);
  [bar distributeStopsEvenly];
}

+ (void)colorPushGradientForProperty:(KKAnimatableProperty *)prop
                              values:(NSArray<NSNumber *> *)flatValues
                          apiManager:(id<PROAPIAccessing>)apiManager {
  BOOL isGradient = NO;
  for (NSNumber *k in prop.valueParamKinds) {
    if (k.integerValue == KKAnimatableParamKindGradient) {
      isGradient = YES;
      break;
    }
  }
  if (!isGradient)
    return;
  KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
  KKGradientBarView *bar = state.gradientBar;
  if (!bar)
    return;
  NSArray<KKGradientStop *> *stops = KKGradientStopsFromFlat(flatValues);
  if (!stops)
    return;
  state.gradientJSONSnapshot = KKGradientJSONFromStops(stops);
  Class klass = [self class];
  dispatch_async(dispatch_get_main_queue(), ^{
    bar.stops = stops;
    KKGradientFavoritesPopover *fp =
        objc_getAssociatedObject(klass, kGradientFavPopoverKey);
    fp.currentStops = stops;
  });
}

+ (void)colorSyncFromParams:(id<PROAPIAccessing>)apiManager {
  KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
  KKGradientBarView *bar = state.gradientBar;
  if (!bar)
    return;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return;
  NSString *json = nil;
  [getAPI getStringParameterValue:&json fromParameter:kKKParamGradientData];
  if (!json)
    return;
  if ([json isEqualToString:state.gradientJSONSnapshot])
    return;
  NSArray<KKGradientStop *> *stops = KKGradientStopsFromJSON(json);
  if (!stops)
    return;
  state.gradientJSONSnapshot = json;
  dispatch_async(dispatch_get_main_queue(), ^{
    bar.stops = stops;
    KKGradientFavoritesPopover *fp =
        objc_getAssociatedObject([self class], kGradientFavPopoverKey);
    fp.currentStops = stops;
  });
}

@end
