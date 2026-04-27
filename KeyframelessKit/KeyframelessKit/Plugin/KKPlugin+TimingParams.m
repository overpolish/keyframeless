/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../KKLog.h"
#import "../Math/KKEasing.h"
#import "../Math/KKTimingStage.h"
#import "../Views/KKTimingGraphView.h"
#import "KKConstants.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

static BOOL KKAddParam(BOOL ok, NSError **err, NSString *desc) {
  if (ok)
    return YES;
  if (err)
    *err = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : desc}];
  return NO;
}

static const FxParameterFlags kCustomUI = kFxParameterFlag_NOT_ANIMATABLE |
                                          kFxParameterFlag_CUSTOM_UI |
                                          kFxParameterFlag_USE_FULL_VIEW_WIDTH;

static const FxParameterFlags kCustomUIDisabled =
    kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_CUSTOM_UI |
    kFxParameterFlag_USE_FULL_VIEW_WIDTH | kFxParameterFlag_DISABLED;

static const FxParameterFlags kHiddenNotAnim =
    kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE;

/// Range used by all intensity/frequency sliders in the animation group.
static BOOL KKAddUnitFloatSlider(id<FxParameterCreationAPI_v5> paramAPI,
                                 NSString *name, UInt32 parameterID,
                                 double delta, FxParameterFlags flags,
                                 NSError **error, NSString *errDesc) {
  return KKAddParam([paramAPI addFloatSliderWithName:name
                                         parameterID:parameterID
                                        defaultValue:0.5
                                        parameterMin:0.0
                                        parameterMax:1.0
                                           sliderMin:0.0
                                           sliderMax:1.0
                                               delta:delta
                                      parameterFlags:flags],
                    error, errDesc);
}

static BOOL KKAddDurationSlider(id<FxParameterCreationAPI_v5> paramAPI,
                                NSString *name, UInt32 parameterID,
                                NSError **error, NSString *errDesc) {
  return KKAddParam([paramAPI addFloatSliderWithName:name
                                         parameterID:parameterID
                                        defaultValue:0.5
                                        parameterMin:0.1
                                        parameterMax:10.0
                                           sliderMin:0.1
                                           sliderMax:2.0
                                               delta:0.1
                                      parameterFlags:kFxParameterFlag_HIDDEN],
                    error, errDesc);
}

static BOOL KKAddEasingCurvePopup(id<FxParameterCreationAPI_v5> paramAPI,
                                  NSString *name, UInt32 parameterID,
                                  NSError **error, NSString *errDesc) {
  return KKAddParam([paramAPI addPopupMenuWithName:name
                                       parameterID:parameterID
                                      defaultValue:KKEasingCurveEaseOut
                                       menuEntries:@[
                                         @"Linear", @"Ease In", @"Ease Out",
                                         @"Ease In Out", @"Elastic", @"Bounce"
                                       ]
                                    parameterFlags:kFxParameterFlag_HIDDEN],
                    error, errDesc);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (TimingParams)

- (BOOL)addMultiStageParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                 error:(NSError **)error {
  if (!KKAddParam([paramAPI
                      addCustomParameterWithName:@""
                                     parameterID:kKKParamAnimationSeparator
                                    defaultValue:@(kKKParamAnimationSeparator)
                                  parameterFlags:kCustomUI],
                  error, @"Unable to add Timing group"))
    return NO;

  if (!KKAddParam([paramAPI
                      addCustomParameterWithName:@""
                                     parameterID:kKKParamTimingCurvePreview
                                    defaultValue:@(kKKParamTimingCurvePreview)
                                  parameterFlags:kCustomUIDisabled],
                  error, @"Unable to add Curve Preview"))
    return NO;

  if (!KKAddParam([paramAPI addToggleButtonWithName:@""
                                        parameterID:kKKParamTimingExpanded
                                       defaultValue:YES
                                     parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add Timing expanded toggle"))
    return NO;

  if (!KKAddParam([paramAPI addToggleButtonWithName:@""
                                        parameterID:kKKParamMultiStageEnabled
                                       defaultValue:YES
                                     parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add multi-stage enabled toggle"))
    return NO;

  if (!KKAddParam([paramAPI addToggleButtonWithName:@""
                                        parameterID:kKKParamTimingLoopEnabled
                                       defaultValue:NO
                                     parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add timing loop toggle"))
    return NO;

  if (!KKAddParam([paramAPI addStringParameterWithName:@""
                                           parameterID:kKKParamMultiStageData
                                          defaultValue:@""
                                        parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add multi-stage data"))
    return NO;

  if (!KKAddParam([paramAPI
                      addIntSliderWithName:@""
                               parameterID:kKKParamMultiStageSelectedProperty
                              defaultValue:0
                              parameterMin:0
                              parameterMax:64
                                 sliderMin:0
                                 sliderMax:64
                                     delta:1
                            parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add multi-stage selected property"))
    return NO;

  if (!KKAddParam([paramAPI addIntSliderWithName:@""
                                     parameterID:kKKParamMultiStageSelectedStage
                                    defaultValue:0
                                    parameterMin:0
                                    parameterMax:64
                                       sliderMin:0
                                       sliderMax:64
                                           delta:1
                                  parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add multi-stage selected stage"))
    return NO;

  if (!KKAddParam([paramAPI addStringParameterWithName:@""
                                           parameterID:kKKParamInstanceID
                                          defaultValue:@""
                                        parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add instance ID"))
    return NO;

  return YES;
}

- (BOOL)addAnimationParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                error:(NSError **)error {
  if (![self addMultiStageParametersWithAPI:paramAPI error:error])
    return NO;

  if (!KKAddParam([paramAPI addToggleButtonWithName:@"Animate In"
                                        parameterID:kKKParamAnimateIn
                                       defaultValue:NO
                                     parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Animate In toggle"))
    return NO;

  if (!KKAddDurationSlider(paramAPI, @"In Duration", kKKParamAnimateInDuration,
                           error, @"Unable to add In Duration slider"))
    return NO;

  if (!KKAddEasingCurvePopup(paramAPI, @"In Curve",
                             kKKParamAnimateInInterpolation, error,
                             @"Unable to add In Curve popup"))
    return NO;

  if (!KKAddUnitFloatSlider(
          paramAPI, @"In Intensity", kKKParamAnimateInIntensity, 0.01,
          kFxParameterFlag_HIDDEN, error, @"Unable to add In Intensity slider"))
    return NO;

  if (!KKAddParam([paramAPI addToggleButtonWithName:@"Animate Out"
                                        parameterID:kKKParamAnimateOut
                                       defaultValue:NO
                                     parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Animate Out toggle"))
    return NO;

  if (!KKAddDurationSlider(paramAPI, @"Out Duration",
                           kKKParamAnimateOutDuration, error,
                           @"Unable to add Out Duration slider"))
    return NO;

  if (!KKAddEasingCurvePopup(paramAPI, @"Out Curve",
                             kKKParamAnimateOutInterpolation, error,
                             @"Unable to add Out Curve popup"))
    return NO;

  if (!KKAddUnitFloatSlider(paramAPI, @"Out Intensity",
                            kKKParamAnimateOutIntensity, 0.01,
                            kFxParameterFlag_HIDDEN, error,
                            @"Unable to add Out Intensity slider"))
    return NO;

  if (!KKAddParam([paramAPI addPopupMenuWithName:@""
                                     parameterID:kKKParamTimingSelectedSection
                                    defaultValue:KKTimingGraphSectionHold
                                     menuEntries:@[ @"In", @"Hold", @"Out" ]
                                  parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add section selector"))
    return NO;

  if (!KKAddParam([paramAPI
                      addPopupMenuWithName:@"Hold Effect"
                               parameterID:kKKParamHoldEffect
                              defaultValue:KKHoldEffectNone
                               menuEntries:@[ @"None", @"Bounce", @"Wiggle" ]
                            parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Hold Effect popup"))
    return NO;

  if (!KKAddUnitFloatSlider(paramAPI, @"Hold Intensity", kKKParamHoldIntensity,
                            0.01, kFxParameterFlag_HIDDEN, error,
                            @"Unable to add Hold Intensity slider"))
    return NO;

  if (!KKAddUnitFloatSlider(
          paramAPI, @"In Frequency", kKKParamAnimateInFrequency, 0.01,
          kFxParameterFlag_HIDDEN, error, @"Unable to add In Frequency slider"))
    return NO;

  if (!KKAddUnitFloatSlider(paramAPI, @"Out Frequency",
                            kKKParamAnimateOutFrequency, 0.01,
                            kFxParameterFlag_HIDDEN, error,
                            @"Unable to add Out Frequency slider"))
    return NO;

  if (!KKAddUnitFloatSlider(paramAPI, @"Hold Frequency", kKKParamHoldFrequency,
                            0.01, kFxParameterFlag_HIDDEN, error,
                            @"Unable to add Hold Frequency slider"))
    return NO;

  if (!KKAddParam([paramAPI addIntSliderWithName:@"Hold Seed"
                                     parameterID:kKKParamHoldSeed
                                    defaultValue:0
                                    parameterMin:0
                                    parameterMax:INT_MAX
                                       sliderMin:0
                                       sliderMax:INT_MAX
                                           delta:1
                                  parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Hold Seed slider"))
    return NO;

  return YES;
}

- (BOOL)addMotionBlurParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                 error:(NSError **)error {

  if (!KKAddParam([paramAPI
                      addCustomParameterWithName:@""
                                     parameterID:kKKParamMotionBlurSeparator
                                    defaultValue:@(kKKParamMotionBlurSeparator)
                                  parameterFlags:kCustomUI],
                  error, @"Unable to add Motion Blur group"))
    return NO;

  // Hidden — driven by the checkbox in the group header view.
  if (!KKAddParam([paramAPI addToggleButtonWithName:@""
                                        parameterID:kKKParamMotionBlurEnabled
                                       defaultValue:NO
                                     parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add Motion Blur enabled toggle"))
    return NO;

  // UI-only: header chevron state. Hidden, persisted, starts collapsed.
  if (!KKAddParam([paramAPI addToggleButtonWithName:@""
                                        parameterID:kKKParamMotionBlurExpanded
                                       defaultValue:NO
                                     parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add Motion Blur expanded toggle"))
    return NO;

  // Length: 0–100% maps to 0–360° shutter angle. Default 50% = 180°.
  // Starts hidden (group collapsed by default); shown by
  // updateMotionBlurParameterVisibility when expanded.
  if (!KKAddParam([paramAPI addPercentSliderWithName:@"Length"
                                         parameterID:kKKParamMotionBlurShutter
                                        defaultValue:0.5
                                        parameterMin:0.0
                                        parameterMax:1.0
                                           sliderMin:0.0
                                           sliderMax:1.0
                                               delta:0.01
                                      parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Motion Blur Length slider"))
    return NO;

  // Quality: 0–100% maps exponentially to 2–128 samples. Default 50% ≈ 16.
  if (!KKAddParam([paramAPI addPercentSliderWithName:@"Quality"
                                         parameterID:kKKParamMotionBlurQuality
                                        defaultValue:0.5
                                        parameterMin:0.0
                                        parameterMax:1.0
                                           sliderMin:0.0
                                           sliderMax:1.0
                                               delta:0.01
                                      parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Motion Blur Quality slider"))
    return NO;

  if (!KKAddParam([paramAPI
                      addToggleButtonWithName:@"Transitions only?"
                                  parameterID:kKKParamMotionBlurTransitionsOnly
                                 defaultValue:NO
                               parameterFlags:kFxParameterFlag_HIDDEN |
                                              kFxParameterFlag_NOT_ANIMATABLE],
                  error, @"Unable to add Motion Blur transitions-only toggle"))
    return NO;

  return YES;
}

@end
#pragma clang diagnostic pop
