/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CapStyleView.h"
#import "FillStyleView.h"
#import "JoinStyleView.h"
#import "LayerList_Private.h"
#import "MarkerStyleView.h"
#import "ObjectParams.h"
#import "StrokeStyleView.h"
#import <KeyframelessKit/KKGradientSampling.h>
#import <objc/message.h>
#import <objc/runtime.h>

@implementation KKLayerInstanceState
@end

// FCP's OZViewCtrlRootScrollView claims forwarded scroll events from nested
// scroll views, which scrolls the inspector when the user reaches the layer
// list's top/bottom. Returning nil from this private method blocks the
// forwarding-target search; native momentum/elasticity stay intact.
@interface KKLayerListScrollView : NSScrollView
@end
@implementation KKLayerListScrollView
- (NSResponder *)_recursiveResponderThatWantsForwardedScrollEventsForAxis:
                     (NSEventGestureAxis)axis
                                                         intendedForSwipe:
                                                             (BOOL)forSwipe {
  return nil;
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
    state.store = [[KKCanvasStore alloc] initWithUUID:uuid];
    NSMutableDictionary *mut = sLayerStates ? [sLayerStates mutableCopy]
                                            : [NSMutableDictionary dictionary];
    mut[uuid] = state;
    sLayerStates = [mut copy];
  }
  return state;
}

@implementation CanvasPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

- (void)refreshLayerList {
}

- (KKCustomGroupHeaderView *)
    createGroupHeaderWithText:(NSString *)text
                         icon:(NSImage *)icon
                 enabledParam:(UInt32)enabledParam
                expandedParam:(UInt32)expandedParam
              storeSetEnabled:(SEL)storeSetEnabled
             storeSetExpanded:(SEL)storeSetExpanded
              stateHeaderProp:(NSString *)stateHeaderProp
            pathPropertyBlock:(void (^)(KKBezierPath *, BOOL))pathBlock {
  KKCustomGroupHeaderView *header =
      [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                          apiManager:self.apiManager
                                         parameterId:enabledParam
                                                text:text
                                                icon:icon
                                       showsCheckbox:YES];

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  CMTime currentTime = [actionAPI currentTime];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

  header.isInteractive = YES;
  {
    BOOL enabled = (enabledParam == kParamStrokeEnabled) ? YES : NO;
    [paramGetAPI getBoolValue:&enabled
                fromParameter:enabledParam
                       atTime:currentTime];
    header.isEnabled = enabled;
    BOOL expanded = NO;
    [paramGetAPI getBoolValue:&expanded
                fromParameter:expandedParam
                       atTime:currentTime];
    header.isExpanded = expanded;
  }
  [actionAPI endAction:self];

  __weak typeof(self) weakSelf = self;
  SEL enabledSel = storeSetEnabled;
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
             toParameter:enabledParam
                  atTime:[actAPI currentTime]];
    [actAPI endAction:strongSelf];
    KKModifySelectedPathProperty(strongSelf.apiManager, ^(KKBezierPath *path) {
      pathBlock(path, isEnabled);
    });
    NSString *sUUID = KKLayerUUIDForAPI(strongSelf.apiManager);
    if (sUUID) {
      KKCanvasStore *s = KKLayerStateForUUID(sUUID).store;
      [s performBatch:^{
        typedef void (*StoreSetter)(id, SEL, BOOL);
        ((StoreSetter)objc_msgSend)(s, enabledSel, isEnabled);
      }];
    }
  };

  SEL expandedSel = storeSetExpanded;
  header.onExpandedChanged = ^(BOOL isExpanded) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setBoolValue:isExpanded
             toParameter:expandedParam
                  atTime:[actAPI currentTime]];
    [actAPI endAction:strongSelf];
    NSString *sUUID = KKLayerUUIDForAPI(strongSelf.apiManager);
    if (sUUID) {
      KKCanvasStore *s = KKLayerStateForUUID(sUUID).store;
      [s performBatch:^{
        typedef void (*StoreSetter)(id, SEL, BOOL);
        ((StoreSetter)objc_msgSend)(s, expandedSel, isExpanded);
      }];
    }
  };

  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  if (uuid)
    [KKLayerStateForUUID(uuid) setValue:header forKey:stateHeaderProp];

  return header;
}

- (NSView *)createLayerListView NS_RETURNS_RETAINED {
  CGFloat inset = KKInspectorHorizontalInset;

  KKLayerListContainer *wrapper = [[KKLayerListContainer alloc]
      initWithFrame:NSMakeRect(0, 0, 300, kLayerListTotalHeight)];
  wrapper.autoresizingMask = NSViewWidthSizable;

  NSScrollView *scrollView =
      [[KKLayerListScrollView alloc] initWithFrame:NSZeroRect];
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
    [scrollView.leadingAnchor constraintEqualToAnchor:borderView.leadingAnchor],
    [scrollView.trailingAnchor
        constraintEqualToAnchor:borderView.trailingAnchor],
    [scrollView.topAnchor constraintEqualToAnchor:borderView.topAnchor],
    [scrollView.bottomAnchor constraintEqualToAnchor:borderView.bottomAnchor],
  ]];

  NSImage *icon = [NSImage imageWithSystemSymbolName:@"square.3.layers.3d.slash"
                            accessibilityDescription:nil];
  NSImageView *iconView = [NSImageView imageViewWithImage:icon];
  iconView.translatesAutoresizingMaskIntoConstraints = NO;
  iconView.contentTintColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];
  [iconView.widthAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;
  [iconView.heightAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;

  NSTextField *empty = [NSTextField labelWithString:@"No shapes"];
  empty.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
  empty.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];
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
  [emptyStack.centerYAnchor constraintEqualToAnchor:content.centerYAnchor]
      .active = YES;

  KKLayerActionTarget *actionTarget = [[KKLayerActionTarget alloc] init];
  actionTarget.apiManager = self.apiManager;

  wrapper.emptyView = emptyStack;
  wrapper.contentView = content;
  content.container = wrapper;
  wrapper.contentHeightConstraint = heightConstraint;
  wrapper.actionTarget = actionTarget;
  content.actionTarget = actionTarget;

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
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

  KKLayerInstanceState *state = KKLayerStateForUUID(uuid);
  // Duplicate-UUID detection: FCP copy/paste/cut clones `kParamInstanceID`
  // along with the rest of the params, so two distinct plugin instances
  // can resolve to the same state and clobber each other's view refs. If
  // this state is already owned by a different api, mint a fresh UUID for
  // the new instance and rebind to a new state entry.
  void *apiPtr = (__bridge void *)self.apiManager;
  if (state.ownerAPIPointer && state.ownerAPIPointer != apiPtr) {
    uuid = [[NSUUID UUID] UUIDString];
    [paramSetAPI setStringParameterValue:uuid toParameter:kParamInstanceID];
    objc_setAssociatedObject(self.apiManager, &kKKLayerUUIDAssocKey, uuid,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    state = KKLayerStateForUUID(uuid);
  }
  state.ownerAPIPointer = apiPtr;
  actionTarget.instanceUUID = uuid;

  state.container = wrapper;

  // Write back any pending per-object param edits.
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
  [actionAPI endAction:self];

  // Register store observer.
  __weak KKLayerInstanceState *weakState = state;
  __weak id weakAPI = self.apiManager;
  __weak CanvasPlugin *weakSelf = self;
  [state.store
      addObserverForChanges:(KKStoreChangePaths | KKStoreChangeSelection |
                             KKStoreChangeVisibility | KKStoreChangeCollapse |
                             KKStoreChangeSolo | KKStoreChangeEditing |
                             KKStoreChangePathProps | KKStoreChangeExpanded)
                      block:^(KKCanvasStoreSnapshot *snap,
                              KKStoreChange changes) {
                        KKLayerInstanceState *s = weakState;
                        id api = weakAPI;
                        if (!s || !api)
                          return;
                        KKCanvasRefreshLayerListFromSnapshot(snap, s, api);
                        if (changes &
                            (KKStoreChangePaths | KKStoreChangePathProps))
                          [KKPlugin multiStageSyncFromParams:api];
                        // Selection or path changes can both shift which
                        // layer the sequencer should accent (paths gone →
                        // groupKey vanishes; selection moves → key swaps).
                        if (changes &
                            (KKStoreChangeSelection | KKStoreChangePaths))
                          [weakSelf kkRefreshSequencerSelectedGroup];
                      }];

  // Seed the store so the observer fires on initial setup.
  {
    NSArray<KKBezierPath *> *seedPaths = @[];
    if (str.length > 0) {
      NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
      seedPaths = [KKBezierPath pathsFromBlob:blob];
    }
    NSIndexSet *seedSel = [NSIndexSet indexSet];
    if (lastIdx >= 0)
      seedSel = [NSIndexSet indexSetWithIndex:(NSUInteger)lastIdx];
    KKCanvasStore *initStore = state.store;
    [initStore performBatch:^{
      [initStore setPaths:seedPaths];
      [initStore setSelectedIndices:seedSel];
      [initStore syncSelectedPathProperties];
    }];
    KKCanvasRefreshLayerListFromSnapshot([initStore snapshot], state,
                                         self.apiManager);
  }

  return wrapper;
}

- (NSView *)createStyleViewForParameterID:(UInt32)parameterID
    NS_RETURNS_RETAINED {
  __weak id weakAPI = self.apiManager;
  NSString *uuid = KKLayerUUIDForAPI(self.apiManager);
  KKLayerInstanceState *lst = uuid ? KKLayerStateForUUID(uuid) : nil;

  if (parameterID == kParamLineCap) {
    KKCapStyleView *v = [[KKCapStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    v.autoresizingMask = NSViewWidthSizable;
    v.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.lineCap = (uint8_t)index;
      });
      if (lst)
        lst.cachedLineCap = (uint8_t)index;
    };
    if (lst)
      lst.capStyleView = v;
    return v;
  }

  if (parameterID == kParamLineJoin) {
    KKJoinStyleView *v = [[KKJoinStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    v.autoresizingMask = NSViewWidthSizable;
    v.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.lineJoin = (uint8_t)index;
      });
      if (lst)
        lst.cachedLineJoin = (uint8_t)index;
    };
    if (lst)
      lst.joinStyleView = v;
    return v;
  }

  if (parameterID == kParamStrokeStyle) {
    KKStrokeStyleView *v = [[KKStrokeStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    v.autoresizingMask = NSViewWidthSizable;
    v.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.strokeStyle = (uint8_t)index;
      });
      if (lst) {
        lst.visHash = 0;
        lst.cachedStrokeStyle = (uint8_t)index;
      }
    };
    if (lst)
      lst.strokeStyleView = v;
    return v;
  }

  if (parameterID == kParamStartMarker) {
    KKMarkerStyleView *v = [[KKMarkerStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    v.autoresizingMask = NSViewWidthSizable;
    v.isStart = YES;
    v.onSelectionChanged = ^(NSInteger index) {
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
      if (lst)
        lst.cachedStartMarker = (uint8_t)index;
    };
    if (lst)
      lst.startMarkerView = v;
    return v;
  }

  if (parameterID == kParamEndMarker) {
    KKMarkerStyleView *v = [[KKMarkerStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    v.autoresizingMask = NSViewWidthSizable;
    v.isStart = NO;
    v.onSelectionChanged = ^(NSInteger index) {
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
      if (lst)
        lst.cachedEndMarker = (uint8_t)index;
    };
    if (lst)
      lst.endMarkerView = v;
    return v;
  }

  if (parameterID == kParamSketchFillStyle) {
    KKFillStyleView *v = [[KKFillStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    v.autoresizingMask = NSViewWidthSizable;
    v.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.sketchFillStyle = (uint8_t)index;
      });
      if (lst) {
        lst.cachedFillStyle = (uint8_t)index;
        lst.visHash = 0;
      }
    };
    if (lst)
      lst.fillStyleView = v;
    return v;
  }

  if (parameterID == kParamSketchSeed) {
    KKSeedView *seedView = [[KKSeedView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    seedView.autoresizingMask = NSViewWidthSizable;

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

  if (parameterID == kParamStrokeGradientUI ||
      parameterID == kParamFillGradientUI) {
    BOOL isStroke = (parameterID == kParamStrokeGradientUI);

    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSString *pathStr = nil;
    [paramGetAPI getStringParameterValue:&pathStr fromParameter:kParamPathData];
    NSInteger selIdx = KKReadSelectedIndex(paramGetAPI);
    NSString *json = nil;
    if (pathStr.length > 0 && selIdx >= 0) {
      NSData *blob = [[NSData alloc] initWithBase64EncodedString:pathStr
                                                         options:0];
      NSArray<KKBezierPath *> *paths = [KKBezierPath pathsFromBlob:blob];
      if ((NSUInteger)selIdx < paths.count) {
        json = isStroke ? paths[selIdx].strokeGradientJSON
                        : paths[selIdx].fillGradientJSON;
      }
    }
    if (json.length == 0)
      json = KKDefaultGradientJSON();

    KKGradientControl *control =
        [[KKGradientControl alloc] initWithFrame:NSMakeRect(0, 0, 200, 36)];
    NSArray<KKGradientStop *> *stops = KKGradientStopsFromJSON(json);
    if (stops)
      control.stops = stops;

    control.onStopsChanged = ^(NSArray<KKGradientStop *> *newStops) {
      id api = weakAPI;
      if (!api)
        return;
      NSString *newJSON = KKGradientJSONFromStops(newStops);
      if (!newJSON)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        if (isStroke)
          p.strokeGradientJSON = newJSON;
        else
          p.fillGradientJSON = newJSON;
      });
      id<FxCustomParameterActionAPI_v4> actAPI =
          [api apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:api];
      id<FxParameterSettingAPI_v5> setAPI =
          [api apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      [setAPI setStringParameterValue:newJSON
                          toParameter:isStroke ? kParamStrokeGradientData
                                               : kParamFillGradientData];
      [actAPI endAction:api];
    };

    if (lst) {
      if (isStroke)
        lst.strokeGradientControl = control;
      else
        lst.fillGradientControl = control;
    }
    return control;
  }

  return nil;
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamLayerList)
    return [self createLayerListView];

  if (parameterID == kParamGroupTransform) {
    return [self
        createGroupHeaderWithText:@"Transform"
                             icon:
                                 [NSImage
                                     imageWithSystemSymbolName:
                                         @"arrow.up.and.down.and.arrow.left.and"
                                         @".right"
                                      accessibilityDescription:nil]
                     enabledParam:kParamTransformEnabled
                    expandedParam:kParamExpandedTransform
                  storeSetEnabled:@selector(setTransformEnabled:)
                 storeSetExpanded:@selector(setTransformExpanded:)
                  stateHeaderProp:@"transformGroupHeader"
                pathPropertyBlock:^(KKBezierPath *path, BOOL enabled) {
                  path.transformEnabled = enabled;
                }];
  }

  if (parameterID == kParamGroupStroke) {
    return
        [self createGroupHeaderWithText:@"Stroke"
                                   icon:[NSImage imageWithSystemSymbolName:
                                                     @"stroke.line.diagonal"
                                                  accessibilityDescription:nil]
                           enabledParam:kParamStrokeEnabled
                          expandedParam:kParamExpandedStroke
                        storeSetEnabled:@selector(setStrokeEnabled:)
                       storeSetExpanded:@selector(setStrokeExpanded:)
                        stateHeaderProp:@"strokeGroupHeader"
                      pathPropertyBlock:^(KKBezierPath *path, BOOL enabled) {
                        path.strokeEnabled = enabled;
                      }];
  }

  if (parameterID == kParamGroupFill) {
    return [self
        createGroupHeaderWithText:@"Fill"
                             icon:[NSImage imageWithSystemSymbolName:
                                               @"rectangle.trailinghalf.filled"
                                            accessibilityDescription:nil]
                     enabledParam:kParamFillEnabled
                    expandedParam:kParamExpandedFill
                  storeSetEnabled:@selector(setFillEnabled:)
                 storeSetExpanded:@selector(setFillExpanded:)
                  stateHeaderProp:@"fillGroupHeader"
                pathPropertyBlock:^(KKBezierPath *path, BOOL enabled) {
                  path.fillEnabled = enabled;
                }];
  }

  if (parameterID == kParamGroupSketch) {
    return [self
        createGroupHeaderWithText:@"Sketch"
                             icon:[NSImage imageWithSystemSymbolName:@"scribble"
                                            accessibilityDescription:nil]
                     enabledParam:kParamSketchEnabled
                    expandedParam:kParamExpandedSketch
                  storeSetEnabled:@selector(setSketchEnabled:)
                 storeSetExpanded:@selector(setSketchExpanded:)
                  stateHeaderProp:@"sketchGroupHeader"
                pathPropertyBlock:^(KKBezierPath *path, BOOL enabled) {
                  path.sketchEnabled = enabled;
                  if (enabled && path.sketchSeed == 0)
                    path.sketchSeed = arc4random();
                }];
  }

  NSView *styleView = [self createStyleViewForParameterID:parameterID];
  if (styleView)
    return styleView;

  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

static NSSet<NSString *> *_kkTransformOSCLabels(void) {
  static NSSet<NSString *> *sLabels = nil;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    sLabels = [NSSet setWithObjects:@"Position", @"Scale", @"Anchor", @"Rot Z",
                                    @"Rot X", @"Rot Y", nil];
  });
  return sLabels;
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSC {
  return _kkTransformOSCLabels();
}

- (NSSet<NSString *> *)animatablePropertyLabelsWithOSCDefaultOff {
  return _kkTransformOSCLabels();
}

- (NSString *)emptyLanesMessageWhenNoLanes {
  return @"No layers";
}

- (NSString *)emptyLanesIconNameWhenNoLanes {
  return @"square.dashed";
}

- (NSArray<KKHelpSection *> *)helpSections {
  KKHelpSection *tools = [KKHelpSection
      sectionWithTitle:@"Tools"
             tipMarkup:@[
               (@"Pick a tool from the on-canvas toolbar - "
                @"<accent>Cursor</accent> selects and reshapes paths, "
                @"<accent>Pen</accent> draws bezier paths anchor by anchor, "
                @"and <accent>Rectangle</accent>, <accent>Ellipse</accent>, "
                @"and <accent>Line</accent> drag out primitive shapes."),
               (@"Each path becomes a <accent>layer</accent> in the inspector "
                @"with its own Stroke, Fill, and Sketch styling."),
               (@"With the Pen tool, click to add corner anchors or drag to "
                @"pull out smooth handles. Close a path by clicking its first "
                @"anchor."),
             ]
             shortcuts:@[
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌃</kbd><kbd>V</kbd>"
                               descMarkup:@"Cursor tool"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌃</kbd><kbd>X</kbd>"
                               descMarkup:@"Pen tool"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌃</kbd><kbd>B</kbd>"
                               descMarkup:@"Rectangle tool"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌃</kbd><kbd>G</kbd>"
                               descMarkup:@"Ellipse tool"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌃</kbd><kbd>M</kbd>"
                               descMarkup:@"Line tool"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>esc</kbd>"
                                           descMarkup:@"Return to Cursor and "
                                                      @"clear selection"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌫</kbd>"
                                           descMarkup:@"Delete the selected "
                                                      @"path or anchor"],
             ]];
  tools.icon = [NSImage imageWithSystemSymbolName:@"scribble.variable"
                         accessibilityDescription:nil];

  KKHelpSection *editing = [KKHelpSection
      sectionWithTitle:@"Editing"
             tipMarkup:@[
               (@"Drag an anchor or handle to reshape a path. Drag empty "
                @"canvas to marquee-select multiple anchors or paths."),
               (@"Resize and rotate handles wrap any selection so you can "
                @"transform several paths at once."),
             ]
             shortcuts:@[
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + drag"
                               descMarkup:@"Constrain motion to X or Y axis"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌘</kbd> + drag"
                                           descMarkup:@"Disable snapping"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + drag "
                                                      @"path"
                                           descMarkup:@"Duplicate the "
                                                      @"selected path"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + corner resize"
                               descMarkup:@"Lock to aspect ratio"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + corner resize"
                               descMarkup:@"Scale symmetrically from center"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + "
                                                      @"rotate"
                                           descMarkup:@"Snap rotation to 15° "
                                                      @"increments"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + "
                                                      @"marquee"
                                           descMarkup:@"Add to selection"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + marquee"
                                           descMarkup:@"Remove from selection"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click "
                                                      @"anchor"
                                           descMarkup:@"Delete the anchor "
                                                      @"(Pen tool)"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + drag "
                                                      @"handle"
                                           descMarkup:@"Break handle "
                                                      @"symmetry (move "
                                                      @"independently)"],
             ]];
  editing.icon = [NSImage imageWithSystemSymbolName:@"hand.draw"
                           accessibilityDescription:nil];

  return @[ tools, editing ];
}

@end
