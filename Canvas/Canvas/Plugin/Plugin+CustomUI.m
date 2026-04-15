/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "CapStyleView.h"
#import "JoinStyleView.h"
#import "LayerList_Private.h"
#import "ObjectParams.h"
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

    [NSLayoutConstraint activateConstraints:@[
      [borderView.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor
                                               constant:inset],
      [borderView.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor
                                                constant:-inset],
      [borderView.topAnchor constraintEqualToAnchor:wrapper.topAnchor
                                           constant:kLayerListVerticalPad],
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

  if (parameterID == kParamLineCap) {
    KKCapStyleView *capView = [[KKCapStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    capView.autoresizingMask = NSViewWidthSizable;

    // Write lineCap changes directly to pathData via action scope.
    __weak id weakAPI = self.apiManager;
    capView.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      id<FxCustomParameterActionAPI_v4> actAPI =
          [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:api];
      id<FxParameterRetrievalAPI_v6> getAPI =
          [api apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      id<FxParameterSettingAPI_v5> setAPI =
          [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      NSString *str = nil;
      [getAPI getStringParameterValue:&str fromParameter:kParamPathData];
      NSInteger selIdx = KKReadSelectedIndex(getAPI);
      if (str.length > 0 && selIdx >= 0) {
        NSData *blob = [[NSData alloc] initWithBase64EncodedString:str
                                                           options:0];
        NSMutableArray<KKBezierPath *> *paths =
            [KKBezierPath pathsFromBlob:blob];
        if ((NSUInteger)selIdx < paths.count) {
          paths[selIdx].lineCap = (uint8_t)index;
          NSData *newBlob = [KKBezierPath blobFromPaths:paths];
          [setAPI
              setStringParameterValue:[newBlob base64EncodedStringWithOptions:0]
                          toParameter:kParamPathData];
        }
      }
      [actAPI endAction:api];
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

    // Write lineJoin changes directly to pathData via action scope.
    __weak id weakAPI = self.apiManager;
    joinView.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      id<FxCustomParameterActionAPI_v4> actAPI =
          [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:api];
      id<FxParameterRetrievalAPI_v6> getAPI =
          [api apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      id<FxParameterSettingAPI_v5> setAPI =
          [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      NSString *str = nil;
      [getAPI getStringParameterValue:&str fromParameter:kParamPathData];
      NSInteger selIdx = KKReadSelectedIndex(getAPI);
      if (str.length > 0 && selIdx >= 0) {
        NSData *blob = [[NSData alloc] initWithBase64EncodedString:str
                                                           options:0];
        NSMutableArray<KKBezierPath *> *paths =
            [KKBezierPath pathsFromBlob:blob];
        if ((NSUInteger)selIdx < paths.count) {
          paths[selIdx].lineJoin = (uint8_t)index;
          NSData *newBlob = [KKBezierPath blobFromPaths:paths];
          [setAPI
              setStringParameterValue:[newBlob base64EncodedStringWithOptions:0]
                          toParameter:kParamPathData];
        }
      }
      [actAPI endAction:api];
    };

    NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
    if (uuid)
      KKLayerStateForUUID(uuid).joinStyleView = joinView;

    return joinView;
  }

  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

@end
