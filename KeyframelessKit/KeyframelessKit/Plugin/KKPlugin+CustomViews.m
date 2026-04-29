/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../KKLog.h"
#import "../Math/KKEasing.h"
#import "../Math/KKTimingStage.h"
#import "../Style/KKTokens.h"
#import "../Views/KKAlertView.h"
#import "../Views/KKCustomGroupHeaderView.h"
#import "../Views/KKHelpSection.h"
#import "../Views/KKHelpView.h"
#import "../Views/KKMarkup.h"
#import "../Views/KKSegmentEditView.h"
#import "../Views/KKSeparatorView.h"
#import "../Views/StageSequencer/KKEmptyLanesView.h"
#import "../Views/StageSequencer/KKLaneVisibilityBar.h"
#import "../Views/StageSequencer/KKRemoteWindowKeyHandlerView.h"
#import "../Views/StageSequencer/KKSequencerScrollView.h"
#import "../Views/StageSequencer/KKStagePlayheadView.h"
#import "../Views/StageSequencer/KKStageSequencerRulerView.h"
#import "../Views/StageSequencer/KKStageSequencerView.h"
#import "KKPlugin+Color.h"

#import "../Views/KKAnimatableProperty.h"
#import "../Views/KKLogoBannerView.h"
#import "KKConstants.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <QuartzCore/QuartzCore.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
// Identifier stamped on the single root subview we add into the remote
// window's host. Lets a subsequent open (help or sequencer) cleanly replace
// prior content without disturbing the host-managed `parentView`.
static NSUserInterfaceItemIdentifier const KKRemoteWindowContentID =
    @"KKRemoteWindowContent";

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

- (NSView *)_createTimingHeader:(UInt32)parameterID {
  NSImage *icon = [NSImage imageWithSystemSymbolName:@"timer"
                            accessibilityDescription:nil];
  KKCustomGroupHeaderView *header =
      [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                          apiManager:self.apiManager
                                         parameterId:parameterID
                                                text:@"Timing"
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
             toParameter:kKKParamTimingExpanded
                  atTime:[actAPI currentTime]];
    [actAPI endAction:strongSelf];
    [strongSelf updateTimingParameterVisibility];
  };

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];

  static pid_t sInitializedPID = 0;
  pid_t currentPID = getpid();
  BOOL isNewProcess = (sInitializedPID != currentPID);
  if (isNewProcess)
    sInitializedPID = currentPID;

  BOOL expanded;
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (isNewProcess) {
    expanded = YES;
    [setAPI setBoolValue:YES
             toParameter:kKKParamTimingExpanded
                  atTime:[actionAPI currentTime]];
  } else {
    expanded = NO;
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    [paramGetAPI getBoolValue:&expanded
                fromParameter:kKKParamTimingExpanded
                       atTime:[actionAPI currentTime]];
  }
  header.isExpanded = expanded;
  // Apply the curve-preview row's flag SYNCHRONOUSLY here (still inside the
  // createView action scope, outside any FCP host action so no cascade).
  // The deferred `updateTimingParameterVisibility` would run after FCP has
  // already laid out the inspector with the persisted (possibly HIDDEN) flag,
  // leaving the row collapsed until the next chevron toggle.
  BOOL show = expanded || [self forceShowAllParameters];
  FxParameterFlags wantFlags =
      show ? (kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_CUSTOM_UI |
              kFxParameterFlag_USE_FULL_VIEW_WIDTH)
           : kFxParameterFlag_HIDDEN;
  [setAPI setParameterFlags:wantFlags toParameter:kKKParamTimingCurvePreview];
  [actionAPI endAction:self];

  NSImage *windowIcon =
      [NSImage imageWithSystemSymbolName:@"macwindow.on.rectangle"
                accessibilityDescription:@"Open in window"];
  __weak typeof(self) weakSelfForWindow = self;
  [header addTrailingButtonWithIcon:windowIcon
                             action:^{
                               [weakSelfForWindow _openTimingRemoteWindow];
                             }];

  self.timingHeader = header;
  return header;
}

- (NSView *)_createMotionBlurHeader:(UInt32)parameterID {
  NSImage *icon = [NSImage imageWithSystemSymbolName:@"figure.walk.motion"
                            accessibilityDescription:nil];
  KKCustomGroupHeaderView *header =
      [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                          apiManager:self.apiManager
                                         parameterId:parameterID
                                                text:@"Motion Blur"
                                                icon:icon
                                       showsCheckbox:YES];

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled
              fromParameter:kKKParamMotionBlurEnabled
                     atTime:[actionAPI currentTime]];
  header.isEnabled = enabled;

  BOOL expanded = NO;
  [paramGetAPI getBoolValue:&expanded
              fromParameter:kKKParamMotionBlurExpanded
                     atTime:[actionAPI currentTime]];
  header.isExpanded = expanded;
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
             toParameter:kKKParamMotionBlurEnabled
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
             toParameter:kKKParamMotionBlurExpanded
                  atTime:[actAPI currentTime]];
    [actAPI endAction:strongSelf];
  };

  return header;
}

- (void)_openTimingRemoteWindow {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];

  id<FxRemoteWindowAPI> windowAPI =
      [self.apiManager apiForProtocol:@protocol(FxRemoteWindowAPI)];
  if (!windowAPI) {
    KKLogError(@"FxRemoteWindowAPI unavailable (apiManager=%@)",
               self.apiManager);
    [actionAPI endAction:self];
    return;
  }

  NSArray<KKAnimatableProperty *> *seqProps = [self animatableProperties];
  CGFloat lanesH = [KKStageSequencerView heightForLaneCount:seqProps.count];
  CGFloat rulerH = [KKStageSequencerRulerView preferredHeight];
  CGFloat contentH = KKPaddingSM + rulerH + lanesH + KKPaddingLG;
  CGSize contentSize = CGSizeMake(300.0, contentH);

  __weak typeof(self) weakSelf = self;
  [windowAPI
      remoteWindowOfSize:contentSize
                   reply:^(FxXPView *parentView, NSError *error) {
                     __strong typeof(weakSelf) strongSelf = weakSelf;
                     if (!strongSelf || !parentView) {
                       if (error)
                         KKLogError(@"remoteWindow error: %@", error);
                       return;
                     }
                     // The host hands us a parent view positioned at
                     // a non-zero origin within its superview; adding
                     // content to it causes right-clipping and a
                     // first-render offset. Attach to the superview
                     // (the XPC jail) which is correctly sized.
                     NSView *host = parentView.superview ?: parentView;
                     for (NSView *sub in [host.subviews copy])
                       if ([sub.identifier
                               isEqualToString:KKRemoteWindowContentID])
                         [sub removeFromSuperview];
                     KKRemoteWindowKeyHandlerView *keyHandler =
                         [[KKRemoteWindowKeyHandlerView alloc]
                             initWithFrame:NSZeroRect];
                     keyHandler.identifier = KKRemoteWindowContentID;
                     keyHandler.translatesAutoresizingMaskIntoConstraints = NO;
                     __weak typeof(strongSelf) weakForKey = strongSelf;
                     keyHandler.onTogglePlayback = ^{
                       __strong typeof(weakForKey) s = weakForKey;
                       if (!s)
                         return;
                       // FxCommandAPI resolves to nil outside an action scope.
                       id<FxCustomParameterActionAPI_v4> actionAPI =
                           [s.apiManager
                               apiForProtocol:
                                   @protocol(FxCustomParameterActionAPI_v4)];
                       if (!actionAPI)
                         return;
                       [actionAPI startAction:s];
                       id<FxCommandAPI_v2> cmd = [s.apiManager
                           apiForProtocol:@protocol(FxCommandAPI_v2)];
                       [cmd performCommand:kFxCommand_TogglePlayback error:nil];
                       [actionAPI endAction:s];
                     };
                     [host addSubview:keyHandler];
                     [NSLayoutConstraint activateConstraints:@[
                       [keyHandler.leadingAnchor
                           constraintEqualToAnchor:host.leadingAnchor],
                       [keyHandler.trailingAnchor
                           constraintEqualToAnchor:host.trailingAnchor],
                       [keyHandler.topAnchor
                           constraintEqualToAnchor:host.topAnchor],
                       [keyHandler.bottomAnchor
                           constraintEqualToAnchor:host.bottomAnchor],
                     ]];

                     NSView *graph =
                         [strongSelf _createTimingGraphViewUncapped:YES];
                     graph.translatesAutoresizingMaskIntoConstraints = NO;
                     [keyHandler addSubview:graph];
                     [NSLayoutConstraint activateConstraints:@[
                       [graph.leadingAnchor
                           constraintEqualToAnchor:keyHandler.leadingAnchor],
                       [graph.trailingAnchor
                           constraintEqualToAnchor:keyHandler.trailingAnchor],
                       [graph.topAnchor
                           constraintEqualToAnchor:keyHandler.topAnchor],
                       [graph.bottomAnchor
                           constraintEqualToAnchor:keyHandler.bottomAnchor],
                     ]];
                   }];

  [actionAPI endAction:self];
}

- (NSArray<KKHelpSection *> *)helpSections {
  return @[];
}

- (KKClipWrappingMode)clipWrappingMode {
  return KKClipWrappingModeNone;
}

+ (nullable NSString *)_clipWrappingTipForMode:(KKClipWrappingMode)mode {
  switch (mode) {
  case KKClipWrappingModeAdjustmentOrCompound:
    return @"Apply on an Adjustment Clip <kbd>⌥ A</kbd> or a Compound Clip "
           @"<kbd>⌥ G</kbd> to avoid unexpected behavior and clipping.";
  case KKClipWrappingModeCompound:
    return @"Wrap your clip in a Compound Clip <kbd>⌥ G</kbd> before applying "
           @"to avoid the animation being clipped at the edges.";
  case KKClipWrappingModeNone:
    return nil;
  }
}

+ (void)_prependClipWrappingTip:(NSString *)tipMarkup
                      toSection:(KKHelpSection *)section {
  NSAttributedString *wrap = [KKMarkup attributedStringFromMarkup:tipMarkup];
  NSMutableArray<NSAttributedString *> *tips = [NSMutableArray array];
  [tips addObject:wrap];
  [tips addObjectsFromArray:section.tips];
  section.tips = tips;
}

+ (KKHelpSection *)_builtInTimingHelpSection {
  NSArray<NSString *> *tips = @[
    (@"Think in <accent>sections</accent>, not keyframes - each lane is a "
     @"chain of <accent>holds</accent> (locked values) and "
     @"<warn>transitions</warn> (interpolations between adjacent holds)."),
    (@"<symbol arcade.stick.console.fill /> on a lane label toggles that "
     @"lane's on-screen control on the canvas."),
    (@"Click <symbol macwindow.on.rectangle /> on the Timing header to pop "
     @"the sequencer out into its own window for more room."),
    (@"Drag the timeline ruler to scrub the playhead; press "
     @"<kbd>Space</kbd> to play and pause. Toggle "
     @"<symbol repeat color=accent /> on the ruler to loop playback."),
    (@"A transition between two holds with the "
     @"same value won't visibly animate - change one side first."),
    (@"Hover a segment to reveal a <symbol graph.2d /> button. Click it "
     @"to change the easing curve (or hold effect) - or "
     @"<kbd>Shift</kbd> + click to apply the same curve to every selected "
     @"segment in all lane."),
    (@"On a multi-component hold (like Radius X/Y), the edit popover has "
     @"a <accent>Linked</accent> toggle - keeps the components' "
     @"proportions locked through the effect, so X/Y stay aspect-locked "
     @"through a wobble."),
    (@"The pill row above the sequencer filters which lanes are visible."),
  ];

  NSArray<KKHelpShortcut *> *shortcuts = @[
    [KKHelpShortcut shortcutWithKeysMarkup:@"Click lane label"
                                descMarkup:@"Disable / enable that lane's "
                                           @"animation"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click pill"
                                descMarkup:@"Solo a lane (or unsolo when "
                                           @"already the only visible lane)"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"Click"
                                descMarkup:@"Select a segment"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"Double-click"
                                descMarkup:@"Split a segment at the cursor"],
    [KKHelpShortcut
        shortcutWithKeysMarkup:@"Right-click"
                    descMarkup:@"Convert between <accent>hold</accent> "
                               @"and <warn>transition</warn>"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌘</kbd> + click"
                                descMarkup:@"Delete the segment"],
    [KKHelpShortcut
        shortcutWithKeysMarkup:@"Drag edge"
                    descMarkup:@"Resize a segment (snaps to other edges, "
                               @"playhead, and ends)"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift</kbd> while dragging"
                                descMarkup:@"Disable snapping"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + drag segment"
                                descMarkup:@"Copy this segment's value onto "
                                           @"another segment"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌃</kbd> + click"
                                descMarkup:@"Lock / unlock the segment's "
                                           @"duration"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌃</kbd> + drag"
                                descMarkup:@"Slide the entire lane in time"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + click"
                                descMarkup:@"Select segments in "
                                           @"every lane"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + double-click"
                                descMarkup:@"Split every lane at this point"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + right-click"
                                descMarkup:@"Toggle hold/transition across "
                                           @"every lane"],
    [KKHelpShortcut
        shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + drag edge"
                    descMarkup:@"Move the matching boundary in every lane"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Shift ⌘</kbd> + click"
                                descMarkup:@"Delete the segment in every lane"],
    [KKHelpShortcut
        shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + <symbol graph.2d />"
                    descMarkup:@"Open curve editor for every lane at once"],
    [KKHelpShortcut
        shortcutWithKeysMarkup:@"<kbd>Shift ⌃</kbd> + click"
                    descMarkup:@"Toggle duration lock across every lane"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"Pinch"
                                descMarkup:@"Zoom the timeline horizontally"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"Two-finger scroll"
                                descMarkup:@"Pan the timeline horizontally"],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>Space</kbd>"
                                descMarkup:@"Play / pause (in the popped-out "
                                           @"window)"],
  ];

  KKHelpSection *timing = [KKHelpSection sectionWithTitle:@"Timing"
                                                tipMarkup:tips
                                                shortcuts:shortcuts];
  timing.icon = [NSImage imageWithSystemSymbolName:@"timer"
                          accessibilityDescription:nil];
  return timing;
}

+ (KKHelpSection *)_builtInMotionBlurHelpSection {
  NSArray<NSString *> *tips = @[
    (@"<accent>Length</accent> is the shutter angle: 0% freezes each "
     @"frame, 50% (default) is a 180° shutter (half a frame of trail), "
     @"100% smears across the full frame."),
    (@"<accent>Quality</accent> controls the sample count - more samples "
     @"means smoother blur but slower renders. Default ~16 samples; the "
     @"slider scales exponentially up to 128."),
    (@"<accent>Transitions only?</accent> skips the blur work on "
     @"<accent>hold</accent> segments, where nothing is moving anyway. "
     @"Big performance win on segments which don't need motion blur."),
    (@"<accent>Adaptive Quality</accent> drops sub-frame resolution "
     @"automatically when playback can't keep up, then restores full "
     @"quality the moment you pause. Probes back to full once a second "
     @"so you don't get stuck in low quality if performance recovers. "
     @"Off during export. Recommended to leave this option on."),
    (@"<warn>Tip:</warn> high Length with low Quality will band visibly. "
     @"If you increase Length, its recommended to increase Quality too."),
  ];

  KKHelpSection *mb = [KKHelpSection sectionWithTitle:@"Motion Blur"
                                            tipMarkup:tips
                                            shortcuts:nil];
  mb.icon = [NSImage imageWithSystemSymbolName:@"figure.walk.motion"
                      accessibilityDescription:nil];
  return mb;
}

- (void)openHelpRemoteWindow {
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

  NSMutableArray<KKHelpSection *> *sections =
      [[self helpSections] mutableCopy] ?: [NSMutableArray array];
  NSString *wrapTip =
      [KKPlugin _clipWrappingTipForMode:[self clipWrappingMode]];
  if (wrapTip.length > 0 && sections.count > 0)
    [KKPlugin _prependClipWrappingTip:wrapTip toSection:sections.firstObject];
  if ([self animatableProperties].count > 0)
    [sections addObject:[KKPlugin _builtInTimingHelpSection]];
  if ([self usesMotionBlur])
    [sections addObject:[KKPlugin _builtInMotionBlurHelpSection]];
  CGSize contentSize = CGSizeMake(500.0, 420.0);
  [windowAPI remoteWindowOfSize:contentSize
                          reply:^(FxXPView *parentView, NSError *error) {
                            if (!parentView) {
                              if (error)
                                KKLogError(@"remoteWindow error: %@", error);
                              return;
                            }
                            NSView *host = parentView.superview ?: parentView;
                            for (NSView *sub in [host.subviews copy])
                              if ([sub.identifier
                                      isEqualToString:KKRemoteWindowContentID])
                                [sub removeFromSuperview];
                            KKHelpView *helpView =
                                [[KKHelpView alloc] initWithSections:sections];
                            helpView.identifier = KKRemoteWindowContentID;
                            helpView.translatesAutoresizingMaskIntoConstraints =
                                NO;
                            [host addSubview:helpView];
                            [NSLayoutConstraint activateConstraints:@[
                              [helpView.leadingAnchor
                                  constraintEqualToAnchor:host.leadingAnchor],
                              [helpView.trailingAnchor
                                  constraintEqualToAnchor:host.trailingAnchor],
                              [helpView.topAnchor
                                  constraintEqualToAnchor:host.topAnchor],
                              [helpView.bottomAnchor
                                  constraintEqualToAnchor:host.bottomAnchor],
                            ]];
                          }];

  [actionAPI endAction:self];
}

/// Stage sequencer container — sticky ruler + vertically-scrolled lanes
/// (capped at 2.5 lanes) with top/bottom shadow overlays. Hidden until
/// multi-stage is enabled. Inspector mode uses fixed height; window (uncapped)
/// mode pins top+bottom so the container stretches with the wrapper.
- (NSView *)_buildSeqContainerInWrapper:(NSView *)wrapper
                              topAnchor:(NSLayoutYAxisAnchor *)topAnchor
                               topInset:(CGFloat)topInset
                               uncapped:(BOOL)uncapped
                          seqContainerH:(CGFloat)seqContainerH {
  NSView *seqContainer = [[NSView alloc] initWithFrame:NSZeroRect];
  seqContainer.translatesAutoresizingMaskIntoConstraints = NO;
  seqContainer.wantsLayer = YES;
  seqContainer.layer.masksToBounds = YES;
  seqContainer.layer.cornerRadius = KKSpacingMD;
  seqContainer.layer.backgroundColor =
      [NSColor colorWithWhite:0.15 alpha:1.0].CGColor;
  seqContainer.layer.borderWidth = KKBorderWidthXS;
  seqContainer.layer.borderColor =
      [NSColor colorWithWhite:1.0 alpha:0.05].CGColor;
  seqContainer.hidden = YES;
  [wrapper addSubview:seqContainer];

  NSMutableArray<NSLayoutConstraint *> *anchors =
      [NSMutableArray arrayWithArray:@[
        [seqContainer.leadingAnchor
            constraintEqualToAnchor:wrapper.leadingAnchor
                           constant:KKInspectorHorizontalInset],
        [seqContainer.trailingAnchor
            constraintEqualToAnchor:wrapper.trailingAnchor
                           constant:-KKInspectorHorizontalInset],
        [seqContainer.topAnchor constraintEqualToAnchor:topAnchor
                                               constant:topInset],
      ]];
  if (uncapped) {
    [anchors addObject:[seqContainer.bottomAnchor
                           constraintEqualToAnchor:wrapper.bottomAnchor
                                          constant:-KKPaddingLG]];
  } else {
    [anchors addObject:[seqContainer.heightAnchor
                           constraintEqualToConstant:seqContainerH]];
  }
  [NSLayoutConstraint activateConstraints:anchors];
  return seqContainer;
}

- (KKStageSequencerRulerView *)_buildSeqRulerInContainer:(NSView *)seqContainer
                                             rulerHeight:(CGFloat)rulerH {
  KKStageSequencerRulerView *rulerView =
      [[KKStageSequencerRulerView alloc] initWithFrame:NSZeroRect];
  rulerView.translatesAutoresizingMaskIntoConstraints = NO;
  [seqContainer addSubview:rulerView];
  [NSLayoutConstraint activateConstraints:@[
    [rulerView.leadingAnchor
        constraintEqualToAnchor:seqContainer.leadingAnchor],
    [rulerView.trailingAnchor
        constraintEqualToAnchor:seqContainer.trailingAnchor],
    [rulerView.topAnchor constraintEqualToAnchor:seqContainer.topAnchor
                                        constant:KKPaddingSM],
    [rulerView.heightAnchor constraintEqualToConstant:rulerH],
  ]];
  return rulerView;
}

- (void)_buildSeqScrollViewInContainer:(NSView *)seqContainer
                            underRuler:(KKStageSequencerRulerView *)rulerView
                              uncapped:(BOOL)uncapped
                              seqProps:
                                  (NSArray<KKAnimatableProperty *> *)seqProps
                            fullLanesH:(CGFloat)fullLanesH
                            outSeqView:(KKStageSequencerView **)outSeqView
                          outEmptyView:(KKEmptyLanesView **)outEmptyView {
  NSScrollView *scrollView =
      [[KKSequencerScrollView alloc] initWithFrame:NSZeroRect];
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
  scrollView.contentView.postsBoundsChangedNotifications = YES;

  KKStageSequencerView *seqView = [[KKStageSequencerView alloc]
      initWithFrame:NSMakeRect(0, 0, 300, fullLanesH)];
  seqView.translatesAutoresizingMaskIntoConstraints = NO;
  // Let the renderer differentiate color/gradient lanes (which should render
  // as a value strip + single easing curve) from scalar lanes. Color and
  // gradient props each have exactly one entry in `valueParamKinds`, so the
  // first entry is representative.
  NSMutableDictionary<NSString *, NSNumber *> *laneKinds =
      [NSMutableDictionary dictionaryWithCapacity:seqProps.count];
  NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *laneCompKinds =
      [NSMutableDictionary dictionaryWithCapacity:seqProps.count];
  for (KKAnimatableProperty *p in seqProps) {
    NSNumber *kind = p.valueParamKinds.firstObject;
    if (kind)
      laneKinds[p.label] = kind;
    NSMutableArray<NSNumber *> *expanded = [NSMutableArray array];
    for (NSNumber *k in p.valueParamKinds) {
      KKAnimatableParamKind kk = (KKAnimatableParamKind)k.integerValue;
      NSUInteger n = 1;
      switch (kk) {
      case KKAnimatableParamKindColor:
        n = 3;
        break;
      case KKAnimatableParamKindPoint:
        n = 2;
        break;
      case KKAnimatableParamKindGradient:
        n = 0;
        break;
      default:
        n = 1;
        break;
      }
      for (NSUInteger i = 0; i < n; i++)
        [expanded addObject:k];
    }
    if (expanded.count)
      laneCompKinds[p.label] = expanded;
  }
  seqView.laneKindsByLabel = laneKinds;
  seqView.laneComponentKindsByLabel = laneCompKinds;
  seqView.laneLabelsWithOSC = [self animatablePropertyLabelsWithOSC];
  scrollView.documentView = seqView;
  [seqContainer addSubview:scrollView];

  // Pin the document view to the clip view's width so segments never overflow
  // past the visible area. A low-priority bottom-pin lets the sequencer grow
  // with the clip view so lanes stretch vertically when there's spare room
  // (few visible lanes), while still allowing intrinsic-content-size to push
  // past the clip view and scroll when there are too many.
  NSMutableArray<NSLayoutConstraint *> *seqViewConstraints =
      [NSMutableArray arrayWithArray:@[
        [seqView.widthAnchor
            constraintEqualToAnchor:scrollView.contentView.widthAnchor],
        [seqView.topAnchor
            constraintEqualToAnchor:scrollView.contentView.topAnchor],
        [seqView.leadingAnchor
            constraintEqualToAnchor:scrollView.contentView.leadingAnchor],
      ]];
  [seqView setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                      forOrientation:NSLayoutConstraintOrientationVertical];
  NSLayoutConstraint *bottomFill = [seqView.bottomAnchor
      constraintEqualToAnchor:scrollView.contentView.bottomAnchor];
  bottomFill.priority = NSLayoutPriorityDefaultLow;
  [seqViewConstraints addObject:bottomFill];
  [NSLayoutConstraint activateConstraints:seqViewConstraints];

  [NSLayoutConstraint activateConstraints:@[
    [scrollView.leadingAnchor
        constraintEqualToAnchor:seqContainer.leadingAnchor],
    [scrollView.trailingAnchor
        constraintEqualToAnchor:seqContainer.trailingAnchor],
    [scrollView.topAnchor constraintEqualToAnchor:rulerView.bottomAnchor],
    [scrollView.bottomAnchor constraintEqualToAnchor:seqContainer.bottomAnchor],
  ]];

  KKEmptyLanesView *emptyView = [[KKEmptyLanesView alloc] init];
  emptyView.hidden = YES;
  [seqContainer addSubview:emptyView
                positioned:NSWindowAbove
                relativeTo:scrollView];
  [NSLayoutConstraint activateConstraints:@[
    [emptyView.leadingAnchor constraintEqualToAnchor:scrollView.leadingAnchor],
    [emptyView.trailingAnchor
        constraintEqualToAnchor:scrollView.trailingAnchor],
    [emptyView.topAnchor constraintEqualToAnchor:scrollView.topAnchor],
    [emptyView.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor],
  ]];

  *outSeqView = seqView;
  if (outEmptyView)
    *outEmptyView = emptyView;
}

- (KKStagePlayheadView *)_buildSeqPlayheadInContainer:(NSView *)seqContainer
                                          rulerHeight:(CGFloat)rulerH {
  KKStagePlayheadView *playheadView =
      [[KKStagePlayheadView alloc] initWithFrame:NSZeroRect];
  playheadView.translatesAutoresizingMaskIntoConstraints = NO;
  playheadView.rulerHeight = rulerH;
  playheadView.topPadding = KKPaddingSM;
  [seqContainer addSubview:playheadView];
  [NSLayoutConstraint activateConstraints:@[
    [playheadView.leadingAnchor
        constraintEqualToAnchor:seqContainer.leadingAnchor],
    [playheadView.trailingAnchor
        constraintEqualToAnchor:seqContainer.trailingAnchor],
    [playheadView.topAnchor constraintEqualToAnchor:seqContainer.topAnchor],
    [playheadView.bottomAnchor
        constraintEqualToAnchor:seqContainer.bottomAnchor],
  ]];
  return playheadView;
}

/// Reads persisted lanes; if none, seeds defaults from each property's
/// current value and writes them back. Returns rebalanced lanes or nil.
- (NSArray<KKTimingLane *> *)
    _readOrSeedLanesForProps:(NSArray<KKAnimatableProperty *> *)seqProps
                 paramGetAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                      atTime:(CMTime)time {
  NSArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  if (lanes || seqProps.count == 0)
    return lanes;

  // Real read failed. Prefer in-memory snapshot if we have one (re-mount
  // recovery). Otherwise fall through and build display-only defaults so
  // the sequencer isn't visually empty — but never persist them, since a
  // nil read can mean "scope not wired yet" rather than "no data". A
  // first user edit will eventually persist real JSON.
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  NSArray<KKTimingLane *> *snapshot = state.lanesSnapshot;
  if (snapshot.count > 0)
    return snapshot;

  NSSet<NSString *> *oscOffByDefault =
      [self animatablePropertyLabelsWithOSCDefaultOff];
  NSMutableArray<KKTimingLane *> *defaults =
      [NSMutableArray arrayWithCapacity:seqProps.count];
  for (KKAnimatableProperty *prop in seqProps) {
    NSArray<NSNumber *> *baseVals = [prop readValuesWithGetAPI:paramGetAPI
                                                        atTime:time];
    if (!baseVals.count)
      baseVals = @[ @(1.0) ];
    KKTimingLane *lane = [KKTimingLane defaultLaneForLabel:prop.label
                                                baseValues:baseVals];
    if ([oscOffByDefault containsObject:prop.label])
      lane.oscVisible = NO;
    [defaults addObject:lane];
  }
  return defaults;
}

- (void)_seedPlayheadForSeqView:(KKStageSequencerView *)seqView
                      rulerView:(KKStageSequencerRulerView *)rulerView
                   playheadView:(KKStagePlayheadView *)playheadView
                         atTime:(CMTime)nowTime {
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!timingAPI)
    return;
  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];
  double durSec = CMTimeGetSeconds(effectDuration);
  seqView.effectDuration = durSec;
  rulerView.effectDuration = durSec;
  if (durSec > 0) {
    double startSec = CMTimeGetSeconds(effectStart);
    double nowSec = CMTimeGetSeconds(nowTime);
    double frac = (nowSec - startSec) / durSec;
    seqView.playheadFraction = frac;
    playheadView.playheadFraction = frac;
  }
}

/// Seeds lane data (creating defaults if missing) and syncs the playhead.
- (void)
    _seedSequencerWithSeqContainer:(NSView *)seqContainer
                           seqView:(KKStageSequencerView *)seqView
                         rulerView:(KKStageSequencerRulerView *)rulerView
                      playheadView:(KKStagePlayheadView *)playheadView
                          seqProps:(NSArray<KKAnimatableProperty *> *)seqProps
                       paramGetAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                         actionAPI:
                             (id<FxCustomParameterActionAPI_v4>)actionAPI {
  seqContainer.hidden = NO;

  NSArray<KKTimingLane *> *lanes =
      [self _readOrSeedLanesForProps:seqProps
                         paramGetAPI:paramGetAPI
                              atTime:[actionAPI currentTime]];
  if (lanes) {
    KKPluginInstanceState *instState = KKInstanceStateForAPI(self.apiManager);
    instState.lanesSnapshot = [lanes copy];
    NSSet<NSString *> *pluginHidden =
        [self hiddenAnimatablePropertyLabels] ?: [NSSet set];
    NSSet<NSString *> *hidden =
        KKEffectiveHiddenLaneLabels(pluginHidden, lanes);
    instState.hiddenLaneLabels = hidden;
    seqView.lanes = KKFilterLanesForVisibility(lanes, hidden);
    KKPushLanesToVisibilityBar(instState.visibilityBar, lanes);
    KKApplyEmptyLanesVisibility(instState.emptyLanesView, lanes);
    for (KKTimingViewRefs *r in instState.additionalTimingViews) {
      KKPushLanesToVisibilityBar(r.visibilityBar, lanes);
      KKApplyEmptyLanesVisibility(r.emptyLanesView, lanes);
    }
  }

  // FCP often can't deliver the real persisted JSON during the initial
  // create-view scope. Schedule a deferred re-apply on the next runloop
  // tick — by then FCP has wired the action scope and the read returns
  // the actual data, replacing the displayed defaults without needing
  // user interaction. Safe in Motion: if the read still fails, the
  // snapshot fallback inside KKReadLanesRebalanced makes it a no-op.
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weakSelf timingGraphApplyState];
  });

  [self _seedPlayheadForSeqView:seqView
                      rulerView:rulerView
                   playheadView:playheadView
                         atTime:[actionAPI currentTime]];
}

typedef struct {
  CGFloat fullLanesH;
  CGFloat rulerH;
  CGFloat seqContainerH;
  CGFloat barH;
  CGFloat wrapperHeight;
} KKTimingGraphMetrics;

/// Sequencer container height for the given visible-lane count. In capped
/// (inspector) mode, the container caps at 2.5 lanes worth and scrolls
/// past that. In uncapped (window) mode, lanes always fit (no scroll).
static CGFloat KKSeqContainerHeightForVisible(BOOL uncapped,
                                              NSUInteger visibleCount) {
  // Treat zero-visible as one lane's worth so the empty container has
  // some presence rather than collapsing to ruler-only.
  NSUInteger laneCountForHeight = MAX((NSUInteger)1, visibleCount);
  CGFloat lanesH;
  if (uncapped || visibleCount <= 2) {
    lanesH = [KKStageSequencerView heightForLaneCount:laneCountForHeight];
  } else {
    CGFloat h2 = [KKStageSequencerView heightForLaneCount:2];
    CGFloat h3 = [KKStageSequencerView heightForLaneCount:3];
    lanesH = h2 + (h3 - h2) * 0.5;
  }
  CGFloat rulerH = [KKStageSequencerRulerView preferredHeight];
  return KKPaddingSM + rulerH + lanesH;
}

static KKTimingGraphMetrics KKTimingGraphMetricsCompute(BOOL uncapped,
                                                        NSUInteger propsCount) {
  CGFloat fullLanesH = [KKStageSequencerView heightForLaneCount:propsCount];
  CGFloat rulerH = [KKStageSequencerRulerView preferredHeight];
  CGFloat seqContainerH = KKSeqContainerHeightForVisible(uncapped, propsCount);
  CGFloat barH = [KKLaneVisibilityBar preferredHeight];
  return (KKTimingGraphMetrics){
      .fullLanesH = fullLanesH,
      .rulerH = rulerH,
      .seqContainerH = seqContainerH,
      .barH = barH,
      .wrapperHeight = barH + KKPaddingSM + seqContainerH + KKPaddingLG,
  };
}

/// In inspector (capped) mode, the primary views are stored on the plugin
/// so callbacks can find them. In uncapped (window) mode they're added to
/// per-instance state as an additional ref set, and we push current state
/// through so the window opens already in sync.
- (void)_registerSequencerViewsForUncapped:(BOOL)uncapped
                              seqContainer:(NSView *)seqContainer
                                   seqView:(KKStageSequencerView *)seqView
                                 rulerView:
                                     (KKStageSequencerRulerView *)rulerView
                              playheadView:(KKStagePlayheadView *)playheadView
                             visibilityBar:(KKLaneVisibilityBar *)visibilityBar
                                 emptyView:(KKEmptyLanesView *)emptyView {
  if (!uncapped) {
    self.stageSequencer = seqView;
    self.stageSequencerContainer = seqContainer;
    self.stageSequencerRuler = rulerView;
    [self _registerMultiStageSequencerView:seqView
                                 rulerView:rulerView
                              playheadView:playheadView];
    KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
    state.visibilityBar = visibilityBar;
    state.emptyLanesView = emptyView;
    return;
  }
  KKTimingViewRefs *refs = [[KKTimingViewRefs alloc] init];
  refs.seqView = seqView;
  refs.seqContainer = seqContainer;
  refs.ruler = rulerView;
  refs.playhead = playheadView;
  refs.visibilityBar = visibilityBar;
  refs.emptyLanesView = emptyView;
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (state) {
    if (!state.additionalTimingViews)
      state.additionalTimingViews = [NSMutableArray array];
    [state.additionalTimingViews addObject:refs];
  }
  [self timingGraphApplyState];
}

- (NSView *)_createTimingGraphViewUncapped:(BOOL)uncapped {
  NSArray<KKAnimatableProperty *> *seqProps = [self animatableProperties];
  KKTimingGraphMetrics metrics =
      KKTimingGraphMetricsCompute(uncapped, seqProps.count);

  NSView *wrapper = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, 300, metrics.wrapperHeight)];
  wrapper.autoresizingMask = NSViewWidthSizable;

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

  KKLaneVisibilityBar *visibilityBar = [[KKLaneVisibilityBar alloc] init];
  visibilityBar.translatesAutoresizingMaskIntoConstraints = NO;
  [wrapper addSubview:visibilityBar];
  [NSLayoutConstraint activateConstraints:@[
    [visibilityBar.leadingAnchor
        constraintEqualToAnchor:wrapper.leadingAnchor
                       constant:KKInspectorHorizontalInset],
    [visibilityBar.trailingAnchor
        constraintEqualToAnchor:wrapper.trailingAnchor
                       constant:-KKInspectorHorizontalInset],
    [visibilityBar.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
    [visibilityBar.heightAnchor constraintEqualToConstant:metrics.barH],
  ]];

  NSView *seqContainer =
      [self _buildSeqContainerInWrapper:wrapper
                              topAnchor:visibilityBar.bottomAnchor
                               topInset:KKPaddingSM
                               uncapped:uncapped
                          seqContainerH:metrics.seqContainerH];
  KKStageSequencerRulerView *rulerView =
      [self _buildSeqRulerInContainer:seqContainer rulerHeight:metrics.rulerH];
  KKStageSequencerView *seqView = nil;
  KKEmptyLanesView *emptyView = nil;
  [self _buildSeqScrollViewInContainer:seqContainer
                            underRuler:rulerView
                              uncapped:uncapped
                              seqProps:seqProps
                            fullLanesH:metrics.fullLanesH
                            outSeqView:&seqView
                          outEmptyView:&emptyView];
  KKStagePlayheadView *playheadView =
      [self _buildSeqPlayheadInContainer:seqContainer
                             rulerHeight:metrics.rulerH];

  [self _registerSequencerViewsForUncapped:uncapped
                              seqContainer:seqContainer
                                   seqView:seqView
                                 rulerView:rulerView
                              playheadView:playheadView
                             visibilityBar:visibilityBar
                                 emptyView:emptyView];

  __weak typeof(self) weakSelf = self;
  visibilityBar.onPillClicked = ^(NSInteger laneIndex, BOOL optionDown) {
    [weakSelf _handleLaneVisibilityClickedAtIndex:laneIndex
                                       optionDown:optionDown];
  };

  [self _wireStageSequencerCallbacksFor:seqView
                              rulerView:rulerView
                           playheadView:playheadView];

  [actionAPI startAction:self];
  [self _seedSequencerWithSeqContainer:seqContainer
                               seqView:seqView
                             rulerView:rulerView
                          playheadView:playheadView
                              seqProps:seqProps
                           paramGetAPI:paramGetAPI
                             actionAPI:actionAPI];
  [actionAPI endAction:self];

  return wrapper;
}

@end
