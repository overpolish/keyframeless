/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "RoundedInspectorView.h"
#import <AppKit/AppKit.h>

@implementation RoundedPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamInspectorUI) {
    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    NSString *uiJson = KKReadCustomParamString(getAPI, kParamUIState);
    NSDictionary *uiState =
        uiJson.length
            ? [NSJSONSerialization
                  JSONObjectWithData:[uiJson
                                         dataUsingEncoding:NSUTF8StringEncoding]
                             options:0
                               error:nil]
                  ?: @{}
            : @{};
    BOOL loopEnabled = [uiState[@"loopEnabled"] boolValue];
    NSInteger activeTab = [uiState[@"activeTab"] integerValue];
    [actionAPI endAction:self];

    RoundedInspectorView *view =
        [[RoundedInspectorView alloc] initWithAPIManager:self.apiManager
                                             loopEnabled:loopEnabled
                                               activeTab:activeTab];
    __weak typeof(self) weak = self;

    void (^writeUIState)(NSString *, id) = ^(NSString *key, id value) {
      __strong typeof(weak) strong = weak;
      if (!strong)
        return;
      id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      if (!act)
        return;
      [act startAction:strong];
      id<FxParameterRetrievalAPI_v6> getAPI2 = [strong.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      NSString *existing = KKReadCustomParamString(getAPI2, kParamUIState);
      NSMutableDictionary *state =
          (existing.length
               ? [NSJSONSerialization
                     JSONObjectWithData:
                         [existing dataUsingEncoding:NSUTF8StringEncoding]
                                options:0
                                  error:nil]
               : nil)
              ?: @{};
      state = [state mutableCopy];
      state[key] = value;
      NSString *json = [[NSString alloc]
          initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                       options:0
                                                         error:nil]
              encoding:NSUTF8StringEncoding];
      id<FxParameterSettingAPI_v5> setAPI = [strong.apiManager
          apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      KKWriteCustomParamString(setAPI, json, kParamUIState);
      [act endAction:strong];
    };

    view.onLoopToggled = ^(BOOL enabled) {
      writeUIState(@"loopEnabled", @(enabled));
    };
    view.onTabChanged = ^(NSInteger tab) {
      writeUIState(@"activeTab", @(tab));
    };
    self.inspectorView = view;
    return view;
  }
  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

- (NSArray<KKHelpSection *> *)helpSections {
  KKHelpSection *rounded = [KKHelpSection
      sectionWithTitle:@"Rounded"
             tipMarkup:@[
               (@"Round the corners of any clip with an animatable "
                @"<accent>Radius</accent>."),
               (@"<accent>Box</accent> crops and positions the clip — "
                @"animate it to reveal or hide content over time."),
             ]
             shortcuts:nil];
  rounded.icon = [NSImage imageWithSystemSymbolName:@"square.dotted"
                           accessibilityDescription:nil];
  return @[ rounded ];
}

@end
