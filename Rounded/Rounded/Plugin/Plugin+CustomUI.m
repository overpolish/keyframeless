/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>

@implementation RoundedPlugin (CustomUI)

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamCropGroup) {
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"crop"
                              accessibilityDescription:nil];
    KKCustomGroupHeaderView *header =
        [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                            apiManager:self.apiManager
                                           parameterId:parameterID
                                                  text:@"Crop"
                                                  icon:icon
                                         showsCheckbox:NO];

    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];

    static pid_t sInitializedPID = 0;
    pid_t currentPID = getpid();
    BOOL isNewProcess = (sInitializedPID != currentPID);
    if (isNewProcess)
      sInitializedPID = currentPID;

    BOOL expanded;
    if (isNewProcess) {
      expanded = YES;
      id<FxParameterSettingAPI_v5> setAPI =
          [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      [setAPI setBoolValue:YES
               toParameter:kParamCropExpanded
                    atTime:[actionAPI currentTime]];
    } else {
      expanded = NO;
      id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager
          apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
      [paramGetAPI getBoolValue:&expanded
                  fromParameter:kParamCropExpanded
                         atTime:[actionAPI currentTime]];
    }
    header.isExpanded = expanded;
    header.isEnabled = YES;

    [actionAPI endAction:self];

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
               toParameter:kParamCropExpanded
                    atTime:[actAPI currentTime]];
      [actAPI endAction:strongSelf];
    };

    return header;
  }

  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

@end
