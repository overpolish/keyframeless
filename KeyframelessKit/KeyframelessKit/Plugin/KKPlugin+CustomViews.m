/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../Views/KKAlertView.h"
#import "../Views/KKCustomGroupHeaderView.h"
#import "../Views/KKLogoBannerView.h"
#import "../Views/KKSeparatorView.h"
#import "KKPlugin+Color.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKConstants.h>

NSUserInterfaceItemIdentifier const KKRemoteWindowContentID =
    @"KKRemoteWindowContent";

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation KKPlugin (CustomViews)

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kKKParamLogoBanner) {
    KKLogoBannerView *banner = [[KKLogoBannerView alloc] init];
    if ([self helpSections].count > 0) {
      __weak typeof(self) weakSelf = self;
      banner.onHelpTap = ^{
        [weakSelf openHelpRemoteWindow];
      };
    }
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

  BOOL expanded = NO;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  [paramGetAPI getBoolValue:&expanded
              fromParameter:expandedParamID
                     atTime:[actionAPI currentTime]];
  header.isExpanded = expanded;
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
    [setAPI setBoolValue:isExpanded
             toParameter:expandedParamID
                  atTime:[actAPI currentTime]];
    [actAPI endAction:strongSelf];
  };

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
  BOOL expanded = NO;
  [getAPI getBoolValue:&expanded
         fromParameter:expandedParamID
                atTime:kCMTimeZero];
  __weak KKCustomGroupHeaderView *weakHeader = header;
  KKRunOnMain(^{
    if (weakHeader.isExpanded != expanded)
      weakHeader.isExpanded = expanded;
  });
}

@end

#pragma clang diagnostic pop
