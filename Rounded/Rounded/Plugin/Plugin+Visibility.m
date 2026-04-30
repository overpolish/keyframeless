/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
  if ([self forceShowAllParameters])
    expanded = YES;

  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamCropExpanded];

  FxParameterFlags base =
      expanded ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  // Preserve any DISABLED bit set externally (e.g. HTH transition selection
  // on the Crop lane) — overwriting flags wholesale would wipe it.
  UInt32 leafIDs[] = {kParamCropTop, kParamCropBottom, kParamCropLeft,
                      kParamCropRight};
  for (NSUInteger i = 0; i < sizeof(leafIDs) / sizeof(leafIDs[0]); i++) {
    FxParameterFlags cur = 0;
    [paramGetAPI getParameterFlags:&cur fromParameter:leafIDs[i]];
    FxParameterFlags want = base | (cur & kFxParameterFlag_DISABLED);
    [paramSetAPI setParameterFlags:want toParameter:leafIDs[i]];
  }
}

@end
