/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKPlugin+Color.h"
#import "KKPlugin_Private.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKAlertView.h>
#import <KeyframelessKit/KKColorWellView.h>
#import <KeyframelessKit/KKGradientBarView.h>
#import <KeyframelessKit/KKGradientFavoritesPopover.h>
#import <KeyframelessKit/KKLabelView.h>
#import <KeyframelessKit/KKParameterRowView.h>
#import <KeyframelessKit/KKPopupSelectView.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>
#import <objc/runtime.h>

static const void *const kColorModesKey = &kColorModesKey;
static const void *const kColorWellKey = &kColorWellKey;
static const void *const kGradientBarKey = &kGradientBarKey;
static const void *const kColorModePopupKey = &kColorModePopupKey;
static const void *const kColorDynamicAlertKey = &kColorDynamicAlertKey;
static const void *const kColorRowKey = &kColorRowKey;
static const void *const kGradientFavPopoverKey = &kGradientFavPopoverKey;
static const void *const kGradientFavBtnKey = &kGradientFavBtnKey;

static NSArray<NSNumber *> *_colorModes(KKPlugin *self) {
  return objc_getAssociatedObject([self class], kColorModesKey)
             ?: @[ @(KKColorModeSolid) ];
}

static NSArray<KKGradientStop *> *_parseStops(NSString *json) {
  if (!json.length)
    return nil;
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  if (!data)
    return nil;
  NSArray *arr = [NSJSONSerialization JSONObjectWithData:data
                                                 options:0
                                                   error:nil];
  if (![arr isKindOfClass:[NSArray class]])
    return nil;
  NSMutableArray<KKGradientStop *> *stops = [NSMutableArray new];
  for (NSDictionary *d in arr) {
    if (![d isKindOfClass:[NSDictionary class]])
      continue;
    CGFloat midpoint = d[@"m"] ? [d[@"m"] doubleValue] : 0.5;
    [stops addObject:[KKGradientStop
                         stopWithPosition:[d[@"p"] doubleValue]
                                    color:[NSColor
                                              colorWithRed:[d[@"r"] doubleValue]
                                                     green:[d[@"g"] doubleValue]
                                                      blue:[d[@"b"] doubleValue]
                                                     alpha:1.0]
                                 midpoint:midpoint]];
  }
  return stops.count >= 2 ? stops : nil;
}

static NSString *_stopsToJSON(NSArray<KKGradientStop *> *stops) {
  NSMutableArray *arr = [NSMutableArray new];
  for (KKGradientStop *s in stops) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    NSColor *c = [s.color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (c)
      [c getRed:&r green:&g blue:&b alpha:&a];
    else
      [s.color getRed:&r green:&g blue:&b alpha:&a];
    [arr addObject:@{
      @"p" : @((double)s.position),
      @"r" : @((double)r),
      @"g" : @((double)g),
      @"b" : @((double)b),
      @"m" : @((double)s.midpoint)
    }];
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:arr
                                                 options:0
                                                   error:nil];
  if (!data)
    return nil;
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

@implementation KKPlugin (Color)

- (BOOL)addColorParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                            modes:(NSArray<NSNumber *> *)modes
                            error:(NSError **)error {
  objc_setAssociatedObject([self class], kColorModesKey, modes,
                           OBJC_ASSOCIATION_COPY_NONATOMIC);

  static const FxParameterFlags kCustomUI =
      kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_CUSTOM_UI |
      kFxParameterFlag_USE_FULL_VIEW_WIDTH;

  if (![paramAPI addCustomParameterWithName:@""
                                parameterID:kKKParamColorCustomUI
                               defaultValue:@(kKKParamColorCustomUI)
                             parameterFlags:kCustomUI])
    return NO;

  if (![paramAPI addIntSliderWithName:@""
                          parameterID:kKKParamColorMode
                         defaultValue:(int)modes.firstObject.integerValue
                         parameterMin:0
                         parameterMax:2
                            sliderMin:0
                            sliderMax:2
                                delta:1
                       parameterFlags:kFxParameterFlag_HIDDEN |
                                      kFxParameterFlag_NOT_ANIMATABLE])
    return NO;

  if (![paramAPI addFloatSliderWithName:@""
                            parameterID:kKKParamColorR
                           defaultValue:1.0
                           parameterMin:0.0
                           parameterMax:1.0
                              sliderMin:0.0
                              sliderMax:1.0
                                  delta:0.001
                         parameterFlags:kFxParameterFlag_HIDDEN |
                                        kFxParameterFlag_NOT_ANIMATABLE])
    return NO;

  if (![paramAPI addFloatSliderWithName:@""
                            parameterID:kKKParamColorG
                           defaultValue:1.0
                           parameterMin:0.0
                           parameterMax:1.0
                              sliderMin:0.0
                              sliderMax:1.0
                                  delta:0.001
                         parameterFlags:kFxParameterFlag_HIDDEN |
                                        kFxParameterFlag_NOT_ANIMATABLE])
    return NO;

  if (![paramAPI addFloatSliderWithName:@""
                            parameterID:kKKParamColorB
                           defaultValue:1.0
                           parameterMin:0.0
                           parameterMax:1.0
                              sliderMin:0.0
                              sliderMax:1.0
                                  delta:0.001
                         parameterFlags:kFxParameterFlag_HIDDEN |
                                        kFxParameterFlag_NOT_ANIMATABLE])
    return NO;

  if (![paramAPI
          addStringParameterWithName:@"GradientData"
                         parameterID:kKKParamGradientData
                        defaultValue:@"[{\"p\":0,\"r\":1,\"g\":1,\"b\":1},"
                                     @"{\"p\":1,\"r\":1,\"g\":1,\"b\":1}]"
                      parameterFlags:kFxParameterFlag_HIDDEN])
    return NO;

  return YES;
}

- (KKColorResult *)colorAtTime:(CMTime)renderTime {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

  int mode = KKColorModeSolid;
  double r = 1, g = 1, b = 1;
  [paramGetAPI getIntValue:&mode
             fromParameter:kKKParamColorMode
                    atTime:renderTime];
  [paramGetAPI getFloatValue:&r fromParameter:kKKParamColorR atTime:renderTime];
  [paramGetAPI getFloatValue:&g fromParameter:kKKParamColorG atTime:renderTime];
  [paramGetAPI getFloatValue:&b fromParameter:kKKParamColorB atTime:renderTime];

  NSArray<KKGradientStop *> *stops = @[];
  if (mode == KKColorModeGradient) {
    NSString *json = nil;
    [paramGetAPI getStringParameterValue:&json
                           fromParameter:kKKParamGradientData];
    stops = _parseStops(json) ?: @[];
  }

  return
      [KKColorResult resultWithMode:(KKColorMode)mode
                         solidColor:(simd_float3){(float)r, (float)g, (float)b}
                      gradientStops:stops];
}

- (void)updateColorParameterVisibility {
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  UInt32 hidden[] = {kKKParamColorMode, kKKParamColorR, kKKParamColorG,
                     kKKParamColorB, kKKParamGradientData};
  for (int i = 0; i < 5; i++)
    [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                       toParameter:hidden[i]];
}

- (NSView *)_createColorCustomUI:(UInt32)parameterID {
  NSArray<NSNumber *> *modes = _colorModes(self);
  BOOL hasMultipleModes = (modes.count > 1);

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  CMTime currentTime = [actionAPI currentTime];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

  int colorMode = (int)modes.firstObject.integerValue;
  double cr = 1, cg = 1, cb = 1;
  [paramGetAPI getIntValue:&colorMode
             fromParameter:kKKParamColorMode
                    atTime:currentTime];
  [paramGetAPI getFloatValue:&cr
               fromParameter:kKKParamColorR
                      atTime:currentTime];
  [paramGetAPI getFloatValue:&cg
               fromParameter:kKKParamColorG
                      atTime:currentTime];
  [paramGetAPI getFloatValue:&cb
               fromParameter:kKKParamColorB
                      atTime:currentTime];
  NSString *gradientJson = nil;
  [paramGetAPI getStringParameterValue:&gradientJson
                         fromParameter:kKKParamGradientData];
  [actionAPI endAction:self];

  CGFloat modeRowH = hasMultipleModes ? KKInspectorRowHeight : 0;
  CGFloat colorRowH = 36;
  CGFloat totalH = modeRowH + colorRowH;

  NSView *container =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, totalH)];
  container.autoresizingMask = NSViewWidthSizable;

  NSView *anchorAbove = container;
  NSLayoutAttribute anchorEdge = NSLayoutAttributeTop;

  if (hasMultipleModes) {
    KKParameterRowView *modeRow = [[KKParameterRowView alloc]
        initWithFrame:NSMakeRect(0, 0, 300, modeRowH)
           apiManager:self.apiManager
          parameterId:parameterID];
    modeRow.translatesAutoresizingMaskIntoConstraints = NO;

    KKLabelView *modeLabel = [[KKLabelView alloc] initWithText:@"Color Mode"];
    modeRow.leftView = modeLabel;

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

    KKPopupSelectView *popupSelect =
        [[KKPopupSelectView alloc] initWithTitles:titles];

    NSInteger popupIndex = [modes indexOfObject:@(colorMode)];
    if (popupIndex != NSNotFound)
      [popupSelect selectIndex:popupIndex];
    objc_setAssociatedObject([self class], kColorModePopupKey, popupSelect,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    modeRow.rightView = popupSelect;

    [container addSubview:modeRow];
    [NSLayoutConstraint activateConstraints:@[
      [modeRow.topAnchor constraintEqualToAnchor:container.topAnchor],
      [modeRow.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
      [modeRow.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
      [modeRow.heightAnchor constraintEqualToConstant:modeRowH],
    ]];

    anchorAbove = modeRow;
    anchorEdge = NSLayoutAttributeBottom;

    __weak typeof(self) weakModeRef = self;
    popupSelect.onSelectionChanged = ^(NSInteger selectedIndex) {
      __strong typeof(weakModeRef) strongSelf = weakModeRef;
      if (strongSelf)
        [strongSelf _kkColorModeChangedToIndex:selectedIndex];
    };
  }

  BOOL hasSolid = [modes containsObject:@(KKColorModeSolid)];
  BOOL hasGradient = [modes containsObject:@(KKColorModeGradient)];

  KKParameterRowView *colorRow =
      [[KKParameterRowView alloc] initWithFrame:NSMakeRect(0, 0, 300, colorRowH)
                                     apiManager:self.apiManager
                                    parameterId:parameterID];
  colorRow.translatesAutoresizingMaskIntoConstraints = NO;
  colorRow.hidden = (colorMode == KKColorModeDynamic);
  objc_setAssociatedObject([self class], kColorRowKey, colorRow,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  KKLabelView *colorLabel = [[KKLabelView alloc] initWithText:@"Color"];
  colorRow.leftView = colorLabel;

  KKColorWellView *well = [[KKColorWellView alloc] initWithFrame:NSZeroRect];
  well.color = [NSColor colorWithRed:cr green:cg blue:cb alpha:1.0];
  well.translatesAutoresizingMaskIntoConstraints = NO;
  objc_setAssociatedObject([self class], kColorWellKey, well,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  KKGradientBarView *bar = [[KKGradientBarView alloc] initWithFrame:NSZeroRect];
  bar.translatesAutoresizingMaskIntoConstraints = NO;
  NSArray<KKGradientStop *> *stops = _parseStops(gradientJson);
  if (stops)
    bar.stops = stops;
  objc_setAssociatedObject([self class], kGradientBarKey, bar,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  well.hidden = (colorMode != KKColorModeSolid);
  bar.hidden = (colorMode != KKColorModeGradient);
  bar.interactionEnabled = (colorMode == KKColorModeGradient);

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
  starBtn.hidden = (colorMode != KKColorModeGradient);
  objc_setAssociatedObject([self class], kGradientFavBtnKey, starBtn,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  KKGradientFavoritesPopover *favPopover =
      [[KKGradientFavoritesPopover alloc] init];
  favPopover.currentStops = bar.stops;
  objc_setAssociatedObject([self class], kGradientFavPopoverKey, favPopover,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  NSView *colorRight = [[NSView alloc] initWithFrame:NSZeroRect];
  if (hasSolid)
    [colorRight addSubview:well];
  if (hasGradient) {
    [colorRight addSubview:bar];
    [colorRight addSubview:starBtn];
  }

  NSMutableArray *constraints = [NSMutableArray new];
  if (hasSolid) {
    [constraints addObjectsFromArray:@[
      [well.trailingAnchor constraintEqualToAnchor:colorRight.trailingAnchor
                                          constant:-23.0],
      [well.centerYAnchor constraintEqualToAnchor:colorRight.centerYAnchor],
      [well.widthAnchor constraintEqualToConstant:14.0],
      [well.heightAnchor constraintEqualToConstant:14.0],
    ]];
  }
  if (hasGradient) {
    [constraints addObjectsFromArray:@[
      [starBtn.trailingAnchor constraintEqualToAnchor:colorRight.trailingAnchor
                                             constant:-23.0],
      [starBtn.topAnchor constraintEqualToAnchor:bar.topAnchor constant:5.0],
      [starBtn.widthAnchor constraintEqualToConstant:16.0],
      [starBtn.heightAnchor constraintEqualToConstant:16.0],

      [bar.trailingAnchor constraintEqualToAnchor:starBtn.leadingAnchor
                                         constant:-KKSpacingSM],
      [bar.leadingAnchor constraintEqualToAnchor:colorRight.leadingAnchor],
      [bar.topAnchor constraintEqualToAnchor:colorRight.topAnchor],
      [bar.bottomAnchor constraintEqualToAnchor:colorRight.bottomAnchor],
    ]];
  }
  [NSLayoutConstraint activateConstraints:constraints];
  colorRow.rightView = colorRight;

  KKAlertView *dynAlert = [[KKAlertView alloc]
      initWithText:@"Color is automatically sampled from content"
             color:[[NSColor inspectorLabel] colorWithAlphaComponent:0.3]];
  dynAlert.icon = [NSImage imageWithSystemSymbolName:@"info.circle"
                            accessibilityDescription:nil];
  dynAlert.translatesAutoresizingMaskIntoConstraints = NO;
  dynAlert.hidden = (colorMode != KKColorModeDynamic);
  objc_setAssociatedObject([self class], kColorDynamicAlertKey, dynAlert,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  [container addSubview:colorRow];
  [container addSubview:dynAlert];

  NSLayoutAnchor *topAnchor = (anchorEdge == NSLayoutAttributeBottom)
                                  ? anchorAbove.bottomAnchor
                                  : container.topAnchor;
  [NSLayoutConstraint activateConstraints:@[
    [colorRow.topAnchor constraintEqualToAnchor:topAnchor],
    [colorRow.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
    [colorRow.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    [colorRow.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],

    [dynAlert.topAnchor constraintEqualToAnchor:topAnchor],
    [dynAlert.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
    [dynAlert.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    [dynAlert.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
  ]];

  __weak typeof(self) weakSelf = self;

  well.onColorChanged = ^(NSColor *color) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [[color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]] getRed:&r
                                                                 green:&g
                                                                  blue:&b
                                                                 alpha:&a];
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setFloatValue:r
              toParameter:kKKParamColorR
                   atTime:[actAPI currentTime]];
    [setAPI setFloatValue:g
              toParameter:kKKParamColorG
                   atTime:[actAPI currentTime]];
    [setAPI setFloatValue:b
              toParameter:kKKParamColorB
                   atTime:[actAPI currentTime]];
    [actAPI endAction:strongSelf];
  };

  bar.onStopsChanged = ^(NSArray<KKGradientStop *> *newStops) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    NSString *json = _stopsToJSON(newStops);
    if (!json)
      return;
    KKGradientFavoritesPopover *fp =
        objc_getAssociatedObject([strongSelf class], kGradientFavPopoverKey);
    fp.currentStops = newStops;
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
    NSString *json = _stopsToJSON(newStops);
    if (!json)
      return;
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

- (void)_kkColorModeChangedToIndex:(NSInteger)selectedIndex {
  NSArray<NSNumber *> *modes = _colorModes(self);
  if (selectedIndex < 0 || selectedIndex >= (NSInteger)modes.count)
    return;
  int mode = modes[selectedIndex].intValue;

  KKColorWellView *well = objc_getAssociatedObject([self class], kColorWellKey);
  KKGradientBarView *bar =
      objc_getAssociatedObject([self class], kGradientBarKey);
  KKAlertView *dynAlert =
      objc_getAssociatedObject([self class], kColorDynamicAlertKey);
  NSView *colorRow = objc_getAssociatedObject([self class], kColorRowKey);

  well.hidden = (mode != KKColorModeSolid);
  bar.hidden = (mode != KKColorModeGradient);
  bar.interactionEnabled = (mode == KKColorModeGradient);
  NSButton *starBtn =
      objc_getAssociatedObject([self class], kGradientFavBtnKey);
  starBtn.hidden = (mode != KKColorModeGradient);
  colorRow.hidden = (mode == KKColorModeDynamic);
  dynAlert.hidden = (mode != KKColorModeDynamic);

  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setIntValue:mode
          toParameter:kKKParamColorMode
               atTime:[actAPI currentTime]];
  [actAPI endAction:self];
}

- (void)_kkGradientFavTapped:(NSButton *)sender {
  KKGradientFavoritesPopover *favPopover =
      objc_getAssociatedObject([self class], kGradientFavPopoverKey);
  if (!favPopover)
    return;
  [favPopover showRelativeToRect:sender.bounds ofView:sender];
}

@end
