/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <objc/message.h>

@implementation GlowPlugin (CustomUI)

- (NSArray<KKTimingSlot *> *)timingSlotsForSection:(NSInteger)section {
  if (section == 1) { // Hold
    return [self _holdPropertySlots];
  }

  KKAlertView *alert = [[KKAlertView alloc]
      initWithText:@"Hold properties only available for Hold"
             color:[[NSColor inspectorLabel] colorWithAlphaComponent:0.3]];
  alert.icon = [NSImage imageWithSystemSymbolName:@"info.circle"
                         accessibilityDescription:nil];
  KKTimingSlot *placeholder =
      [KKTimingSlot slotWithView:alert
                          height:KKInspectorRowHeight * 2
                      applyState:^(id<FxParameterRetrievalAPI_v6> p, CMTime t){
                      }];
  return @[ placeholder ];
}

- (NSArray<KKTimingSlot *> *)_holdPropertySlots {
  static const UInt32 holdParams[] = {kParamHoldRadius, kParamHoldIntensity,
                                      kParamHoldFalloff, kParamHoldOffset};
  static const NSInteger holdCount = 4;

  static const CGFloat kPillRowH = 18.0;

  KKPillToggleRowView *row1 = [[KKPillToggleRowView alloc]
      initWithLabels:@[ @"Radius", @"Intensity", @"Falloff", @"Offset" ]];
  row1.translatesAutoresizingMaskIntoConstraints = NO;
  [row1.heightAnchor constraintEqualToConstant:kPillRowH].active = YES;

  NSStackView *pills = [NSStackView stackViewWithViews:@[ row1 ]];
  pills.orientation = NSUserInterfaceLayoutOrientationVertical;
  pills.spacing = KKSpacingXS;
  pills.alignment = NSLayoutAttributeTrailing;

  KKParameterRowView *row = [[KKParameterRowView alloc]
      initWithFrame:NSMakeRect(0, 0, 300,
                               KKInspectorRowHeight + KKSpacingSM * 2)
         apiManager:self.apiManager
        parameterId:kParamHoldRadius];

  KKLabelView *label = [[KKLabelView alloc] initWithText:@"Hold Properties"];
  row.leftView = label;

  NSView *rightContainer = [[NSView alloc] initWithFrame:NSZeroRect];
  rightContainer.autoresizingMask = NSViewNotSizable;
  pills.translatesAutoresizingMaskIntoConstraints = NO;
  [rightContainer addSubview:pills];
  [NSLayoutConstraint activateConstraints:@[
    [pills.trailingAnchor constraintEqualToAnchor:rightContainer.trailingAnchor
                                         constant:-23.0],
    [pills.centerYAnchor constraintEqualToAnchor:rightContainer.centerYAnchor],
    [pills.leadingAnchor
        constraintGreaterThanOrEqualToAnchor:rightContainer.leadingAnchor],
    [pills.topAnchor
        constraintGreaterThanOrEqualToAnchor:rightContainer.topAnchor
                                    constant:KKSpacingSM],
    [pills.bottomAnchor
        constraintLessThanOrEqualToAnchor:rightContainer.bottomAnchor
                                 constant:-KKSpacingSM],
  ]];
  row.rightView = rightContainer;

  __weak typeof(self) weakSelf = self;
  row1.onToggled = ^(NSInteger index, BOOL isOn) {
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

  KKTimingSlot *slot = [KKTimingSlot
      slotWithView:row
            height:KKInspectorRowHeight + KKSpacingSM * 2
        applyState:^(id<FxParameterRetrievalAPI_v6> paramAPI, CMTime time) {
          for (NSInteger i = 0; i < holdCount; i++) {
            BOOL val = YES;
            [paramAPI getBoolValue:&val
                     fromParameter:holdParams[i]
                            atTime:time];
            [row1 setState:val atIndex:i];
          }
        }];

  return @[ slot ];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamInfoUsage) {
    NSAttributedString *text = [KKMarkup
        attributedStringFromMarkup:
            @"Use on an Adjustment Clip <kbd>⌥ A</kbd> or a Compound Clip "
            @"<kbd>⌥ G</kbd>"];
    KKAlertView *alert = [[KKAlertView alloc] initWithAttributedText:text];
    alert.icon = [NSImage imageWithSystemSymbolName:@"info.circle"
                           accessibilityDescription:nil];
    return alert;
  }
  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

@end
