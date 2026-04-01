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
  MagicMoveGroupIDs groups[] = {kGroupA, kGroupB, kGroupDrift, kGroupExit};
  NSMutableArray<NSNumber *> *allHideableParams = [NSMutableArray array];
  for (int i = 0; i < 4; i++) {
    if (groups[i].enable)
      [allHideableParams addObject:@(groups[i].enable)];
    [allHideableParams addObjectsFromArray:childIDsForGroup(groups[i])];
  }
  [allHideableParams addObjectsFromArray:@[
    @(kKKParamAnimateIn),
    @(kKKParamAnimateOut),
    @(kKKParamAnimateInDuration),
    @(kKKParamAnimateInInterpolation),
    @(kKKParamAnimateOutDuration),
    @(kKKParamAnimateOutInterpolation),
    @(kParamRotateWithMotion),
  ]];

  if ([self forceShowAllParametersIfEnabled:kParamForceShowAlerts
                                   paramIDs:allHideableParams
                                     atTime:time])
    return;

  BOOL hideA = NO, hideB = NO, hideDrift = NO, hideExit = NO;
  [paramGetAPI getBoolValue:&hideA fromParameter:kParamHideOSCA atTime:time];
  [paramGetAPI getBoolValue:&hideB fromParameter:kParamHideOSCB atTime:time];
  [paramGetAPI getBoolValue:&hideDrift
              fromParameter:kParamHideOSCDrift
                     atTime:time];
  [paramGetAPI getBoolValue:&hideExit
              fromParameter:kParamHideOSCExit
                     atTime:time];

  BOOL anyPreview = previewA || previewB || previewDrift || previewExit;
  BOOL anyHidden = hideA || hideB || hideDrift || hideExit;

  [self.alertStackView setAlert:self.previewAlertView active:anyPreview];
  [self.alertStackView setAlert:self.hideOSCAlertView active:anyHidden];

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

  BOOL expandedA = NO;
  [paramGetAPI getBoolValue:&expandedA
              fromParameter:kParamExpandedA
                     atTime:time];
  BOOL showAParams = showA && expandedA;
  [self setFlags:(showAParams ? kFxParameterFlag_DEFAULT
                              : kFxParameterFlag_HIDDEN)
        forGroup:kGroupA
         withAPI:paramSetAPI];

  BOOL expandedB = NO;
  [paramGetAPI getBoolValue:&expandedB
              fromParameter:kParamExpandedB
                     atTime:time];
  [self
      setFlags:(expandedB ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN)
      forGroup:kGroupB
       withAPI:paramSetAPI];

  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamDrift];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamExit];

  BOOL expandedDrift = NO;
  [paramGetAPI getBoolValue:&expandedDrift
              fromParameter:kParamExpandedDrift
                     atTime:time];
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

  BOOL expandedExit = NO;
  [paramGetAPI getBoolValue:&expandedExit
              fromParameter:kParamExpandedExit
                     atTime:time];
  [self setFlags:((showExit && expandedExit) ? kFxParameterFlag_DEFAULT
                                             : kFxParameterFlag_HIDDEN)
        forGroup:kGroupExit
         withAPI:paramSetAPI];
}

@end
