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

    // Register store observer — this is the single entry point for all
    // layer list UI, param sync, style view, and header updates.
    __weak KKLayerInstanceState *weakState = state;
    __weak id weakAPI = self.apiManager;
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
                        }];

    // Seed the store so the observer fires on initial setup.
    // drawOSC will take over as the producer on subsequent frames.
    {
      // Seed the store with paths and selection only.
      // Do NOT read enabled/expanded states from params here — FxPlug
      // params may not be initialized yet during createViewForParameterID.
      // The store init has correct defaults (strokeEnabled=YES, rest NO).
      // drawOSC and header callbacks will set the real values once ready.
      NSArray<KKBezierPath *> *seedPaths = @[];
      if (str.length > 0) {
        NSData *blob = [[NSData alloc] initWithBase64EncodedString:str
                                                           options:0];
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
      // Apply immediately — don't wait for observer dispatch.
      // On fresh instances the diff may find no changes (all defaults),
      // but we still need KKShowObjectParams to run.
      KKCanvasRefreshLayerListFromSnapshot([initStore snapshot], state,
                                           self.apiManager);
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

    header.isInteractive = YES;
    {
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
      [actAPI endAction:strongSelf];
      KKModifySelectedPathProperty(strongSelf.apiManager,
                                   ^(KKBezierPath *path) {
                                     path.strokeEnabled = isEnabled;
                                   });
      NSString *sUUID = KKLayerUUIDForAPI(strongSelf.apiManager);
      if (sUUID) {
        KKCanvasStore *s = KKLayerStateForUUID(sUUID).store;
        [s performBatch:^{
          [s setStrokeEnabled:isEnabled];
        }];
      }
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
      [setAPI setBoolValue:isExpanded
               toParameter:kParamExpandedStroke
                    atTime:[actAPI currentTime]];
      [actAPI endAction:strongSelf];
      NSString *sUUID2 = KKLayerUUIDForAPI(strongSelf.apiManager);
      if (sUUID2) {
        KKCanvasStore *s = KKLayerStateForUUID(sUUID2).store;
        [s performBatch:^{
          [s setStrokeExpanded:isExpanded];
        }];
      }
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

    header.isInteractive = YES;
    {
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
      [actAPI endAction:strongSelf];
      KKModifySelectedPathProperty(strongSelf.apiManager,
                                   ^(KKBezierPath *path) {
                                     path.fillEnabled = isEnabled;
                                   });
      NSString *fUUID = KKLayerUUIDForAPI(strongSelf.apiManager);
      if (fUUID) {
        KKCanvasStore *fs = KKLayerStateForUUID(fUUID).store;
        [fs performBatch:^{
          [fs setFillEnabled:isEnabled];
        }];
      }
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
      [setAPI setBoolValue:isExpanded
               toParameter:kParamExpandedFill
                    atTime:[actAPI currentTime]];
      [actAPI endAction:strongSelf];
      NSString *fUUID2 = KKLayerUUIDForAPI(strongSelf.apiManager);
      if (fUUID2) {
        KKCanvasStore *fs = KKLayerStateForUUID(fUUID2).store;
        [fs performBatch:^{
          [fs setFillExpanded:isExpanded];
        }];
      }
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

    header.isInteractive = YES;
    {
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
      [actAPI endAction:strongSelf];
      KKModifySelectedPathProperty(strongSelf.apiManager,
                                   ^(KKBezierPath *path) {
                                     path.sketchEnabled = isEnabled;
                                     if (isEnabled && path.sketchSeed == 0)
                                       path.sketchSeed = arc4random();
                                   });
      NSString *skUUID = KKLayerUUIDForAPI(strongSelf.apiManager);
      if (skUUID) {
        KKCanvasStore *sks = KKLayerStateForUUID(skUUID).store;
        [sks performBatch:^{
          [sks setSketchEnabled:isEnabled];
        }];
      }
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
      [setAPI setBoolValue:isExpanded
               toParameter:kParamExpandedSketch
                    atTime:[actAPI currentTime]];
      [actAPI endAction:strongSelf];
      NSString *skUUID2 = KKLayerUUIDForAPI(strongSelf.apiManager);
      if (skUUID2) {
        KKCanvasStore *sks = KKLayerStateForUUID(skUUID2).store;
        [sks performBatch:^{
          [sks setSketchExpanded:isExpanded];
        }];
      }
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
    NSString *capUUID = KKLayerUUIDForAPI(self.apiManager);
    capView.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.lineCap = (uint8_t)index;
      });
      if (capUUID)
        KKLayerStateForUUID(capUUID).cachedLineCap = (uint8_t)index;
    };

    // Store weak ref so the layer list refresh can update selectedIndex.
    if (capUUID)
      KKLayerStateForUUID(capUUID).capStyleView = capView;

    return capView;
  }

  if (parameterID == kParamLineJoin) {
    KKJoinStyleView *joinView = [[KKJoinStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    joinView.autoresizingMask = NSViewWidthSizable;

    __weak id weakAPI = self.apiManager;
    NSString *joinUUID = KKLayerUUIDForAPI(self.apiManager);
    joinView.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.lineJoin = (uint8_t)index;
      });
      if (joinUUID)
        KKLayerStateForUUID(joinUUID).cachedLineJoin = (uint8_t)index;
    };

    if (joinUUID)
      KKLayerStateForUUID(joinUUID).joinStyleView = joinView;

    return joinView;
  }

  if (parameterID == kParamStrokeStyle) {
    KKStrokeStyleView *styleView = [[KKStrokeStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    styleView.autoresizingMask = NSViewWidthSizable;

    __weak id weakAPI = self.apiManager;
    NSString *styleUUID = KKLayerUUIDForAPI(self.apiManager);
    styleView.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.strokeStyle = (uint8_t)index;
      });
      if (styleUUID)
        KKLayerStateForUUID(styleUUID).visHash = 0;
      if (styleUUID)
        KKLayerStateForUUID(styleUUID).cachedStrokeStyle = (uint8_t)index;
    };

    if (styleUUID)
      KKLayerStateForUUID(styleUUID).strokeStyleView = styleView;

    return styleView;
  }

  if (parameterID == kParamStartMarker) {
    KKMarkerStyleView *markerView = [[KKMarkerStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    markerView.autoresizingMask = NSViewWidthSizable;
    markerView.isStart = YES;

    __weak id weakAPI = self.apiManager;
    NSString *smUUID = KKLayerUUIDForAPI(self.apiManager);
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
      if (smUUID)
        KKLayerStateForUUID(smUUID).cachedStartMarker = (uint8_t)index;
    };

    if (smUUID)
      KKLayerStateForUUID(smUUID).startMarkerView = markerView;

    return markerView;
  }

  if (parameterID == kParamEndMarker) {
    KKMarkerStyleView *markerView = [[KKMarkerStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    markerView.autoresizingMask = NSViewWidthSizable;
    markerView.isStart = NO;

    __weak id weakAPI = self.apiManager;
    NSString *emUUID = KKLayerUUIDForAPI(self.apiManager);
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
      if (emUUID)
        KKLayerStateForUUID(emUUID).cachedEndMarker = (uint8_t)index;
    };

    if (emUUID)
      KKLayerStateForUUID(emUUID).endMarkerView = markerView;

    return markerView;
  }

  if (parameterID == kParamSketchFillStyle) {
    KKFillStyleView *fillStyleView = [[KKFillStyleView alloc]
        initWithFrame:NSMakeRect(0, 0, 200, KKInspectorRowHeight)];
    fillStyleView.autoresizingMask = NSViewWidthSizable;

    __weak id weakAPI = self.apiManager;
    NSString *fsUUID = KKLayerUUIDForAPI(self.apiManager);
    fillStyleView.onSelectionChanged = ^(NSInteger index) {
      id api = weakAPI;
      if (!api)
        return;
      KKModifySelectedPathProperty(api, ^(KKBezierPath *p) {
        p.sketchFillStyle = (uint8_t)index;
      });
      if (fsUUID) {
        KKLayerStateForUUID(fsUUID).cachedFillStyle = (uint8_t)index;
        KKLayerStateForUUID(fsUUID).visHash = 0;
      }
    };

    if (fsUUID)
      KKLayerStateForUUID(fsUUID).fillStyleView = fillStyleView;

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
