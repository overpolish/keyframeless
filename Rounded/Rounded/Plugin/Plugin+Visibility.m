/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"

@implementation RoundedPlugin (Visibility)

- (void)updateCropParameterVisibility {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramGetAPI || !paramSetAPI)
    return;

  BOOL expanded = NO;
  [paramGetAPI getBoolValue:&expanded
              fromParameter:kParamCropExpanded
                     atTime:kCMTimeZero];

  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamCropExpanded];

  FxParameterFlags flags =
      expanded ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flags toParameter:kParamCropTop];
  [paramSetAPI setParameterFlags:flags toParameter:kParamCropBottom];
  [paramSetAPI setParameterFlags:flags toParameter:kParamCropLeft];
  [paramSetAPI setParameterFlags:flags toParameter:kParamCropRight];
}

@end
