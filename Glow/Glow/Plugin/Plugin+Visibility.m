/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKDataBlob.h>

// Bits we own. Compare/mutate these only — the host silently OR's its own
// bits (e.g. 0x20200) into the flags every parameterChanged: tick, so a
// wholesale `current != want` check would always disagree and create a
// phantom undo entry per tick (3+ undos to revert one user action).
// Mirrors kKKMutableFlagMask in KKPlugin+TimingParams.m.
static const FxParameterFlags kGlowMutableFlagMask =
    kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE |
    kFxParameterFlag_DONT_DISPLAY_IN_DASHBOARD | kFxParameterFlag_CUSTOM_UI |
    kFxParameterFlag_USE_FULL_VIEW_WIDTH;

static void setFlagsIfChanged(id<FxParameterSettingAPI_v5> setAPI,
                              id<FxParameterRetrievalAPI_v6> getAPI,
                              FxParameterFlags newFlags, UInt32 paramID) {
  FxParameterFlags current = 0;
  [getAPI getParameterFlags:&current fromParameter:paramID];
  // Preserve DISABLED (set externally by HTH transition lane disabling).
  FxParameterFlags want = newFlags | (current & kFxParameterFlag_DISABLED);
  if ((current & kGlowMutableFlagMask) != (want & kGlowMutableFlagMask)) {
    FxParameterFlags merged =
        (current & ~kGlowMutableFlagMask) | (want & kGlowMutableFlagMask);
    [setAPI setParameterFlags:merged toParameter:paramID];
  }
}

@implementation GlowPlugin (Visibility)

- (void)updateParameterVisibilityAtTime:(CMTime)time {
  static BOOL sUpdating = NO;
  if (sUpdating)
    return;
  sUpdating = YES;
  @try {
    // Do NOT call updateTimingParameterVisibility here — it defers writes
    // onto its own action scope (cascade-crash workaround) which lands as
    // a separate undo entry. Mirror Rounded: only fire it from
    // parameterChanged: gated to ForceShow / kKKParamTimingExpanded.

    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

    BOOL forceShow = [self
        forceShowAllParametersIfEnabled:kParamForceShow
                               paramIDs:@[
                                 @(kParamNoise), @(kParamNoiseOffset),
                                 @(kParamNoiseSpeed), @(kKKParamColorMode),
                                 @(kKKParamColorSolid),
                                 @(kKKParamColorCustomUI),
                                 @(kParamGradientType), @(kParamGradientAngle)
                               ]
                                 atTime:time];
    if (forceShow)
      return;

    // --- Noise group ---
    BOOL noiseExpanded =
        KKReadCustomParamBool(paramGetAPI, kParamNoiseExpanded);

    FxParameterFlags noiseFlags =
        noiseExpanded ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
    setFlagsIfChanged(paramSetAPI, paramGetAPI, noiseFlags, kParamNoise);
    setFlagsIfChanged(paramSetAPI, paramGetAPI, noiseFlags, kParamNoiseOffset);
    setFlagsIfChanged(paramSetAPI, paramGetAPI, noiseFlags, kParamNoiseSpeed);

    // --- Color group ---
    BOOL colorExpanded =
        KKReadCustomParamBool(paramGetAPI, kKKParamColorExpanded);

    if (colorExpanded) {
      [self updateColorParameterVisibility];

      int colorMode = 0, gradType = 0;
      [paramGetAPI getIntValue:&colorMode
                 fromParameter:kKKParamColorMode
                        atTime:time];
      [paramGetAPI getIntValue:&gradType
                 fromParameter:kParamGradientType
                        atTime:time];

      BOOL isGradient = (colorMode == 2); // Gradient (index 2 in modes array)

      setFlagsIfChanged(paramSetAPI, paramGetAPI,
                        isGradient ? kFxParameterFlag_NOT_ANIMATABLE
                                   : (kFxParameterFlag_HIDDEN |
                                      kFxParameterFlag_NOT_ANIMATABLE),
                        kParamGradientType);

      BOOL showAngle = isGradient && (gradType == 1);
      setFlagsIfChanged(paramSetAPI, paramGetAPI,
                        showAngle ? kFxParameterFlag_DEFAULT
                                  : kFxParameterFlag_HIDDEN,
                        kParamGradientAngle);
    } else {
      setFlagsIfChanged(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                        kKKParamColorMode);
      setFlagsIfChanged(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                        kKKParamColorSolid);
      setFlagsIfChanged(paramSetAPI, paramGetAPI,
                        kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_HIDDEN,
                        kKKParamColorCustomUI);
      setFlagsIfChanged(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                        kParamGradientType);
      setFlagsIfChanged(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                        kParamGradientAngle);
    }

  } @finally {
    sUpdating = NO;
  }
}

@end
