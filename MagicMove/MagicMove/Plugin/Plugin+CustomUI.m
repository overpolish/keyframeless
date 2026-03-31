/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <AppKit/NSView.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <objc/runtime.h>

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

    NSArray<NSNumber *> *childIDs = childIDsForGroup(kGroupA);

    __weak typeof(self) weakSelf = self;
    header.onExpandedChanged = ^(BOOL isExpanded) {
      [weakSelf setGroupExpanded:isExpanded childParamIDs:childIDs];
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
      UInt32 flags = 0;
      [paramGetAPI getParameterFlags:&flags fromParameter:kParamPointA];
      header.isExpanded = (flags & kFxParameterFlag_HIDDEN) == 0;
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

    NSArray<NSNumber *> *childIDs = childIDsForGroup(kGroupB);

    __weak typeof(self) weakSelf = self;
    header.onExpandedChanged = ^(BOOL isExpanded) {
      [weakSelf setGroupExpanded:isExpanded childParamIDs:childIDs];
    };

    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    UInt32 flags = 0;
    [paramGetAPI getParameterFlags:&flags fromParameter:kParamPointB];
    header.isExpanded = (flags & kFxParameterFlag_HIDDEN) == 0;

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
      UInt32 flags = 0;
      [paramGetAPI getParameterFlags:&flags fromParameter:kParamDriftPoint];
      header.isExpanded = (flags & kFxParameterFlag_HIDDEN) == 0;
    }

    [actionAPI endAction:self];

    NSArray<NSNumber *> *childIDs = childIDsForGroup(kGroupDrift);

    __weak typeof(self) weakSelf = self;
    header.onEnabledChanged = ^(BOOL isEnabled) {
      [weakSelf setGroupEnabled:isEnabled
                    boolParamID:kParamDrift
                  childParamIDs:childIDs];
    };
    header.onExpandedChanged = ^(BOOL isExpanded) {
      [weakSelf setGroupExpanded:isExpanded childParamIDs:childIDs];
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
      UInt32 flags = 0;
      [paramGetAPI getParameterFlags:&flags fromParameter:kParamExitPoint];
      header.isExpanded = (flags & kFxParameterFlag_HIDDEN) == 0;
    }

    [actionAPI endAction:self];

    NSArray<NSNumber *> *childIDs = childIDsForGroup(kGroupExit);

    __weak typeof(self) weakSelf = self;
    header.onEnabledChanged = ^(BOOL isEnabled) {
      [weakSelf setGroupEnabled:isEnabled
                    boolParamID:kParamExit
                  childParamIDs:childIDs];
    };
    header.onExpandedChanged = ^(BOOL isExpanded) {
      [weakSelf setGroupExpanded:isExpanded childParamIDs:childIDs];
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
                    @"Hold <kbd>⌥</kbd> while dragging to disable snapping"],
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
