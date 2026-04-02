/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Math/KKEasing.h"
#import "../Update/KKUpdateChecker.h"
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

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (Timing)

- (BOOL)addAnimationParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                error:(NSError **)error {
  if (!KKAddParam([paramAPI
                      addCustomParameterWithName:@""
                                     parameterID:kKKParamTimingCurvePreview
                                    defaultValue:@(kKKParamTimingCurvePreview)
                                  parameterFlags:kCustomUI],
                  error, @"Unable to add Curve Preview"))
    return NO;

  if (!KKAddParam([paramAPI
                      addCustomParameterWithName:@""
                                     parameterID:kKKParamAnimationSeparator
                                    defaultValue:@(kKKParamAnimationSeparator)
                                  parameterFlags:kCustomUI],
                  error, @"Unable to add Timing group"))
    return NO;

  if (!KKAddParam([paramAPI addToggleButtonWithName:@"Animate In"
                                        parameterID:kKKParamAnimateIn
                                       defaultValue:NO
                                     parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Animate In toggle"))
    return NO;

  if (!KKAddParam([paramAPI addFloatSliderWithName:@"In Duration"
                                       parameterID:kKKParamAnimateInDuration
                                      defaultValue:0.5
                                      parameterMin:0.1
                                      parameterMax:2.0
                                         sliderMin:0.1
                                         sliderMax:2.0
                                             delta:0.1
                                    parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add In Duration slider"))
    return NO;

  if (!KKAddParam([paramAPI addPopupMenuWithName:@"In Curve"
                                     parameterID:kKKParamAnimateInInterpolation
                                    defaultValue:KKEasingCurveEaseOut
                                     menuEntries:@[
                                       @"Linear", @"Ease In", @"Ease Out",
                                       @"Ease In Out", @"Elastic", @"Bounce"
                                     ]
                                  parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add In Curve popup"))
    return NO;

  if (!KKAddParam([paramAPI addFloatSliderWithName:@"In Intensity"
                                       parameterID:kKKParamAnimateInIntensity
                                      defaultValue:0.5
                                      parameterMin:0.0
                                      parameterMax:1.0
                                         sliderMin:0.0
                                         sliderMax:1.0
                                             delta:0.01
                                    parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add In Intensity slider"))
    return NO;

  if (!KKAddParam([paramAPI addToggleButtonWithName:@"Animate Out"
                                        parameterID:kKKParamAnimateOut
                                       defaultValue:NO
                                     parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Animate Out toggle"))
    return NO;

  if (!KKAddParam([paramAPI addFloatSliderWithName:@"Out Duration"
                                       parameterID:kKKParamAnimateOutDuration
                                      defaultValue:0.5
                                      parameterMin:0.1
                                      parameterMax:2.0
                                         sliderMin:0.1
                                         sliderMax:2.0
                                             delta:0.1
                                    parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Out Duration slider"))
    return NO;

  if (!KKAddParam([paramAPI addPopupMenuWithName:@"Out Curve"
                                     parameterID:kKKParamAnimateOutInterpolation
                                    defaultValue:KKEasingCurveEaseOut
                                     menuEntries:@[
                                       @"Linear", @"Ease In", @"Ease Out",
                                       @"Ease In Out", @"Elastic", @"Bounce"
                                     ]
                                  parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Out Curve popup"))
    return NO;

  if (!KKAddParam([paramAPI addFloatSliderWithName:@"Out Intensity"
                                       parameterID:kKKParamAnimateOutIntensity
                                      defaultValue:0.5
                                      parameterMin:0.0
                                      parameterMax:1.0
                                         sliderMin:0.0
                                         sliderMax:1.0
                                             delta:0.01
                                    parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Out Intensity slider"))
    return NO;

  if (!KKAddParam([paramAPI
                      addToggleButtonWithName:@""
                                  parameterID:kKKParamTimingExpanded
                                 defaultValue:NO
                               parameterFlags:kFxParameterFlag_HIDDEN |
                                              kFxParameterFlag_NOT_ANIMATABLE],
                  error, @"Unable to add Timing expanded toggle"))
    return NO;

  if (!KKAddParam([paramAPI
                      addPopupMenuWithName:@""
                               parameterID:kKKParamTimingSelectedSection
                              defaultValue:KKTimingGraphSectionMid
                               menuEntries:@[ @"In", @"Mid", @"Out" ]
                            parameterFlags:kFxParameterFlag_HIDDEN |
                                           kFxParameterFlag_NOT_ANIMATABLE],
                  error, @"Unable to add section selector"))
    return NO;

  if (!KKAddParam([paramAPI
                      addPopupMenuWithName:@"Hold Effect"
                               parameterID:kKKParamMidHoldEffect
                              defaultValue:KKHoldEffectNone
                               menuEntries:@[ @"None", @"Bounce", @"Wiggle" ]
                            parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Hold Effect popup"))
    return NO;

  if (!KKAddParam([paramAPI addFloatSliderWithName:@"Hold Intensity"
                                       parameterID:kKKParamMidHoldIntensity
                                      defaultValue:0.5
                                      parameterMin:0.0
                                      parameterMax:1.0
                                         sliderMin:0.0
                                         sliderMax:1.0
                                             delta:0.01
                                    parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Hold Intensity slider"))
    return NO;

  if (!KKAddParam([paramAPI addFloatSliderWithName:@"In Frequency"
                                       parameterID:kKKParamAnimateInFrequency
                                      defaultValue:0.5
                                      parameterMin:0.0
                                      parameterMax:1.0
                                         sliderMin:0.0
                                         sliderMax:1.0
                                             delta:0.01
                                    parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add In Frequency slider"))
    return NO;

  if (!KKAddParam([paramAPI addFloatSliderWithName:@"Out Frequency"
                                       parameterID:kKKParamAnimateOutFrequency
                                      defaultValue:0.5
                                      parameterMin:0.0
                                      parameterMax:1.0
                                         sliderMin:0.0
                                         sliderMax:1.0
                                             delta:0.01
                                    parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Out Frequency slider"))
    return NO;

  if (!KKAddParam([paramAPI addFloatSliderWithName:@"Hold Frequency"
                                       parameterID:kKKParamMidHoldFrequency
                                      defaultValue:0.5
                                      parameterMin:0.0
                                      parameterMax:1.0
                                         sliderMin:0.0
                                         sliderMax:1.0
                                             delta:0.01
                                    parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Hold Frequency slider"))
    return NO;

  if (!KKAddParam([paramAPI addIntSliderWithName:@"Hold Seed"
                                     parameterID:kKKParamMidHoldSeed
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

- (KKTimingResult *)timingAtTime:(CMTime)renderTime {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];

  KKTimingInterpolator identity = ^double(double t) {
    return t;
  };

  if (!paramGetAPI || !timingAPI) {
    KKTimingPhase *off = [KKTimingPhase phaseWithEnabled:NO
                                                duration:0
                                                progress:1.0
                                             interpolate:identity];
    return [KKTimingResult resultWithIn:off mid:off out:off];
  }

  BOOL animateIn = NO, animateOut = NO;
  [paramGetAPI getBoolValue:&animateIn
              fromParameter:kKKParamAnimateIn
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&animateOut
              fromParameter:kKKParamAnimateOut
                     atTime:renderTime];

  double inDuration = 0.5, outDuration = 0.5;
  int inCurve = KKEasingCurveEaseOut, outCurve = KKEasingCurveEaseOut;
  if (animateIn) {
    [paramGetAPI getFloatValue:&inDuration
                 fromParameter:kKKParamAnimateInDuration
                        atTime:renderTime];
    [paramGetAPI getIntValue:&inCurve
               fromParameter:kKKParamAnimateInInterpolation
                      atTime:renderTime];
  }
  if (animateOut) {
    [paramGetAPI getFloatValue:&outDuration
                 fromParameter:kKKParamAnimateOutDuration
                        atTime:renderTime];
    [paramGetAPI getIntValue:&outCurve
               fromParameter:kKKParamAnimateOutInterpolation
                      atTime:renderTime];
  }

  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];

  double startSec = CMTimeGetSeconds(effectStart);
  double durSec = CMTimeGetSeconds(effectDuration);
  double nowSec = CMTimeGetSeconds(renderTime);
  double endSec = startSec + durSec;

  // In phase
  double inProgress =
      animateIn ? MAX(0.0, MIN(1.0, (nowSec - startSec) / inDuration)) : 1.0;
  double inIntensity = 0.5, inFrequency = 0.5;
  if (animateIn) {
    [paramGetAPI getFloatValue:&inIntensity
                 fromParameter:kKKParamAnimateInIntensity
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&inFrequency
                 fromParameter:kKKParamAnimateInFrequency
                        atTime:renderTime];
  }
  KKEasingCurve inEasing = (KKEasingCurve)inCurve;
  KKTimingInterpolator inInterp = ^double(double t) {
    return KKApplyEasing(t, inEasing, inIntensity, inFrequency);
  };
  KKTimingPhase *inPhase = [KKTimingPhase phaseWithEnabled:animateIn
                                                  duration:inDuration
                                                  progress:inProgress
                                               interpolate:inInterp];

  // Out phase
  double outProgress =
      animateOut ? MAX(0.0, MIN(1.0, (endSec - nowSec) / outDuration)) : 1.0;
  double outIntensity = 0.5, outFrequency = 0.5;
  if (animateOut) {
    [paramGetAPI getFloatValue:&outIntensity
                 fromParameter:kKKParamAnimateOutIntensity
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&outFrequency
                 fromParameter:kKKParamAnimateOutFrequency
                        atTime:renderTime];
  }
  KKEasingCurve outEasing = (KKEasingCurve)outCurve;
  KKTimingInterpolator outInterp = ^double(double t) {
    return KKApplyEasing(t, outEasing, outIntensity, outFrequency);
  };
  KKTimingPhase *outPhase = [KKTimingPhase phaseWithEnabled:animateOut
                                                   duration:outDuration
                                                   progress:outProgress
                                                interpolate:outInterp];

  // Mid phase
  int midHoldInt = KKHoldEffectNone;
  [paramGetAPI getIntValue:&midHoldInt
             fromParameter:kKKParamMidHoldEffect
                    atTime:renderTime];
  KKHoldEffect midHold = (KKHoldEffect)midHoldInt;
  double midHoldIntensity = 0.5, midHoldFrequency = 0.5;
  [paramGetAPI getFloatValue:&midHoldIntensity
               fromParameter:kKKParamMidHoldIntensity
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&midHoldFrequency
               fromParameter:kKKParamMidHoldFrequency
                      atTime:renderTime];
  int midHoldSeed = 0;
  [paramGetAPI getIntValue:&midHoldSeed
             fromParameter:kKKParamMidHoldSeed
                    atTime:renderTime];

  static const double kMidOverlap = 0.3;
  double inEnd = startSec + (animateIn ? inDuration : 0);
  double outStart = endSec - (animateOut ? outDuration : 0);
  double midStart = inEnd - (animateIn ? inDuration * kMidOverlap : 0);
  double midEnd = outStart + (animateOut ? outDuration * kMidOverlap : 0);
  double midDur = MAX(0.0, midEnd - midStart);
  double midProgress =
      (midDur > 0) ? MAX(0.0, MIN(1.0, (nowSec - midStart) / midDur)) : 1.0;
  KKTimingInterpolator holdInterp = ^double(double t) {
    return KKApplyHoldEffect(t, midHold, midHoldIntensity, midHoldFrequency,
                             midHoldSeed);
  };
  KKTimingPhase *midPhase = [KKTimingPhase phaseWithEnabled:YES
                                                   duration:midDur
                                                   progress:midProgress
                                                interpolate:holdInterp];

  return [KKTimingResult resultWithIn:inPhase mid:midPhase out:outPhase];
}

- (BOOL)addInfoParameterWithText:(NSString *)text
                            icon:(nullable NSImage *)icon
                     parameterID:(UInt32)parameterID
                         withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                           error:(NSError **)error {
  kkClassRegistry([self class], kKKInfoTexts)[@(parameterID)] = [text copy];
  if (icon)
    kkClassRegistry([self class], kKKInfoIcons)[@(parameterID)] = icon;

  if (!KKAddParam([paramAPI addCustomParameterWithName:@""
                                           parameterID:parameterID
                                          defaultValue:@(parameterID)
                                        parameterFlags:kCustomUIDisabled],
                  error, @"Unable to add info parameter")) {
    kkClassRegistry([self class], kKKInfoTexts)[@(parameterID)] = nil;
    return NO;
  }
  return YES;
}

- (BOOL)addInfoParameterWithAttributedText:(NSAttributedString *)text
                                      icon:(nullable NSImage *)icon
                               parameterID:(UInt32)parameterID
                                   withAPI:
                                       (id<FxParameterCreationAPI_v5>)paramAPI
                                     error:(NSError **)error {
  kkClassRegistry([self class], kKKInfoAttrTexts)[@(parameterID)] = [text copy];
  if (icon)
    kkClassRegistry([self class], kKKInfoIcons)[@(parameterID)] = icon;

  if (!KKAddParam([paramAPI addCustomParameterWithName:@""
                                           parameterID:parameterID
                                          defaultValue:@(parameterID)
                                        parameterFlags:kCustomUIDisabled],
                  error, @"Unable to add info parameter")) {
    kkClassRegistry([self class], kKKInfoAttrTexts)[@(parameterID)] = nil;
    return NO;
  }
  return YES;
}

- (BOOL)addSeparatorParameterWithText:(nullable NSString *)text
                                 icon:(nullable NSImage *)icon
                          parameterID:(UInt32)parameterID
                              withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                error:(NSError **)error {
  kkClassRegistry([self class], kKKSepTexts)[@(parameterID)] =
      [text copy] ?: @"";
  if (icon)
    kkClassRegistry([self class], kKKSepIcons)[@(parameterID)] = icon;

  if (!KKAddParam([paramAPI addCustomParameterWithName:@""
                                           parameterID:parameterID
                                          defaultValue:@(parameterID)
                                        parameterFlags:kCustomUIDisabled],
                  error, @"Unable to add separator parameter")) {
    kkClassRegistry([self class], kKKSepTexts)[@(parameterID)] = nil;
    return NO;
  }
  return YES;
}

- (BOOL)addUpdateBannerParameterWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                  error:(NSError **)error {
  return KKAddParam([paramAPI addCustomParameterWithName:@""
                                             parameterID:kKKParamUpdateBanner
                                            defaultValue:@(kKKParamUpdateBanner)
                                          parameterFlags:kCustomUIDisabled],
                    error, @"Unable to add update banner parameter");
}

- (void)updateTimingParameterVisibility {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramGetAPI || !paramSetAPI)
    return;

  BOOL expandedTiming = NO;
  [paramGetAPI getBoolValue:&expandedTiming
              fromParameter:kKKParamTimingExpanded
                     atTime:kCMTimeZero];

  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kKKParamAnimateIn];
  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kKKParamAnimateOut];

  BOOL animateIn = NO, animateOut = NO;
  int inCurve = KKEasingCurveEaseOut, outCurve = KKEasingCurveEaseOut;
  if (expandedTiming) {
    [paramGetAPI getBoolValue:&animateIn
                fromParameter:kKKParamAnimateIn
                       atTime:kCMTimeZero];
    [paramGetAPI getBoolValue:&animateOut
                fromParameter:kKKParamAnimateOut
                       atTime:kCMTimeZero];
    [paramGetAPI getIntValue:&inCurve
               fromParameter:kKKParamAnimateInInterpolation
                      atTime:kCMTimeZero];
    [paramGetAPI getIntValue:&outCurve
               fromParameter:kKKParamAnimateOutInterpolation
                      atTime:kCMTimeZero];
  }

  int sel = KKTimingGraphSectionMid;
  [paramGetAPI getIntValue:&sel
             fromParameter:kKKParamTimingSelectedSection
                    atTime:kCMTimeZero];

  UInt32 alwaysHidden[] = {
      kKKParamAnimateInDuration,       kKKParamAnimateOutDuration,
      kKKParamAnimateInInterpolation,  kKKParamAnimateInIntensity,
      kKKParamAnimateOutInterpolation, kKKParamAnimateOutIntensity,
      kKKParamMidHoldEffect,           kKKParamMidHoldIntensity,
      kKKParamAnimateInFrequency,      kKKParamAnimateOutFrequency,
      kKKParamMidHoldFrequency,        kKKParamMidHoldSeed,
  };
  for (NSUInteger i = 0; i < sizeof(alwaysHidden) / sizeof(alwaysHidden[0]);
       i++) {
    [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                       toParameter:alwaysHidden[i]];
  }

  for (NSNumber *paramID in self.timingGroupExtraParamIDs) {
    FxParameterFlags flagTiming =
        expandedTiming ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
    [paramSetAPI setParameterFlags:flagTiming
                       toParameter:paramID.unsignedIntValue];
  }
}

@end
