/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <objc/message.h>
#import <objc/runtime.h>

@interface KKPlugin (TimingGraph)
- (void)timingGraphApplyState;
@end

@implementation GlowPlugin (CustomUI)

- (NSArray<KKTimingSlot *> *)timingSlotsForSection:(NSInteger)section {
  return @[];
}

- (NSView *)holdPropertyView {
  static const UInt32 holdParams[] = {kParamHoldRadius, kParamHoldIntensity,
                                      kParamHoldFalloff, kParamHoldOffset};
  static const NSInteger holdCount = 4;

  KKPillToggleRowView *toggles = [[KKPillToggleRowView alloc]
      initWithLabels:@[ @"Radius", @"Intensity", @"Falloff", @"Offset" ]];
  objc_setAssociatedObject([self class], @selector(holdPropertyView), toggles,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  __weak typeof(self) weakSelf = self;
  toggles.onToggled = ^(NSInteger index, BOOL isOn) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || index >= holdCount)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setBoolValue:isOn
             toParameter:holdParams[index]
                  atTime:[actAPI currentTime]];
    [actAPI endAction:strongSelf];
  };

  return toggles;
}

- (CGFloat)holdPropertyViewHeight {
  return 18.0;
}

- (void (^)(id, CMTime))holdPropertyApplyState {
  static const UInt32 holdParams[] = {kParamHoldRadius, kParamHoldIntensity,
                                      kParamHoldFalloff, kParamHoldOffset};
  static const NSInteger holdCount = 4;
  return [^(id paramAPI, CMTime time) {
    KKPillToggleRowView *toggles =
        objc_getAssociatedObject([self class], @selector(holdPropertyView));
    if (!toggles)
      return;
    for (NSInteger i = 0; i < holdCount; i++) {
      BOOL val = YES;
      [paramAPI getBoolValue:&val fromParameter:holdParams[i] atTime:time];
      [toggles setState:val atIndex:i];
    }
  } copy];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamOffsetGroup)
    return [self createGroupHeaderWithTitle:@"Offset"
                                       icon:nil
                                parameterID:parameterID
                            expandedParamID:kParamOffsetExpanded];

  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

@end
