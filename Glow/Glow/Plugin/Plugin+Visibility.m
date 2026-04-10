/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"

static void setFlagsIfChanged(id<FxParameterSettingAPI_v5> setAPI,
                              id<FxParameterRetrievalAPI_v6> getAPI,
                              FxParameterFlags newFlags, UInt32 paramID) {
  FxParameterFlags current = 0;
  [getAPI getParameterFlags:&current fromParameter:paramID];
  if (current != newFlags)
    [setAPI setParameterFlags:newFlags toParameter:paramID];
}

@implementation GlowPlugin (Visibility)

- (void)updateParameterVisibilityAtTime:(CMTime)time {
  static BOOL sUpdating = NO;
  if (sUpdating)
    return;
  sUpdating = YES;
  @try {
    [self updateTimingParameterVisibility];

    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];

    BOOL forceShow = [self
        forceShowAllParametersIfEnabled:kParamForceShow
                               paramIDs:@[
                                 @(kParamNoise), @(kParamNoiseOffset),
                                 @(kParamNoiseSpeed), @(kParamOffsetX),
                                 @(kParamOffsetY), @(kKKParamColorMode),
                                 @(kKKParamColorSolid),
                                 @(kKKParamColorGradient),
                                 @(kParamGradientType), @(kParamGradientAngle),
                                 @(kParamTimingInColor),
                                 @(kParamTimingHoldColor),
                                 @(kParamTimingOutColor),
                                 @(kParamTimingInGradient),
                                 @(kParamTimingHoldGradient),
                                 @(kParamTimingOutGradient)
                               ]
                                 atTime:time];
    if (forceShow)
      return;

    // --- Noise group ---
    BOOL noiseExpanded = NO;
    [paramGetAPI getBoolValue:&noiseExpanded
                fromParameter:kParamNoiseExpanded
                       atTime:kCMTimeZero];

    FxParameterFlags noiseFlags =
        noiseExpanded ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
    setFlagsIfChanged(paramSetAPI, paramGetAPI, noiseFlags, kParamNoise);
    setFlagsIfChanged(paramSetAPI, paramGetAPI, noiseFlags, kParamNoiseOffset);
    setFlagsIfChanged(paramSetAPI, paramGetAPI, noiseFlags, kParamNoiseSpeed);

    // --- Offset group ---
    BOOL offsetExpanded = NO;
    [paramGetAPI getBoolValue:&offsetExpanded
                fromParameter:kParamOffsetExpanded
                       atTime:kCMTimeZero];

    FxParameterFlags offsetFlags =
        offsetExpanded ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
    setFlagsIfChanged(paramSetAPI, paramGetAPI, offsetFlags, kParamOffsetX);
    setFlagsIfChanged(paramSetAPI, paramGetAPI, offsetFlags, kParamOffsetY);

    // --- Color group ---
    BOOL colorExpanded = NO;
    [paramGetAPI getBoolValue:&colorExpanded
                fromParameter:kKKParamColorExpanded
                       atTime:kCMTimeZero];

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
      setFlagsIfChanged(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                        kKKParamColorGradient);
      setFlagsIfChanged(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                        kParamGradientType);
      setFlagsIfChanged(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                        kParamGradientAngle);
    }

    // --- Timing color params ---
    BOOL timingExpanded = NO;
    [paramGetAPI getBoolValue:&timingExpanded
                fromParameter:kKKParamTimingExpanded
                       atTime:kCMTimeZero];

    int colorModeIdx = 0;
    [paramGetAPI getIntValue:&colorModeIdx
               fromParameter:kKKParamColorMode
                      atTime:time];
    // modes array order: Dynamic(0), Solid(1), Gradient(2)
    BOOL isSolid = (colorModeIdx == 1);
    BOOL isGradient = (colorModeIdx == 2);

    BOOL animateIn = NO, animateOut = NO;
    [paramGetAPI getBoolValue:&animateIn
                fromParameter:kKKParamAnimateIn
                       atTime:time];
    [paramGetAPI getBoolValue:&animateOut
                fromParameter:kKKParamAnimateOut
                       atTime:time];

    BOOL inColorToggle = NO, holdColorToggle = NO, outColorToggle = NO;
    [paramGetAPI getBoolValue:&inColorToggle
                fromParameter:kParamInColor
                       atTime:time];
    [paramGetAPI getBoolValue:&holdColorToggle
                fromParameter:kParamHoldColor
                       atTime:time];
    [paramGetAPI getBoolValue:&outColorToggle
                fromParameter:kParamOutColor
                       atTime:time];

    int selectedSection = 1; // Hold
    [paramGetAPI getIntValue:&selectedSection
               fromParameter:kKKParamTimingSelectedSection
                      atTime:kCMTimeZero];

    BOOL sectionIsIn = (selectedSection == 0);
    BOOL sectionIsHold = (selectedSection == 1);
    BOOL sectionIsOut = (selectedSection == 2);

    int holdEffect = 0;
    [paramGetAPI getIntValue:&holdEffect
               fromParameter:kKKParamHoldEffect
                      atTime:time];
    BOOL holdHasEffect = (holdEffect != 0);

    BOOL inActive = timingExpanded && animateIn && inColorToggle && sectionIsIn;
    BOOL holdActive =
        timingExpanded && holdColorToggle && holdHasEffect && sectionIsHold;
    BOOL outActive =
        timingExpanded && animateOut && outColorToggle && sectionIsOut;

    setFlagsIfChanged(paramSetAPI, paramGetAPI,
                      (inActive && isSolid) ? kFxParameterFlag_DEFAULT
                                            : kFxParameterFlag_HIDDEN,
                      kParamTimingInColor);
    setFlagsIfChanged(paramSetAPI, paramGetAPI,
                      (holdActive && isSolid) ? kFxParameterFlag_DEFAULT
                                              : kFxParameterFlag_HIDDEN,
                      kParamTimingHoldColor);
    setFlagsIfChanged(paramSetAPI, paramGetAPI,
                      (outActive && isSolid) ? kFxParameterFlag_DEFAULT
                                             : kFxParameterFlag_HIDDEN,
                      kParamTimingOutColor);
    setFlagsIfChanged(paramSetAPI, paramGetAPI,
                      (inActive && isGradient) ? kFxParameterFlag_DEFAULT
                                               : kFxParameterFlag_HIDDEN,
                      kParamTimingInGradient);
    setFlagsIfChanged(paramSetAPI, paramGetAPI,
                      (holdActive && isGradient) ? kFxParameterFlag_DEFAULT
                                                 : kFxParameterFlag_HIDDEN,
                      kParamTimingHoldGradient);
    setFlagsIfChanged(paramSetAPI, paramGetAPI,
                      (outActive && isGradient) ? kFxParameterFlag_DEFAULT
                                                : kFxParameterFlag_HIDDEN,
                      kParamTimingOutGradient);
  } @finally {
    sUpdating = NO;
  }
}

@end
