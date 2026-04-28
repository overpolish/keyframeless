/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Math/KKEasing.h"
#import "../Math/KKTimingStage.h"
#import "../Views/KKTimingGraphView.h"
#import "KKConstants.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

static const FxParameterFlags kCustomUI = kFxParameterFlag_NOT_ANIMATABLE |
                                          kFxParameterFlag_CUSTOM_UI |
                                          kFxParameterFlag_USE_FULL_VIEW_WIDTH;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (Timing)

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
    return [KKTimingResult resultWithIn:off hold:off out:off];
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

  // Hold phase
  int holdEffectInt = KKHoldEffectNone;
  [paramGetAPI getIntValue:&holdEffectInt
             fromParameter:kKKParamHoldEffect
                    atTime:renderTime];
  KKHoldEffect holdEffect = (KKHoldEffect)holdEffectInt;
  double holdIntensity = 0.5, holdFrequency = 0.5;
  [paramGetAPI getFloatValue:&holdIntensity
               fromParameter:kKKParamHoldIntensity
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&holdFrequency
               fromParameter:kKKParamHoldFrequency
                      atTime:renderTime];
  int holdSeed = 0;
  [paramGetAPI getIntValue:&holdSeed
             fromParameter:kKKParamHoldSeed
                    atTime:renderTime];

  static const double kHoldOverlap = 0.3;
  double inEnd = startSec + (animateIn ? inDuration : 0);
  double outStart = endSec - (animateOut ? outDuration : 0);
  double holdStart = inEnd - (animateIn ? inDuration * kHoldOverlap : 0);
  double holdEnd = outStart + (animateOut ? outDuration * kHoldOverlap : 0);
  double holdDur = MAX(0.0, holdEnd - holdStart);
  double holdProgress =
      (holdDur > 0) ? MAX(0.0, MIN(1.0, (nowSec - holdStart) / holdDur)) : 1.0;
  KKTimingInterpolator holdInterp = ^double(double t) {
    return KKApplyHoldEffect(t, holdEffect, holdIntensity, holdFrequency,
                             holdSeed);
  };
  KKTimingPhase *holdPhase = [KKTimingPhase phaseWithEnabled:YES
                                                    duration:holdDur
                                                    progress:holdProgress
                                                 interpolate:holdInterp];

  return [KKTimingResult resultWithIn:inPhase hold:holdPhase out:outPhase];
}

static void _setFlagsIfNeeded(id<FxParameterSettingAPI_v5> setAPI,
                              id<FxParameterRetrievalAPI_v6> getAPI,
                              FxParameterFlags flags, UInt32 paramID) {
  FxParameterFlags cur = 0;
  [getAPI getParameterFlags:&cur fromParameter:paramID];
  if (cur != flags)
    [setAPI setParameterFlags:flags toParameter:paramID];
}

- (void)updateTimingParameterVisibility {
  // setParameterFlags on params in the kKKParam range (9000s) crashes FCP
  // when called synchronously from `parameterChanged:` — the host action
  // wrapping the user's interaction (group toggle, OSC drag) ends with our
  // flag-writes in the bulk-change list and FCP's transaction processor
  // null-derefs walking the channel tree. Defer onto the main queue inside
  // a fresh action scope so the writes land outside FCP's host action.
  // See project_published_custom_ui_cascade.md.
  // Get/Set APIs MUST be resolved inside the deferred action scope (after
  // startAction) — capturing them sync from `parameterChanged:` re-binds
  // writes to FCP's host bulk-change and re-triggers the cascade. Resolving
  // them on the main queue without a live action returns nil, so the order
  // is: startAction first, then apiForProtocol for get/set.
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!actAPI)
      return;
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> paramGetAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> paramSetAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (!paramGetAPI || !paramSetAPI) {
      [actAPI endAction:strongSelf];
      return;
    }

    BOOL expandedTiming = NO;
    [paramGetAPI getBoolValue:&expandedTiming
                fromParameter:kKKParamTimingExpanded
                       atTime:kCMTimeZero];
    if ([strongSelf forceShowAllParameters])
      expandedTiming = YES;
    _setFlagsIfNeeded(paramSetAPI, paramGetAPI,
                      expandedTiming ? kCustomUI : kFxParameterFlag_HIDDEN,
                      kKKParamTimingCurvePreview);
    [actAPI endAction:strongSelf];
  });
}

- (void)updateMotionBlurParameterVisibility {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramGetAPI || !paramSetAPI)
    return;

  BOOL expanded = NO;
  [paramGetAPI getBoolValue:&expanded
              fromParameter:kKKParamMotionBlurExpanded
                     atTime:kCMTimeZero];
  if ([self forceShowAllParameters])
    expanded = YES;

  FxParameterFlags flag =
      expanded ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  FxParameterFlags toggleFlag =
      expanded ? kFxParameterFlag_NOT_ANIMATABLE
               : (kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE);
  _setFlagsIfNeeded(paramSetAPI, paramGetAPI, flag, kKKParamMotionBlurShutter);
  _setFlagsIfNeeded(paramSetAPI, paramGetAPI, flag, kKKParamMotionBlurQuality);
  _setFlagsIfNeeded(paramSetAPI, paramGetAPI, toggleFlag,
                    kKKParamMotionBlurTransitionsOnly);
  _setFlagsIfNeeded(paramSetAPI, paramGetAPI, toggleFlag,
                    kKKParamMotionBlurAdaptiveQuality);
}

@end
