/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKAlertView.h"
#import "KKCustomGroupHeaderView.h"
#import "KKDataBlob.h"
#import "KKLog.h"
#import "KKLogoBannerView.h"
#import "KKPlugin+Color.h"
#import "KKPlugin_Private.h"
#import "KKRemoteWindowKeyHandlerView.h"
#import "KKSeparatorView.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKConstants.h>

NSUserInterfaceItemIdentifier const KKRemoteWindowContentID =
    @"KKRemoteWindowContent";

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation KKPlugin (CustomViews)

- (NSRect)effectHeaderScreenRect {
  return self.logoBanner ? [self.logoBanner effectHeaderScreenRect]
                         : NSZeroRect;
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kKKParamLogoBanner) {
    KKLogoBannerView *banner = [[KKLogoBannerView alloc] init];
    self.logoBanner = banner; // per-instance, for guide header anchoring
    if ([self helpSections].count > 0) {
      __weak typeof(self) weakSelf = self;
      banner.onHelpTap = ^{
        [weakSelf openHelpRemoteWindow];
      };
    }
    NSView *aiAccessory = [self aiAccessoryView];
    if (aiAccessory)
      [banner setLeadingAccessoryView:aiAccessory];
    return banner;
  }

  if (parameterID == kKKParamColorGroup)
    return [self
        createGroupHeaderWithTitle:@"Color Style"
                              icon:[NSImage
                                       imageWithSystemSymbolName:@"paintpalette"
                                        accessibilityDescription:nil]
                       parameterID:parameterID
                   expandedParamID:kKKParamColorExpanded];

  if (parameterID == kKKParamColorCustomUI)
    return [self _createColorCustomUI:parameterID];

  if (parameterID == kKKParamAnimationSeparator)
    return [self _createTimingHeader:parameterID];

  if (parameterID == kKKParamMotionBlurSeparator)
    return [self _createMotionBlurHeader:parameterID];

  if (parameterID == kKKParamTimingCurvePreview)
    return [self _createTimingGraphViewUncapped:NO];

  NSString *separatorText =
      kkClassRegistry([self class], kKKSepTexts)[@(parameterID)];
  if (separatorText) {
    return [[KKSeparatorView alloc]
        initWithText:(separatorText.length > 0 ? separatorText : nil)
                icon:kkClassRegistry([self class],
                                     kKKSepIcons)[@(parameterID)]];
  }

  NSAttributedString *attributedText =
      kkClassRegistry([self class], kKKInfoAttrTexts)[@(parameterID)];
  if (attributedText) {
    KKAlertView *infoView =
        [[KKAlertView alloc] initWithAttributedText:attributedText];
    infoView.icon = kkClassRegistry([self class], kKKInfoIcons)[@(parameterID)];
    return infoView;
  }

  NSString *text = kkClassRegistry([self class], kKKInfoTexts)[@(parameterID)];
  if (!text)
    return nil;

  KKAlertView *infoView = [[KKAlertView alloc] initWithText:text];
  infoView.icon = kkClassRegistry([self class], kKKInfoIcons)[@(parameterID)];
  return infoView;
}

- (NSView *)createGroupHeaderWithTitle:(NSString *)title
                                  icon:(nullable NSImage *)icon
                           parameterID:(UInt32)parameterID
                       expandedParamID:(UInt32)expandedParamID
    NS_RETURNS_RETAINED {
  KKCustomGroupHeaderView *header =
      [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                          apiManager:self.apiManager
                                         parameterId:parameterID
                                                text:title
                                                icon:icon
                                       showsCheckbox:NO];

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  header.isExpanded = KKReadCustomParamBool(paramGetAPI, expandedParamID);
  header.isEnabled = YES;

  [actionAPI endAction:self];

  if (!self.genericGroupHeaders)
    self.genericGroupHeaders = [NSMapTable strongToWeakObjectsMapTable];
  [self.genericGroupHeaders setObject:header forKey:@(expandedParamID)];

  __weak typeof(self) weakSelf = self;
  header.onExpandedChanged = ^(BOOL isExpanded) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    KKWriteCustomParamBool(setAPI, isExpanded, expandedParamID);
    [actAPI endAction:strongSelf];
  };

  return header;
}

- (KKCustomGroupHeaderView *)
    createCheckboxGroupHeaderWithTitle:(NSString *)title
                                  icon:(nullable NSImage *)icon
                        enabledParamID:(UInt32)enabledParamID
                       expandedParamID:(UInt32)expandedParamID
                        onEnabledExtra:(void (^_Nullable)(
                                           BOOL isEnabled,
                                           id<FxParameterSettingAPI_v5> setAPI))
                                           onEnabledExtra
                       onExpandedExtra:(void (^_Nullable)(
                                           BOOL isExpanded,
                                           id<FxParameterSettingAPI_v5> setAPI))
                                           onExpandedExtra {
  KKCustomGroupHeaderView *header =
      [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                          apiManager:self.apiManager
                                         parameterId:enabledParamID
                                                text:title
                                                icon:icon
                                       showsCheckbox:YES];

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  CMTime currentTime = [actionAPI currentTime];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled
              fromParameter:enabledParamID
                     atTime:currentTime];
  header.isEnabled = enabled;
  header.isExpanded = KKReadCustomParamBool(paramGetAPI, expandedParamID);
  [actionAPI endAction:self];

  __weak typeof(self) weakSelf = self;
  void (^onEnabledExtraCopy)(BOOL, id<FxParameterSettingAPI_v5>) =
      [onEnabledExtra copy];
  void (^onExpandedExtraCopy)(BOOL, id<FxParameterSettingAPI_v5>) =
      [onExpandedExtra copy];

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
             toParameter:enabledParamID
                  atTime:[actAPI currentTime]];
    if (onEnabledExtraCopy)
      onEnabledExtraCopy(isEnabled, setAPI);
    [actAPI endAction:strongSelf];
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
    KKWriteCustomParamBool(setAPI, isExpanded, expandedParamID);
    if (onExpandedExtraCopy)
      onExpandedExtraCopy(isExpanded, setAPI);
    [actAPI endAction:strongSelf];
  };

  [self registerGroupHeader:header
             enabledParamID:enabledParamID
            expandedParamID:expandedParamID];

  return header;
}

- (void)syncGroupHeaderExpandedForExpandedParamID:(UInt32)expandedParamID {
  KKCustomGroupHeaderView *header =
      [self.genericGroupHeaders objectForKey:@(expandedParamID)];
  if (!header)
    return;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return;
  BOOL expanded = KKReadCustomParamBool(getAPI, expandedParamID);
  __weak KKCustomGroupHeaderView *weakHeader = header;
  KKRunOnMain(^{
    if (weakHeader.isExpanded != expanded)
      weakHeader.isExpanded = expanded;
  });
}

- (void)syncGroupHeaderEnabledForEnabledParamID:(UInt32)enabledParamID
                                         atTime:(CMTime)time {
  KKCustomGroupHeaderView *header =
      [self.genericGroupHeadersByEnabledParamID objectForKey:@(enabledParamID)];
  if (!header)
    return;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return;
  BOOL enabled = NO;
  [getAPI getBoolValue:&enabled fromParameter:enabledParamID atTime:time];
  __weak KKCustomGroupHeaderView *weakHeader = header;
  KKRunOnMain(^{
    if (weakHeader.isEnabled != enabled)
      weakHeader.isEnabled = enabled;
  });
}

- (void)kkWriteLanesJSON:(NSArray<KKTimingLane *> *)lanes
                  setAPI:(id<FxParameterSettingAPI_v5>)setAPI {
  KKWriteLanesJSON(lanes, setAPI, self.apiManager);
}

- (void)registerGroupHeader:(KKCustomGroupHeaderView *)header
             enabledParamID:(UInt32)enabledParamID
            expandedParamID:(UInt32)expandedParamID {
  if (!header)
    return;
  if (!self.genericGroupHeaders)
    self.genericGroupHeaders = [NSMapTable strongToWeakObjectsMapTable];
  [self.genericGroupHeaders setObject:header forKey:@(expandedParamID)];
  if (enabledParamID != 0) {
    if (!self.genericGroupHeadersByEnabledParamID)
      self.genericGroupHeadersByEnabledParamID =
          [NSMapTable strongToWeakObjectsMapTable];
    [self.genericGroupHeadersByEnabledParamID setObject:header
                                                 forKey:@(enabledParamID)];
  }
}

- (void)presentRemoteWindowOfSize:(CGSize)size
                  contentProvider:(NSView * (^)(void))contentProvider {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI) {
    KKLogError(@"FxCustomParameterActionAPI_v4 unavailable");
    return;
  }
  [actionAPI startAction:self];

  id<FxRemoteWindowAPI> windowAPI =
      [self.apiManager apiForProtocol:@protocol(FxRemoteWindowAPI)];
  if (!windowAPI) {
    KKLogError(@"FxRemoteWindowAPI unavailable");
    [actionAPI endAction:self];
    return;
  }

  __weak typeof(self) weakSelf = self;
  [windowAPI
      remoteWindowOfSize:size
                   reply:^(FxXPView *parentView, NSError *error) {
                     if (!parentView) {
                       if (error)
                         KKLogError(@"remoteWindow error: %@", error);
                       return;
                     }
                     // The host hands us a parentView at a non-zero origin
                     // in its superview - adding content there right-clips
                     // and offsets the first render. Attach to the superview
                     // (the correctly sized XPC jail).
                     NSView *host = parentView.superview ?: parentView;
                     for (NSView *sub in [host.subviews copy])
                       if ([sub.identifier
                               isEqualToString:KKRemoteWindowContentID])
                         [sub removeFromSuperview];

                     NSView *content =
                         contentProvider ? contentProvider() : nil;
                     if (!content) {
                       [actionAPI endAction:self];
                       return;
                     }

                     // Wrap so Space / Cmd-Z / Cmd-Shift-Z reach the host
                     // command API (which resolves nil outside an action
                     // scope) instead of beeping.
                     KKRemoteWindowKeyHandlerView *keyHandler =
                         [[KKRemoteWindowKeyHandlerView alloc] init];
                     keyHandler.identifier = KKRemoteWindowContentID;
                     keyHandler.translatesAutoresizingMaskIntoConstraints = NO;
                     void (^perform)(FxCommand) = ^(FxCommand command) {
                       __strong typeof(weakSelf) s = weakSelf;
                       if (!s)
                         return;
                       id<FxCustomParameterActionAPI_v4> act = [s.apiManager
                           apiForProtocol:@protocol(
                                              FxCustomParameterActionAPI_v4)];
                       if (!act)
                         return;
                       [act startAction:s];
                       id<FxCommandAPI_v2> cmd = [s.apiManager
                           apiForProtocol:@protocol(FxCommandAPI_v2)];
                       [cmd performCommand:command error:nil];
                       [act endAction:s];
                     };
                     keyHandler.onTogglePlayback = ^{
                       perform(kFxCommand_TogglePlayback);
                     };
                     keyHandler.onUndo = ^{
                       perform(kFxCommand_Undo);
                     };
                     keyHandler.onRedo = ^{
                       perform(kFxCommand_Redo);
                     };
                     [host addSubview:keyHandler];

                     content.translatesAutoresizingMaskIntoConstraints = NO;
                     [keyHandler addSubview:content];
                     [NSLayoutConstraint activateConstraints:@[
                       [keyHandler.leadingAnchor
                           constraintEqualToAnchor:host.leadingAnchor],
                       [keyHandler.trailingAnchor
                           constraintEqualToAnchor:host.trailingAnchor],
                       [keyHandler.topAnchor
                           constraintEqualToAnchor:host.topAnchor],
                       [keyHandler.bottomAnchor
                           constraintEqualToAnchor:host.bottomAnchor],
                       [content.leadingAnchor
                           constraintEqualToAnchor:keyHandler.leadingAnchor],
                       [content.trailingAnchor
                           constraintEqualToAnchor:keyHandler.trailingAnchor],
                       [content.topAnchor
                           constraintEqualToAnchor:keyHandler.topAnchor],
                       [content.bottomAnchor
                           constraintEqualToAnchor:keyHandler.bottomAnchor],
                     ]];
                   }];

  [actionAPI endAction:self];
}

- (void)closeRemoteWindowIfSupported {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  [actionAPI startAction:self];
  id<FxRemoteWindowAPI> windowAPI =
      [self.apiManager apiForProtocol:@protocol(FxRemoteWindowAPI)];
  if ([(id)windowAPI respondsToSelector:@selector(closeRemoteWindow)])
    [(id<FxRemoteWindowAPI_v3>)windowAPI closeRemoteWindow];
  [actionAPI endAction:self];
}

@end

#pragma clang diagnostic pop
