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
#import <KeyframelessKit/KKLabelView.h>
#import <KeyframelessKit/KKParameterRowView.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>
#import <objc/runtime.h>

static const void *const kColorModesKey = &kColorModesKey;
static const void *const kColorWellKey = &kColorWellKey;
static const void *const kGradientBarKey = &kGradientBarKey;
static const void *const kColorModePopupKey = &kColorModePopupKey;
static const void *const kColorDynamicAlertKey = &kColorDynamicAlertKey;
static const void *const kColorRowKey = &kColorRowKey;

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
    [stops addObject:[KKGradientStop
                         stopWithPosition:[d[@"p"] doubleValue]
                                    color:[NSColor
                                              colorWithRed:[d[@"r"] doubleValue]
                                                     green:[d[@"g"] doubleValue]
                                                      blue:[d[@"b"] doubleValue]
                                                     alpha:1.0]]];
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
      @"b" : @((double)b)
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

    NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect
                                                      pullsDown:NO];
    [popup addItemsWithTitles:titles];
    popup.bordered = NO;
    popup.font = [NSFont systemFontOfSize:11.0];
    ((NSPopUpButtonCell *)popup.cell).arrowPosition = NSPopUpNoArrow;
    popup.translatesAutoresizingMaskIntoConstraints = NO;

    NSInteger popupIndex = [modes indexOfObject:@(colorMode)];
    if (popupIndex != NSNotFound)
      [popup selectItemAtIndex:popupIndex];
    objc_setAssociatedObject([self class], kColorModePopupKey, popup,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSColor *chevronColor = [NSColor colorWithRed:0xAB / 255.0
                                            green:0xAB / 255.0
                                             blue:0xAA / 255.0
                                            alpha:1.0];
    NSImageSymbolConfiguration *chevronCfg = [NSImageSymbolConfiguration
        configurationWithPointSize:11.0
                            weight:NSFontWeightSemibold];
    CGFloat chevronW = 11.0 - 3.0;

    NSImage *upImg = [[NSImage imageWithSystemSymbolName:@"chevron.up"
                                accessibilityDescription:nil]
        imageWithSymbolConfiguration:chevronCfg];
    NSImageView *upChevron = [[NSImageView alloc] init];
    upChevron.image = upImg;
    upChevron.contentTintColor = chevronColor;
    upChevron.imageScaling = NSImageScaleAxesIndependently;
    upChevron.translatesAutoresizingMaskIntoConstraints = NO;

    NSImage *downImg = [[NSImage imageWithSystemSymbolName:@"chevron.down"
                                  accessibilityDescription:nil]
        imageWithSymbolConfiguration:chevronCfg];
    NSImageView *downChevron = [[NSImageView alloc] init];
    downChevron.image = downImg;
    downChevron.contentTintColor = chevronColor;
    downChevron.imageScaling = NSImageScaleAxesIndependently;
    downChevron.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *modeRight = [[NSView alloc] initWithFrame:NSZeroRect];
    [modeRight addSubview:popup];
    [modeRight addSubview:upChevron];
    [modeRight addSubview:downChevron];
    [NSLayoutConstraint activateConstraints:@[
      [popup.trailingAnchor constraintEqualToAnchor:upChevron.leadingAnchor],
      [popup.centerYAnchor constraintEqualToAnchor:modeRight.centerYAnchor],

      [upChevron.trailingAnchor constraintEqualToAnchor:modeRight.trailingAnchor
                                               constant:-KKSpacingLG],
      [upChevron.widthAnchor constraintEqualToConstant:chevronW],
      [upChevron.heightAnchor constraintEqualToConstant:6.0],
      [upChevron.bottomAnchor constraintEqualToAnchor:modeRight.centerYAnchor
                                             constant:0.0],

      [downChevron.trailingAnchor
          constraintEqualToAnchor:modeRight.trailingAnchor
                         constant:-KKSpacingLG],
      [downChevron.widthAnchor constraintEqualToConstant:chevronW],
      [downChevron.heightAnchor constraintEqualToConstant:6.0],
      [downChevron.topAnchor constraintEqualToAnchor:modeRight.centerYAnchor
                                            constant:0.0],
    ]];
    modeRow.rightView = modeRight;

    [container addSubview:modeRow];
    [NSLayoutConstraint activateConstraints:@[
      [modeRow.topAnchor constraintEqualToAnchor:container.topAnchor],
      [modeRow.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
      [modeRow.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
      [modeRow.heightAnchor constraintEqualToConstant:modeRowH],
    ]];

    anchorAbove = modeRow;
    anchorEdge = NSLayoutAttributeBottom;

    popup.target = self;
    popup.action = @selector(_kkColorModeChanged:);
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

  NSView *colorRight = [[NSView alloc] initWithFrame:NSZeroRect];
  if (hasSolid)
    [colorRight addSubview:well];
  if (hasGradient)
    [colorRight addSubview:bar];

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
      [bar.trailingAnchor constraintEqualToAnchor:colorRight.trailingAnchor
                                         constant:-23.0],
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

- (void)_kkColorModeChanged:(NSPopUpButton *)sender {
  NSArray<NSNumber *> *modes = _colorModes(self);
  NSInteger selectedIndex = sender.indexOfSelectedItem;
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

@end
