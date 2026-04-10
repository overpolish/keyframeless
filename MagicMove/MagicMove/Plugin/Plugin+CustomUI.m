/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/NSView.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <objc/runtime.h>

@interface KKPlugin (TimingGraph)
- (void)timingGraphApplyState;
@end

@interface MagicMovePreviewClearTarget : NSObject
@property(nonatomic, weak) id<PROAPIAccessing> apiManager;
- (void)clearPreviews:(id)sender;
@end

@implementation MagicMovePreviewClearTarget
- (void)clearPreviews:(id)sender {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  id<FxTimingAPI_v4> timingAPI =
      [_apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  CMTime now = kCMTimeZero;
  if (timingAPI) {
    CMTime start = kCMTimeZero;
    [timingAPI startTimeForEffect:&start];
    now = start;
  }
  UInt32 previews[] = {kParamPreviewA, kParamPreviewB, kParamPreviewDrift,
                       kParamPreviewExit};
  for (int i = 0; i < 4; i++)
    [paramSetAPI setBoolValue:NO toParameter:previews[i] atTime:now];
  [actionAPI endAction:self];
}
@end

@interface MagicMoveShowOSCTarget : NSObject
@property(nonatomic, weak) id<PROAPIAccessing> apiManager;
- (void)showAll:(id)sender;
@end

@implementation MagicMoveShowOSCTarget
- (void)showAll:(id)sender {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [_apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  id<FxTimingAPI_v4> timingAPI =
      [_apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  CMTime now = kCMTimeZero;
  if (timingAPI) {
    CMTime start = kCMTimeZero;
    [timingAPI startTimeForEffect:&start];
    now = start;
  }
  UInt32 hideParams[] = {kParamHideOSCA, kParamHideOSCB, kParamHideOSCDrift,
                         kParamHideOSCExit};
  for (int i = 0; i < 4; i++)
    [paramSetAPI setBoolValue:NO toParameter:hideParams[i] atTime:now];
  [actionAPI endAction:self];
}
@end

@implementation MagicMovePlugin (CustomUI)

- (NSArray<KKTimingSlot *> *)timingGlobalSlots {
  return @[];
}

- (KKTimingSlot *)_rotateWithMotionSlotForParam:(UInt32)paramID {
  KKParameterRowView *row = [[KKParameterRowView alloc]
      initWithFrame:NSMakeRect(0, 0, 300, KKInspectorRowHeight)
         apiManager:self.apiManager
        parameterId:paramID];

  KKLabelView *label = [[KKLabelView alloc] initWithText:@"Rotate with Motion"];
  row.leftView = label;

  NSView *rightContainer = [[NSView alloc] initWithFrame:NSZeroRect];
  KKCheckboxView *checkbox = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
  checkbox.translatesAutoresizingMaskIntoConstraints = NO;
  [rightContainer addSubview:checkbox];
  [NSLayoutConstraint activateConstraints:@[
    [checkbox.trailingAnchor
        constraintEqualToAnchor:rightContainer.trailingAnchor
                       constant:-23.0],
    [checkbox.centerYAnchor
        constraintEqualToAnchor:rightContainer.centerYAnchor],
    [checkbox.widthAnchor constraintEqualToConstant:12.0],
    [checkbox.heightAnchor constraintEqualToConstant:12.0],
  ]];
  row.rightView = rightContainer;

  __weak typeof(self) weakSelf = self;
  checkbox.onToggle = ^(BOOL isChecked) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setBoolValue:isChecked
             toParameter:paramID
                  atTime:[actAPI currentTime]];
    [actAPI endAction:strongSelf];
  };

  return [KKTimingSlot
      slotWithView:row
            height:KKInspectorRowHeight
        applyState:^(id<FxParameterRetrievalAPI_v6> paramAPI, CMTime time) {
          BOOL val = NO;
          [paramAPI getBoolValue:&val fromParameter:paramID atTime:time];
          checkbox.isChecked = val;
        }];
}

- (NSArray<KKTimingSlot *> *)timingSlotsForSection:(NSInteger)section {
  static const UInt32 rwmParams[] = {kParamRotateWithMotionIn,
                                     kParamRotateWithMotionHold,
                                     kParamRotateWithMotionOut};
  return @[ [self _rotateWithMotionSlotForParam:rwmParams[section]] ];
}

- (NSArray<KKAnimatableProperty *> *)animatableProperties {
  return @[
    [KKAnimatableProperty propertyWithLabel:@"Pos X"
                                       inID:kParamInPositionX
                                     holdID:kParamHoldPositionX
                                      outID:kParamOutPositionX],
    [KKAnimatableProperty propertyWithLabel:@"Pos Y"
                                       inID:kParamInPositionY
                                     holdID:kParamHoldPositionY
                                      outID:kParamOutPositionY],
    [KKAnimatableProperty propertyWithLabel:@"Sca X"
                                       inID:kParamInScaleX
                                     holdID:kParamHoldScaleX
                                      outID:kParamOutScaleX],
    [KKAnimatableProperty propertyWithLabel:@"Sca Y"
                                       inID:kParamInScaleY
                                     holdID:kParamHoldScaleY
                                      outID:kParamOutScaleY],
    [KKAnimatableProperty propertyWithLabel:@"Rot Z"
                                       inID:kParamInRotationZ
                                     holdID:kParamHoldRotationZ
                                      outID:kParamOutRotationZ],
    [KKAnimatableProperty propertyWithLabel:@"Rot X"
                                       inID:kParamInRotationX
                                     holdID:kParamHoldRotationX
                                      outID:kParamOutRotationX],
    [KKAnimatableProperty propertyWithLabel:@"Rot Y"
                                       inID:kParamInRotationY
                                     holdID:kParamHoldRotationY
                                      outID:kParamOutRotationY],
    [KKAnimatableProperty propertyWithLabel:@"Opa"
                                       inID:kParamInOpacity
                                     holdID:kParamHoldOpacity
                                      outID:kParamOutOpacity],
  ];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamGroupPointA) {
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"circle.circle"
                              accessibilityDescription:nil];
    KKCustomGroupHeaderView *header =
        [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                            apiManager:self.apiManager
                                           parameterId:parameterID
                                                  text:@"Point A"
                                                  icon:icon
                                         showsCheckbox:NO];

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
               toParameter:kParamExpandedA
                    atTime:[actAPI currentTime]];
      [actAPI endAction:strongSelf];
    };

    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    CMTime currentTime = [actionAPI currentTime];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    BOOL animIn = NO, animOut = NO, exitOn = NO;
    [paramGetAPI getBoolValue:&animIn
                fromParameter:kKKParamAnimateIn
                       atTime:currentTime];
    [paramGetAPI getBoolValue:&animOut
                fromParameter:kKKParamAnimateOut
                       atTime:currentTime];
    [paramGetAPI getBoolValue:&exitOn
                fromParameter:kParamExit
                       atTime:currentTime];

    BOOL showA = animIn || (animOut && !exitOn);
    header.isEnabled = showA;
    if (!showA) {
      header.statusText = (!animIn && !animOut)
                              ? @"Enable Animate In or Out"
                              : @"Overridden by Exit and Animate In is off";
    }
    if (showA) {
      BOOL expanded = NO;
      [paramGetAPI getBoolValue:&expanded
                  fromParameter:kParamExpandedA
                         atTime:currentTime];
      header.isExpanded = expanded;
    }

    [actionAPI endAction:self];

    self.pointAHeader = header;
    return header;
  }
  if (parameterID == kParamGroupPointB) {
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"circle.circle"
                              accessibilityDescription:nil];
    KKCustomGroupHeaderView *header =
        [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                            apiManager:self.apiManager
                                           parameterId:parameterID
                                                  text:@"Point B"
                                                  icon:icon
                                         showsCheckbox:NO];
    header.isEnabled = YES;

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
               toParameter:kParamExpandedB
                    atTime:[actAPI currentTime]];
      [actAPI endAction:strongSelf];
    };

    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    BOOL expanded = NO;
    [paramGetAPI getBoolValue:&expanded
                fromParameter:kParamExpandedB
                       atTime:[actionAPI currentTime]];
    header.isExpanded = expanded;

    [actionAPI endAction:self];

    self.pointBHeader = header;
    return header;
  }
  if (parameterID == kParamGroupDrift) {
    NSImage *icon =
        [NSImage imageWithSystemSymbolName:@"circle.dotted.and.circle"
                  accessibilityDescription:nil];
    KKCustomGroupHeaderView *header =
        [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                            apiManager:self.apiManager
                                           parameterId:parameterID
                                                  text:@"Drift"
                                                  icon:icon
                                         showsCheckbox:YES];

    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    CMTime currentTime = [actionAPI currentTime];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    BOOL enabled = NO;
    [paramGetAPI getBoolValue:&enabled
                fromParameter:kParamDrift
                       atTime:currentTime];
    header.isEnabled = enabled;

    if (enabled) {
      BOOL expanded = NO;
      [paramGetAPI getBoolValue:&expanded
                  fromParameter:kParamExpandedDrift
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
               toParameter:kParamDrift
                    atTime:[actAPI currentTime]];
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
      [setAPI setBoolValue:isExpanded
               toParameter:kParamExpandedDrift
                    atTime:[actAPI currentTime]];
      [actAPI endAction:strongSelf];
    };
    self.driftHeader = header;
    return header;
  }
  if (parameterID == kParamGroupExit) {
    NSImage *icon = [NSImage
        imageWithSystemSymbolName:@"arrowshape.turn.up.right.circle.fill"
         accessibilityDescription:nil];
    KKCustomGroupHeaderView *header =
        [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                            apiManager:self.apiManager
                                           parameterId:parameterID
                                                  text:@"Exit"
                                                  icon:icon
                                         showsCheckbox:YES];

    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    CMTime currentTime = [actionAPI currentTime];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    BOOL exitOn = NO, animOut = NO;
    [paramGetAPI getBoolValue:&exitOn
                fromParameter:kParamExit
                       atTime:currentTime];
    [paramGetAPI getBoolValue:&animOut
                fromParameter:kKKParamAnimateOut
                       atTime:currentTime];
    header.isEnabled = exitOn;

    if (exitOn && !animOut) {
      header.statusText = @"Enable Animate Out";
    }

    if (exitOn) {
      BOOL expanded = NO;
      [paramGetAPI getBoolValue:&expanded
                  fromParameter:kParamExpandedExit
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
               toParameter:kParamExit
                    atTime:[actAPI currentTime]];
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
      [setAPI setBoolValue:isExpanded
               toParameter:kParamExpandedExit
                    atTime:[actAPI currentTime]];
      [actAPI endAction:strongSelf];
    };

    self.exitHeader = header;
    return header;
  }
  if (parameterID == kParamInfoCompound) {
    // Info alert
    NSArray<NSAttributedString *> *pages = @[
      [KKMarkup attributedStringFromMarkup:
                    @"Create a Compound Clip <kbd>⌥ G</kbd> before applying "
                    @"to avoid clipping"],
      [KKMarkup attributedStringFromMarkup:
                    @"<kbd>⌘ + click</kbd> a point to show or hide its "
                    @"controls"],
      [KKMarkup attributedStringFromMarkup:
                    @"<kbd>⌥ + click</kbd> the path to add or remove a "
                    @"control point"],
      [KKMarkup attributedStringFromMarkup:
                    @"Double-click a point to toggle between linear and "
                    @"bezier"],
      [KKMarkup attributedStringFromMarkup:
                    @"Hold <kbd>⌥</kbd> to move a bezier handle "
                    @"independently"],
      [KKMarkup attributedStringFromMarkup:
                    @"Hold <kbd>Shift</kbd> while dragging to constrain to "
                    @"X or Y axis"],
      [KKMarkup attributedStringFromMarkup:
                    @"Hold <kbd>⌃</kbd> while dragging to disable snapping"],
      [KKMarkup attributedStringFromMarkup:
                    @"Hold <kbd>⌥</kbd> to show X and Y rotation rings"],
      [KKMarkup attributedStringFromMarkup:
                    @"Hold <kbd>Shift</kbd> while scaling to lock to X or Y"],
      [KKMarkup attributedStringFromMarkup:
                    @"Double-click the scale ring to reset to 1:1 ratio"],
      [KKMarkup attributedStringFromMarkup:
                    @"<symbol squareshape.fill color=white /> toggles scale "
                    @"between 0\% and 100\%"],
      [KKMarkup attributedStringFromMarkup:
                    @"<symbol circle.fill color=white /> toggles opacity "
                    @"between 0\% and 100\%"],
      [KKMarkup attributedStringFromMarkup:
                    @"<symbol eye.fill color=white /> previews the clip at "
                    @"that point"],
    ];
    KKAlertView *infoAlert =
        [[KKAlertView alloc] initWithAttributedText:pages.firstObject];
    infoAlert.icon = [NSImage imageWithSystemSymbolName:@"info.circle"
                               accessibilityDescription:nil];
    infoAlert.attributedPages = pages;

    // Warning alerts
    KKAlertView *previewAlert =
        [[KKAlertView alloc] initWithText:@"Preview mode is active"
                                    color:[NSColor warning]];
    previewAlert.icon = [NSImage imageWithSystemSymbolName:@"eye.fill"
                                  accessibilityDescription:nil];
    [self _addRenderedText:@"Preview mode is active"
                     color:[NSColor warning]
                   toAlert:previewAlert];

    MagicMovePreviewClearTarget *clearTarget =
        [[MagicMovePreviewClearTarget alloc] init];
    clearTarget.apiManager = self.apiManager;
    NSButton *clearBtn = [NSButton buttonWithTitle:@"Clear"
                                            target:clearTarget
                                            action:@selector(clearPreviews:)];
    clearBtn.controlSize = NSControlSizeSmall;
    clearBtn.bezelStyle = NSBezelStyleAccessoryBarAction;
    clearBtn.contentTintColor = [NSColor warning];
    objc_setAssociatedObject(clearBtn, "clearTarget", clearTarget,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    previewAlert.accessoryView = clearBtn;

    KKAlertView *hideOSCAlert =
        [[KKAlertView alloc] initWithText:@"Some controls are hidden"
                                    color:[NSColor warning]];
    hideOSCAlert.icon = [NSImage imageWithSystemSymbolName:@"circle.slash.fill"
                                  accessibilityDescription:nil];
    [self _addRenderedText:@"Some controls are hidden"
                     color:[NSColor warning]
                   toAlert:hideOSCAlert];

    MagicMoveShowOSCTarget *showTarget = [[MagicMoveShowOSCTarget alloc] init];
    showTarget.apiManager = self.apiManager;
    NSButton *showBtn = [NSButton buttonWithTitle:@"Show All"
                                           target:showTarget
                                           action:@selector(showAll:)];
    showBtn.controlSize = NSControlSizeSmall;
    showBtn.bezelStyle = NSBezelStyleAccessoryBarAction;
    showBtn.contentTintColor = [NSColor warning];
    objc_setAssociatedObject(showBtn, "showTarget", showTarget,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    hideOSCAlert.accessoryView = showBtn;

    self.previewAlertView = previewAlert;
    self.hideOSCAlertView = hideOSCAlert;

    KKAlertStackView *stack = [[KKAlertStackView alloc]
        initWithDefaultAlert:infoAlert
                  apiManager:self.apiManager
          persistParameterID:kParamAlertStackSelected];
    [stack addAlert:previewAlert priority:0];
    [stack addAlert:hideOSCAlert priority:1];

    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    CMTime now = [actionAPI currentTime];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    BOOL pA = NO, pB = NO, pD = NO, pE = NO;
    [paramGetAPI getBoolValue:&pA fromParameter:kParamPreviewA atTime:now];
    [paramGetAPI getBoolValue:&pB fromParameter:kParamPreviewB atTime:now];
    [paramGetAPI getBoolValue:&pD fromParameter:kParamPreviewDrift atTime:now];
    [paramGetAPI getBoolValue:&pE fromParameter:kParamPreviewExit atTime:now];
    BOOL hA = NO, hB = NO, hD = NO, hE = NO;
    [paramGetAPI getBoolValue:&hA fromParameter:kParamHideOSCA atTime:now];
    [paramGetAPI getBoolValue:&hB fromParameter:kParamHideOSCB atTime:now];
    [paramGetAPI getBoolValue:&hD fromParameter:kParamHideOSCDrift atTime:now];
    [paramGetAPI getBoolValue:&hE fromParameter:kParamHideOSCExit atTime:now];
    [actionAPI endAction:self];

    [stack setAlert:previewAlert active:(pA || pB || pD || pE)];
    [stack setAlert:hideOSCAlert active:(hA || hB || hD || hE)];

    self.alertStackView = stack;
    return stack;
  }

  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

- (void)_addRenderedText:(NSString *)text
                   color:(NSColor *)color
                 toAlert:(KKAlertView *)alert {
  NSFont *font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]
                                   weight:NSFontWeightLight];
  NSDictionary *attrs = @{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : color,
  };
  NSSize textSize = [text sizeWithAttributes:attrs];
  NSImage *img = [[NSImage alloc]
      initWithSize:NSMakeSize(ceil(textSize.width), ceil(textSize.height))];
  [img lockFocus];
  [text drawAtPoint:NSZeroPoint withAttributes:attrs];
  [img unlockFocus];

  NSImageView *iv = [NSImageView imageViewWithImage:img];
  iv.translatesAutoresizingMaskIntoConstraints = NO;
  iv.imageScaling = NSImageScaleNone;
  iv.imageAlignment = NSImageAlignLeft;
  [alert addSubview:iv];

  // Position over the label area: after icon, vertically centered in content.
  NSView *content = alert.subviews.firstObject;
  [NSLayoutConstraint activateConstraints:@[
    [iv.leadingAnchor
        constraintEqualToAnchor:content.leadingAnchor
                       constant:KKSpacingMD * 1.5 + 12.0 + KKSpacingMD],
    [iv.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                      constant:-KKSpacingMD],
    [iv.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
  ]];
}

@end
