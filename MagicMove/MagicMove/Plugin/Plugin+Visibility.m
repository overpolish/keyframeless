/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KeyframelessKit.h>

@implementation MagicMovePlugin (Visibility)

- (void)setFlags:(FxParameterFlags)flags
        forGroup:(MagicMoveGroupIDs)group
         withAPI:(id<FxParameterSettingAPI_v5>)api {
  if (group.preview)
    [api setParameterFlags:flags toParameter:group.preview];
  if (group.hideOSC)
    [api setParameterFlags:flags toParameter:group.hideOSC];
  [api setParameterFlags:flags toParameter:group.params.point];
  [api setParameterFlags:flags toParameter:group.params.rotation];
  [api setParameterFlags:flags toParameter:group.params.rotationX];
  [api setParameterFlags:flags toParameter:group.params.rotationY];
  [api setParameterFlags:flags toParameter:group.params.scaleX];
  [api setParameterFlags:flags toParameter:group.params.scaleY];
  [api setParameterFlags:flags toParameter:group.params.opacity];
}

- (void)updateParameterVisibilityAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramGetAPI || !paramSetAPI)
    return;

  BOOL animIn = NO, animOut = NO, driftOn = NO, exitOn = NO;
  [paramGetAPI getBoolValue:&animIn
              fromParameter:kKKParamAnimateIn
                     atTime:time];
  [paramGetAPI getBoolValue:&animOut
              fromParameter:kKKParamAnimateOut
                     atTime:time];
  [paramGetAPI getBoolValue:&driftOn fromParameter:kParamDrift atTime:time];
  [paramGetAPI getBoolValue:&exitOn fromParameter:kParamExit atTime:time];

  BOOL previewA = NO, previewB = NO, previewDrift = NO, previewExit = NO;
  [paramGetAPI getBoolValue:&previewA fromParameter:kParamPreviewA atTime:time];
  [paramGetAPI getBoolValue:&previewB fromParameter:kParamPreviewB atTime:time];
  [paramGetAPI getBoolValue:&previewDrift
              fromParameter:kParamPreviewDrift
                     atTime:time];
  [paramGetAPI getBoolValue:&previewExit
              fromParameter:kParamPreviewExit
                     atTime:time];
  FxParameterFlags alertBase =
      kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_CUSTOM_UI |
      kFxParameterFlag_USE_FULL_VIEW_WIDTH | kFxParameterFlag_DISABLED;

  MagicMoveGroupIDs groups[] = {kGroupA, kGroupB, kGroupDrift, kGroupExit};
  NSMutableArray<NSNumber *> *allHideableParams = [NSMutableArray array];
  for (int i = 0; i < 4; i++) {
    if (groups[i].enable)
      [allHideableParams addObject:@(groups[i].enable)];
    [allHideableParams addObjectsFromArray:childIDsForGroup(groups[i])];
  }

  if ([self forceShowAllParametersIfEnabled:kParamForceShowAlerts
                                   paramIDs:allHideableParams
                                     atTime:time]) {
    [paramSetAPI setParameterFlags:alertBase toParameter:kParamPreviewWarning];
    [paramSetAPI setParameterFlags:alertBase toParameter:kParamHideOSCWarning];
    return;
  }

  [paramSetAPI setParameterFlags:alertBase toParameter:kParamPreviewWarning];
  [paramSetAPI setParameterFlags:alertBase toParameter:kParamHideOSCWarning];

  [self updateTimingParameterVisibility];

  BOOL showA = animIn || (animOut && !exitOn);
  BOOL showExit = exitOn && animOut;

  if (self.pointAHeader) {
    self.pointAHeader.isEnabled = showA;
    if (!showA) {
      NSString *reason = (!animIn && !animOut)
                             ? @"Enable Animate In or Out"
                             : @"Overridden by Exit and Animate In is off";
      self.pointAHeader.statusText = reason;
    } else {
      self.pointAHeader.statusText = nil;
    }
  }

  BOOL expandedA;
  if (self.pointAHeader) {
    expandedA = self.pointAHeader.isExpanded;
  } else {
    UInt32 f = 0;
    [paramGetAPI getParameterFlags:&f fromParameter:kParamPointA];
    expandedA = (f & kFxParameterFlag_HIDDEN) == 0;
  }
  BOOL showAParams = showA && expandedA;
  [self setFlags:(showAParams ? kFxParameterFlag_DEFAULT
                              : kFxParameterFlag_HIDDEN)
        forGroup:kGroupA
         withAPI:paramSetAPI];

  BOOL expandedB;
  if (self.pointBHeader) {
    expandedB = self.pointBHeader.isExpanded;
  } else {
    UInt32 f = 0;
    [paramGetAPI getParameterFlags:&f fromParameter:kParamPointB];
    expandedB = (f & kFxParameterFlag_HIDDEN) == 0;
  }
  [self
      setFlags:(expandedB ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN)
      forGroup:kGroupB
       withAPI:paramSetAPI];

  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamDrift];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamExit];

  BOOL expandedDrift;
  if (self.driftHeader) {
    expandedDrift = self.driftHeader.isExpanded;
  } else {
    UInt32 f = 0;
    [paramGetAPI getParameterFlags:&f fromParameter:kParamDriftPoint];
    expandedDrift = (f & kFxParameterFlag_HIDDEN) == 0;
  }
  [self setFlags:((driftOn && expandedDrift) ? kFxParameterFlag_DEFAULT
                                             : kFxParameterFlag_HIDDEN)
        forGroup:kGroupDrift
         withAPI:paramSetAPI];

  if (self.exitHeader) {
    if (exitOn && !animOut) {
      self.exitHeader.statusText = @"Enable Animate Out";
    } else {
      self.exitHeader.statusText = nil;
    }
  }

  BOOL expandedExit;
  if (self.exitHeader) {
    expandedExit = self.exitHeader.isExpanded;
  } else {
    UInt32 f = 0;
    [paramGetAPI getParameterFlags:&f fromParameter:kParamExitPoint];
    expandedExit = (f & kFxParameterFlag_HIDDEN) == 0;
  }
  [self setFlags:((showExit && expandedExit) ? kFxParameterFlag_DEFAULT
                                             : kFxParameterFlag_HIDDEN)
        forGroup:kGroupExit
         withAPI:paramSetAPI];
}

- (void)setGroupEnabled:(BOOL)enabled
            boolParamID:(UInt32)boolParamID
          childParamIDs:(NSArray<NSNumber *> *)childIDs {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];

  CMTime currentTime = [actionAPI currentTime];

  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

  [paramSetAPI setBoolValue:enabled toParameter:boolParamID atTime:currentTime];

  for (NSNumber *paramID in childIDs) {
    [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                       toParameter:paramID.unsignedIntValue];
  }

  [actionAPI endAction:self];
}

@end
