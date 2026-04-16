/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "CapStyleView.h"
#import "FillStyleView.h"
#import "JoinStyleView.h"
#import "LayerList_Private.h"
#import "MarkerStyleView.h"
#import "ObjectParams.h"
#import "SeedView.h"
#import "StrokeStyleView.h"
#import <objc/message.h>
#import <objc/runtime.h>

@implementation KKLayerInstanceState
- (instancetype)init {
  self = [super init];
  _listHash = NSUIntegerMax;
  return self;
}
@end

static NSDictionary<NSString *, KKLayerInstanceState *> *sLayerStates;
static const char kKKLayerUUIDAssocKey;

NSString *KKLayerUUIDForAPI(id<PROAPIAccessing> api) {
  NSString *cached = objc_getAssociatedObject(api, &kKKLayerUUIDAssocKey);
  if (cached)
    return cached;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [api apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *uuid = nil;
  [paramGetAPI getStringParameterValue:&uuid fromParameter:kParamInstanceID];
  if (uuid.length > 0)
    objc_setAssociatedObject(api, &kKKLayerUUIDAssocKey, uuid,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
  return uuid;
}

KKLayerInstanceState *KKLayerStateForUUID(NSString *uuid) {
  if (!uuid)
    return nil;
  KKLayerInstanceState *state = sLayerStates[uuid];
  if (!state) {
    state = [[KKLayerInstanceState alloc] init];
    NSMutableDictionary *mut = sLayerStates ? [sLayerStates mutableCopy]
                                            : [NSMutableDictionary dictionary];
    mut[uuid] = state;
    sLayerStates = [mut copy];
  }
  return state;
}

@implementation CanvasPlugin (CustomUI)

- (void)refreshLayerList {
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamLayerList) {
    CGFloat inset = KKInspectorHorizontalInset;

    KKLayerListContainer *wrapper = [[KKLayerListContainer alloc]
        initWithFrame:NSMakeRect(0, 0, 300, kLayerListTotalHeight)];
    wrapper.autoresizingMask = NSViewWidthSizable;

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = NO;
    scrollView.autohidesScrollers = YES;
    scrollView.drawsBackground = YES;
    scrollView.backgroundColor = [NSColor colorWithWhite:0.15 alpha:1.0];
    scrollView.borderType = NSNoBorder;
    scrollView.wantsLayer = YES;
    scrollView.layer.cornerRadius = KKSpacingMD;
    scrollView.layer.masksToBounds = YES;
    wrapper.scrollView = scrollView;

    NSView *borderView = [[NSView alloc] initWithFrame:NSZeroRect];
    borderView.translatesAutoresizingMaskIntoConstraints = NO;
    borderView.wantsLayer = YES;
    borderView.layer.cornerRadius = KKSpacingMD;
    borderView.layer.borderWidth = KKBorderWidthXS;
    borderView.layer.borderColor =
        [NSColor colorWithWhite:1.0 alpha:kLayerBorderAlpha].CGColor;
    wrapper.borderView = borderView;
    [borderView addSubview:scrollView];
    [wrapper addSubview:borderView];

    NSTextField *hintLabel =
        [NSTextField labelWithString:@"Drop images into the layer list"];
    hintLabel.font = [NSFont systemFontOfSize:KKFontSizeSM - 1.0];
    hintLabel.textColor = [NSColor tertiaryLabelColor];
    hintLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSImageView *hintIcon = [NSImageView
        imageViewWithImage:[NSImage imageWithSystemSymbolName:@"photo.fill"
                                     accessibilityDescription:nil]];
    hintIcon.translatesAutoresizingMaskIntoConstraints = NO;
    hintIcon.contentTintColor = [NSColor tertiaryLabelColor];
    [hintIcon.widthAnchor constraintEqualToConstant:KKFontSizeSM].active = YES;
    [hintIcon.heightAnchor constraintEqualToConstant:KKFontSizeSM].active = YES;

    NSStackView *hintStack =
        [NSStackView stackViewWithViews:@[ hintIcon, hintLabel ]];
    hintStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    hintStack.spacing = KKSpacingXS;
    hintStack.translatesAutoresizingMaskIntoConstraints = NO;
    [wrapper addSubview:hintStack];

    [NSLayoutConstraint activateConstraints:@[
      [hintStack.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor
                                              constant:inset + KKPaddingSM],
      [hintStack.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
      [hintStack.heightAnchor constraintEqualToConstant:kLayerListHintHeight],
      [borderView.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor
                                               constant:inset],
      [borderView.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor
                                                constant:-inset],
      [borderView.topAnchor constraintEqualToAnchor:hintStack.bottomAnchor],
      [borderView.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor
                                              constant:-kLayerListVerticalPad],
      [scrollView.leadingAnchor
          constraintEqualToAnchor:borderView.leadingAnchor],
      [scrollView.trailingAnchor
          constraintEqualToAnchor:borderView.trailingAnchor],
      [scrollView.topAnchor constraintEqualToAnchor:borderView.topAnchor],
      [scrollView.bottomAnchor constraintEqualToAnchor:borderView.bottomAnchor],
    ]];

    NSImage *icon =
        [NSImage imageWithSystemSymbolName:@"square.3.layers.3d.slash"
                  accessibilityDescription:nil];
    NSImageView *iconView = [NSImageView imageViewWithImage:icon];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentTintColor = [NSColor secondaryLabelColor];
    [iconView.widthAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;

    NSTextField *empty = [NSTextField labelWithString:@"No shapes"];
    empty.font = [NSFont systemFontOfSize:KKFontSizeSM];
    empty.textColor = [NSColor secondaryLabelColor];
    empty.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *emptyStack =
        [NSStackView stackViewWithViews:@[ iconView, empty ]];
    emptyStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    emptyStack.spacing = KKSpacingSM;
    emptyStack.translatesAutoresizingMaskIntoConstraints = NO;

    KKLayerContentView *content =
        [[KKLayerContentView alloc] initWithFrame:NSZeroRect];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:emptyStack];
    scrollView.documentView = content;

    [content.leadingAnchor
        constraintEqualToAnchor:scrollView.contentView.leadingAnchor]
        .active = YES;
    [content.trailingAnchor
        constraintEqualToAnchor:scrollView.contentView.trailingAnchor]
        .active = YES;
    NSLayoutConstraint *heightConstraint =
        [content.heightAnchor constraintEqualToConstant:kLayerListHeight];
    heightConstraint.active = YES;
    [emptyStack.centerXAnchor constraintEqualToAnchor:content.centerXAnchor]
        .active = YES;
    [emptyStack.topAnchor constraintEqualToAnchor:content.topAnchor
                                         constant:kLayerListHeight / 2 - 7]
        .active = YES;

    KKLayerActionTarget *actionTarget = [[KKLayerActionTarget alloc] init];
    actionTarget.apiManager = self.apiManager;

    wrapper.emptyView = emptyStack;
    wrapper.contentView = content;
    content.container = wrapper;
    wrapper.contentHeightConstraint = heightConstraint;
    wrapper.actionTarget = actionTarget;
    content.actionTarget = actionTarget;

    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

    NSString *uuid = nil;
    [paramGetAPI getStringParameterValue:&uuid fromParameter:kParamInstanceID];
    if (uuid.length == 0) {
      uuid = [[NSUUID UUID] UUIDString];
      [paramSetAPI setStringParameterValue:uuid toParameter:kParamInstanceID];
    }
    objc_setAssociatedObject(self.apiManager, &kKKLayerUUIDAssocKey, uuid,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    actionTarget.instanceUUID = uuid;

    KKLayerInstanceState *state = KKLayerStateForUUID(uuid);
    state.container = wrapper;
    state.listHash = NSUIntegerMax;

    // Write back any pending per-object param edits (e.g. user edited
    // params, then switched clips without changing selection).
    NSString *str = nil;
    [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
    NSInteger lastIdx = KKReadSelectedIndex(paramGetAPI);
    if (str.length > 0 && lastIdx >= 0) {
      NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
      NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
      if ((NSUInteger)lastIdx < paths.count && !paths[lastIdx].isGroup) {
        KKParamsToPath(paramGetAPI, paths[lastIdx]);
        NSData *newBlob = [KKBezierPath blobFromPaths:paths];
        [paramSetAPI
            setStringParameterValue:[newBlob base64EncodedStringWithOptions:0]
                        toParameter:kParamPathData];
      }
    }
    // Visibility is managed by drawOSC every frame — don't hide here
    // as this method also fires when switching to the inspector panel.
    [actionAPI endAction:self];

    if (str.length > 0) {
      NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
      NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
      if (paths.count > 0)
        KKCanvasRefreshLayerList(uuid, paths.count, paths);
    }

    return wrapper;
  }

  if (parameterID == kParamGroupStroke) {
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"stroke.line.diagonal"
                              accessibilityDescription:nil];
    KKCustomGroupHeaderView *header =
        [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                            apiManager:self.apiManager
                                           parameterId:parameterID
                                                  text:@"Stroke"
                                                  icon:icon
                                         showsCheckbox:YES];

    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    CMTime currentTime = [actionAPI currentTime];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    NSInteger selIdx = KKReadSelectedIndex(paramGetAPI);
    BOOL hasSelection = (selIdx >= 0);
    header.isInteractive = hasSelection;
    if (hasSelection) {
      BOOL enabled = YES;
      [paramGetAPI getBoolValue:&enabled
                  fromParameter:kParamStrokeEnabled
                         atTime:currentTime];
      header.isEnabled = enabled;

      BOOL expanded = NO;
      [paramGetAPI getBoolValue:&expanded
                  fromParameter:kParamExpandedStroke
                         atTime:currentTime];
      header.isExpanded = expanded;
    }
    [actionAPI endAction:self];

    __weak typeof(self) weakSelf = self;
    header.onEnabledChanged = ^(BOOL isEnabled) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;
      id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:strongSelf];
      id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      [setAPI setBoolValue:isEnabled
               toParameter:kParamStrokeEnabled
                    atTime:[actAPI currentTime]];
      id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      BOOL expanded = NO;
      [getAPI getBoolValue:&expanded
             fromParameter:kParamExpandedStroke
                    atTime:kCMTimeZero];
      KKSetStrokeChildrenVisible(setAPI, isEnabled, expanded);
      if (isEnabled && expanded) {
        NSString *str = nil;
        [getAPI getStringParameterValue:&str fromParameter:kParamPathData];
        NSInteger selIdx = KKReadSelectedIndex(getAPI);
        if (str.length > 0 && selIdx >= 0) {
          NSData *blob = [[NSData alloc] initWithBase64EncodedString:str
                                                             options:0];
          NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
          if ((NSUInteger)selIdx < paths.count) {
            KKBezierPath *p = paths[selIdx];
            KKSetEndWidthVisible(setAPI, !p.closed);
            KKSetLineCapVisible(setAPI, !p.closed);
            KKSetMarkersVisible(setAPI, !p.closed);
            if (!p.closed)
              KKSetMarkerSizeVisible(setAPI, p.startMarker, p.endMarker);
            KKSetLineJoinVisible(setAPI, p.count > 2);
            KKSetStrokeStyleVisible(setAPI, YES);
            KKSetDashDotParamsForStyle(setAPI, p.strokeStyle);
          }
        }
      }
      [actAPI endAction:strongSelf];
      KKModifySelectedPathProperty(strongSelf.apiManager,
                                   ^(KKBezierPath *path) {
                                     path.strokeEnabled = isEnabled;
                                   });
    };
    header.onExpandedChanged = ^(BOOL isExpanded) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;
      id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:strongSelf];
      id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      [setAPI setBoolValue:isExpanded
               toParameter:kParamExpandedStroke
                    atTime:[actAPI currentTime]];
      BOOL strokeOn = NO;
      [getAPI getBoolValue:&strokeOn
             fromParameter:kParamStrokeEnabled
                    atTime:kCMTimeZero];
      KKSetStrokeChildrenVisible(setAPI, strokeOn, isExpanded);
      if (strokeOn && isExpanded) {
        NSString *str = nil;
        [getAPI getStringParameterValue:&str fromParameter:kParamPathData];
        NSInteger selIdx = KKReadSelectedIndex(getAPI);
        if (str.length > 0 && selIdx >= 0) {
          NSData *blob = [[NSData alloc] initWithBase64EncodedString:str
                                                             options:0];
          NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
          if ((NSUInteger)selIdx < paths.count) {
            KKBezierPath *p = paths[selIdx];
            KKSetEndWidthVisible(setAPI, !p.closed);
            KKSetLineCapVisible(setAPI, !p.closed);
            KKSetMarkersVisible(setAPI, !p.closed);
            if (!p.closed)
              KKSetMarkerSizeVisible(setAPI, p.startMarker, p.endMarker);
            KKSetLineJoinVisible(setAPI, p.count > 2);
            KKSetStrokeStyleVisible(setAPI, YES);
            KKSetDashDotParamsForStyle(setAPI, p.strokeStyle);
          }
        }
      }
      [actAPI endAction:strongSelf];
    };

    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid)
      KKLayerStateForUUID(uuid).strokeGroupHeader = header;

    return header;
  }

  if (parameterID == kParamGroupFill) {
    NSImage *icon =
        [NSImage imageWithSystemSymbolName:@"rectangle.trailinghalf.filled"
                  accessibilityDescription:nil];
    KKCustomGroupHeaderView *header =
        [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                            apiManager:self.apiManager
                                           parameterId:parameterID
                                                  text:@"Fill"
                                                  icon:icon
                                         showsCheckbox:YES];

    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    CMTime currentTime = [actionAPI currentTime];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    NSInteger selIdx = KKReadSelectedIndex(paramGetAPI);
    BOOL hasSelection = (selIdx >= 0);
    header.isInteractive = hasSelection;
    if (hasSelection) {
      BOOL enabled = NO;
      [paramGetAPI getBoolValue:&enabled
                  fromParameter:kParamFillEnabled
                         atTime:currentTime];
      header.isEnabled = enabled;

      BOOL expanded = NO;
      [paramGetAPI getBoolValue:&expanded
                  fromParameter:kParamExpandedFill
                         atTime:currentTime];
      header.isExpanded = expanded;
    }
    [actionAPI endAction:self];

    __weak typeof(self) weakSelf = self;
    header.onEnabledChanged = ^(BOOL isEnabled) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;
      id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:strongSelf];
      id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      [setAPI setBoolValue:isEnabled
               toParameter:kParamFillEnabled
                    atTime:[actAPI currentTime]];
      id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      BOOL expanded = NO;
      [getAPI getBoolValue:&expanded
             fromParameter:kParamExpandedFill
                    atTime:kCMTimeZero];
      KKSetFillChildrenVisible(setAPI, isEnabled, expanded);
      if (isEnabled && expanded) {
        int fillStyle = KKReadSelectedFillStyle(getAPI);
        KKSetFillStyleParamsVisible(setAPI, YES, fillStyle);
      }
      [actAPI endAction:strongSelf];
      KKModifySelectedPathProperty(strongSelf.apiManager,
                                   ^(KKBezierPath *path) {
                                     path.fillEnabled = isEnabled;
                                   });
    };
    header.onExpandedChanged = ^(BOOL isExpanded) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;
      id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:strongSelf];
      id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      [setAPI setBoolValue:isExpanded
               toParameter:kParamExpandedFill
                    atTime:[actAPI currentTime]];
      BOOL fillOn = NO;
      [getAPI getBoolValue:&fillOn
             fromParameter:kParamFillEnabled
                    atTime:kCMTimeZero];
      KKSetFillChildrenVisible(setAPI, fillOn, isExpanded);
      if (fillOn && isExpanded) {
        int fillStyle = KKReadSelectedFillStyle(getAPI);
        KKSetFillStyleParamsVisible(setAPI, YES, fillStyle);
      }
      [actAPI endAction:strongSelf];
    };

    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid)
      KKLayerStateForUUID(uuid).fillGroupHeader = header;

    return header;
  }

  if (parameterID == kParamGroupSketch) {
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"scribble"
                              accessibilityDescription:nil];
    KKCustomGroupHeaderView *header =
        [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                            apiManager:self.apiManager
                                           parameterId:parameterID
                                                  text:@"Sketch"
                                                  icon:icon
                                         showsCheckbox:YES];

    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    CMTime currentTime = [actionAPI currentTime];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    NSInteger selIdx = KKReadSelectedIndex(paramGetAPI);
    BOOL hasSelection = (selIdx >= 0);
    header.isInteractive = hasSelection;
    if (hasSelection) {
      BOOL enabled = NO;
      [paramGetAPI getBoolValue:&enabled
                  fromParameter:kParamSketchEnabled
                         atTime:currentTime];
      header.isEnabled = enabled;

      BOOL expanded = NO;
      [paramGetAPI getBoolValue:&expanded
                  fromParameter:kParamExpandedSketch
                         atTime:currentTime];
      header.isExpanded = expanded;
    }
    [actionAPI endAction:self];

    __weak typeof(self) weakSelf = self;
    header.onEnabledChanged = ^(BOOL isEnabled) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;
      id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:strongSelf];
      id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      [setAPI setBoolValue:isEnabled
               toParameter:kParamSketchEnabled
                    atTime:[actAPI currentTime]];
      id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      BOOL expanded = NO;
      [getAPI getBoolValue:&expanded
             fromParameter:kParamExpandedSketch
                    atTime:kCMTimeZero];
      KKSetSketchChildrenVisible(setAPI, isEnabled, expanded);
      [actAPI endAction:strongSelf];
      KKModifySelectedPathProperty(strongSelf.apiManager,
                                   ^(KKBezierPath *path) {
                                     path.sketchEnabled = isEnabled;
                                     if (isEnabled && path.sketchSeed == 0)
                                       path.sketchSeed = arc4random();
                                   });
    };
    header.onExpandedChanged = ^(BOOL isExpanded) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf)
        return;
      id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:strongSelf];
      id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      [setAPI setBoolValue:isExpanded
               toParameter:kParamExpandedSketch
                    atTime:[actAPI currentTime]];
      BOOL sketchOn = NO;
      [getAPI getBoolValue:&sketchOn
             fromParameter:kParamSketchEnabled
                    atTime:kCMTimeZero];
      KKSetSketchChildrenVisible(setAPI, sketchOn, isExpanded);
      [actAPI endAction:strongSelf];
    };

    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid)
      KKLayerStateForUUID(uuid).sketchGroupHeader = header;

    return header;
  }

  if (parameterID == kParamLineCap) {
    KKCapStyleView *capView = [[KKCapStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    capView.autoresizingMask = NSViewWidthSizable;

    __weak id weakAPI = self.apiManager;
    capView.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.lineCap = (uint8_t)index;
      });
    };

    // Store weak ref so the layer list refresh can update selectedIndex.
    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid)
      KKLayerStateForUUID(uuid).capStyleView = capView;

    return capView;
  }

  if (parameterID == kParamLineJoin) {
    KKJoinStyleView *joinView = [[KKJoinStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    joinView.autoresizingMask = NSViewWidthSizable;

    __weak id weakAPI = self.apiManager;
    joinView.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.lineJoin = (uint8_t)index;
      });
    };

    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid)
      KKLayerStateForUUID(uuid).joinStyleView = joinView;

    return joinView;
  }

  if (parameterID == kParamStrokeStyle) {
    KKStrokeStyleView *styleView = [[KKStrokeStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    styleView.autoresizingMask = NSViewWidthSizable;

    __weak id weakAPI = self.apiManager;
    styleView.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.strokeStyle = (uint8_t)index;
        KKSetDashDotParamsForStyle(
            [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)],
            (uint8_t)index);
      });
    };

    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid)
      KKLayerStateForUUID(uuid).strokeStyleView = styleView;

    return styleView;
  }

  if (parameterID == kParamStartMarker) {
    KKMarkerStyleView *markerView = [[KKMarkerStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    markerView.autoresizingMask = NSViewWidthSizable;
    markerView.isStart = YES;

    __weak id weakAPI = self.apiManager;
    markerView.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.startMarker = (uint8_t)index;
        id<FxParameterSettingAPI_v5> setAPI =
            [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
        [setAPI setParameterFlags:(index != 0) ? kFxParameterFlag_DEFAULT
                                               : kFxParameterFlag_HIDDEN
                      toParameter:kParamStartMarkerSize];
      });
    };

    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid)
      KKLayerStateForUUID(uuid).startMarkerView = markerView;

    return markerView;
  }

  if (parameterID == kParamEndMarker) {
    KKMarkerStyleView *markerView = [[KKMarkerStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    markerView.autoresizingMask = NSViewWidthSizable;
    markerView.isStart = NO;

    __weak id weakAPI = self.apiManager;
    markerView.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.endMarker = (uint8_t)index;
        id<FxParameterSettingAPI_v5> setAPI =
            [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
        [setAPI setParameterFlags:(index != 0) ? kFxParameterFlag_DEFAULT
                                               : kFxParameterFlag_HIDDEN
                      toParameter:kParamEndMarkerSize];
      });
    };

    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid)
      KKLayerStateForUUID(uuid).endMarkerView = markerView;

    return markerView;
  }

  if (parameterID == kParamSketchFillStyle) {
    KKFillStyleView *fillStyleView = [[KKFillStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    fillStyleView.autoresizingMask = NSViewWidthSizable;

    __weak id weakAPI = self.apiManager;
    fillStyleView.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.sketchFillStyle = (uint8_t)index;
      });
      id<FxCustomParameterActionAPI_v4> actAPI =
          [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:api];
      id<FxParameterSettingAPI_v5> setAPI =
          [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      KKSetFillStyleParamsVisible(setAPI, YES, (int)index);
      [actAPI endAction:api];
    };

    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid)
      KKLayerStateForUUID(uuid).fillStyleView = fillStyleView;

    return fillStyleView;
  }

  if (parameterID == kParamSketchSeed) {
    KKSeedView *seedView = [[KKSeedView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    seedView.autoresizingMask = NSViewWidthSizable;

    // Read current seed from the selected path. If it's 0, generate one now.
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSString *pathStr = nil;
    [paramGetAPI getStringParameterValue:&pathStr fromParameter:kParamPathData];
    NSInteger selIdx = KKReadSelectedIndex(paramGetAPI);
    if (pathStr.length > 0 && selIdx >= 0) {
      NSData *blob = [[NSData alloc] initWithBase64EncodedString:pathStr
                                                         options:0];
      NSMutableArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
      if ((NSUInteger)selIdx < paths.count) {
        uint32_t seed = paths[selIdx].sketchSeed;
        if (seed == 0) {
          seed = arc4random();
          paths[selIdx].sketchSeed = seed;
          id<FxParameterSettingAPI_v5> setAPI = [self.apiManager
              apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
          NSData *newBlob = [KKBezierPath blobFromPaths:paths];
          [setAPI
              setStringParameterValue:[newBlob base64EncodedStringWithOptions:0]
                          toParameter:kParamPathData];
        }
        seedView.seed = seed;
      }
    }

    __weak id weakAPI = self.apiManager;
    __weak KKSeedView *weakSeedView = seedView;
    seedView.onReroll = ^{
      id api = weakAPI;
      if (!api)
        return;
      __block uint32_t newSeed = 0;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *path) {
        newSeed = arc4random();
        path.sketchSeed = newSeed;
      });
      KKSeedView *sv = weakSeedView;
      if (sv && newSeed != 0)
        sv.seed = newSeed;
    };
    seedView.onSeedChanged = ^(uint32_t newSeed) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *path) {
        path.sketchSeed = newSeed;
      });
    };

    return seedView;
  }

  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

@end
