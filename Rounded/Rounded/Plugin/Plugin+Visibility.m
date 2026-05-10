/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKDataBlob.h>

@implementation RoundedPlugin (Visibility)

- (void)updateCropParameterVisibility {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramGetAPI || !paramSetAPI)
    return;

  BOOL expanded = KKReadCustomParamBool(paramGetAPI, kParamCropExpanded);
  if ([self forceShowAllParameters])
    expanded = YES;

  // Mask out host-internal flag bits when comparing — FCP silently OR's
  // bits like 0x20200 back in after our writes, so a raw `cur != want`
  // check fires forever and pollutes the undo stack with phantom entries.
  const FxParameterFlags kMask = kFxParameterFlag_HIDDEN |
                                 kFxParameterFlag_DISABLED |
                                 kFxParameterFlag_NOT_ANIMATABLE |
                                 kFxParameterFlag_DONT_DISPLAY_IN_DASHBOARD;

  // kParamCropExpanded is created HIDDEN at addCropParameters time and is
  // never user-toggled — we only read its bool value. Don't try to manage
  // its flags at runtime: FCP adds DISABLED on hidden params and our
  // setParameterFlags fires would each pollute the host undo stack with
  // an entry the user has to step past with extra cmd-Z presses.

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
    if ((cur & kMask) != (want & kMask)) {
      FxParameterFlags merged = (cur & ~kMask) | (want & kMask);
      [paramSetAPI setParameterFlags:merged toParameter:leafIDs[i]];
    }
  }
}

@end
