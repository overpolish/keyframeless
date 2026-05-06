/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../KKLog.h"
#import "../../Style/KKTokens.h"
#import "../../Views/KKCustomGroupHeaderView.h"
#import "../../Views/StageSequencer/KKRemoteWindowKeyHandlerView.h"
#import "../../Views/StageSequencer/KKStageSequencerRulerView.h"
#import "../../Views/StageSequencer/KKStageSequencerView.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKConstants.h>

@implementation KKPlugin (TimingHeader)

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
  // Apply both the bool write AND the curve-preview row flag synchronously
  // inside the same action scope. The deferred
  // `updateTimingParameterVisibility` path (used by parameterChanged: callers
  // to dodge the cascade crash) commits setParameterFlags one inspector tick
  // late on non-first instances, leaving the row state visually one click out
  // of phase. The chevron click is not a parameterChanged: context, so the
  // synchronous write is safe here.
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
    BOOL show = isExpanded || [strongSelf forceShowAllParameters];
    FxParameterFlags wantFlags =
        show ? (kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_CUSTOM_UI |
                kFxParameterFlag_USE_FULL_VIEW_WIDTH)
             : kFxParameterFlag_HIDDEN;
    [setAPI setParameterFlags:wantFlags toParameter:kKKParamTimingCurvePreview];
    [actAPI endAction:strongSelf];
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

  self.motionBlurHeader = header;
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

  id<FxParameterRetrievalAPI_v6> _hdrGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSArray<KKTimingLane *> *_hdrLanes =
      KKReadLanesRebalanced(self.apiManager, _hdrGetAPI);
  if (!_hdrLanes.count)
    _hdrLanes = [self defaultLanesAtTime:[actionAPI currentTime]
                             paramGetAPI:_hdrGetAPI];
  CGFloat lanesH = [KKStageSequencerView heightForLaneCount:_hdrLanes.count];
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

@end
