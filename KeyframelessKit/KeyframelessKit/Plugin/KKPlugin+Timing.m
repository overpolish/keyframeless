/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../KKLog.h"
#import "../Math/KKEasing.h"
#import "../Math/KKTimingStage.h"
#import "../Update/KKUpdateChecker.h"
#import "../Views/KKAnimatableProperty.h"
#import "../Views/KKStageSequencerView.h"
#import "../Views/KKTimingGraphView.h"
#import "KKConstants.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

/// Last-known lanes snapshot. Updated whenever the view writes lanes
/// (segment selection, lane toggle, etc). Read by parameterChanged: to
/// build live updates without touching the JSON param.
NSArray<KKTimingLane *> *KKMultiStageLanesSnapshot = nil;
/// Pending lanes for live graph updates. Written from parameterChanged:,
/// consumed by multiStageFlushPendingLanes called from drawOSC.
NSArray<KKTimingLane *> *KKMultiStagePendingLanes = nil;
/// Reference to the sequencer view for the OSC flush path.
void *KKMultiStageSequencerView = nil;
/// Guard flag: skip parameterChanged staging while a segment selection
/// callback is in progress (it writes native params which would re-enter).
BOOL KKMultiStageSelectionInProgress = NO;

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
                                      parameterMax:10.0
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
                                      parameterMax:10.0
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
                                 defaultValue:YES
                               parameterFlags:kFxParameterFlag_HIDDEN |
                                              kFxParameterFlag_NOT_ANIMATABLE],
                  error, @"Unable to add Timing expanded toggle"))
    return NO;

  if (!KKAddParam([paramAPI
                      addPopupMenuWithName:@""
                               parameterID:kKKParamTimingSelectedSection
                              defaultValue:KKTimingGraphSectionHold
                               menuEntries:@[ @"In", @"Hold", @"Out" ]
                            parameterFlags:kFxParameterFlag_HIDDEN |
                                           kFxParameterFlag_NOT_ANIMATABLE],
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

  if (!KKAddParam([paramAPI addFloatSliderWithName:@"Hold Intensity"
                                       parameterID:kKKParamHoldIntensity
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
                                       parameterID:kKKParamHoldFrequency
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

  if (!KKAddParam([paramAPI
                      addToggleButtonWithName:@""
                                  parameterID:kKKParamMultiStageEnabled
                                 defaultValue:YES // TODO: revert to NO
                               parameterFlags:kFxParameterFlag_HIDDEN |
                                              kFxParameterFlag_NOT_ANIMATABLE],
                  error, @"Unable to add multi-stage enabled toggle"))
    return NO;

  if (!KKAddParam(
          [paramAPI addStringParameterWithName:@""
                                   parameterID:kKKParamMultiStageData
                                  defaultValue:@""
                                parameterFlags:kFxParameterFlag_HIDDEN |
                                               kFxParameterFlag_NOT_ANIMATABLE],
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
                            parameterFlags:kFxParameterFlag_HIDDEN |
                                           kFxParameterFlag_NOT_ANIMATABLE],
                  error, @"Unable to add multi-stage selected property"))
    return NO;

  if (!KKAddParam([paramAPI
                      addIntSliderWithName:@""
                               parameterID:kKKParamMultiStageSelectedStage
                              defaultValue:0
                              parameterMin:0
                              parameterMax:64
                                 sliderMin:0
                                 sliderMax:64
                                     delta:1
                            parameterFlags:kFxParameterFlag_HIDDEN |
                                           kFxParameterFlag_NOT_ANIMATABLE],
                  error, @"Unable to add multi-stage selected stage"))
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

- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)multiStageValuesAtTime:
    (CMTime)renderTime {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!paramGetAPI || !timingAPI)
    return nil;

  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled
              fromParameter:kKKParamMultiStageEnabled
                     atTime:renderTime];
  if (!enabled)
    return nil;

  NSString *json = nil;
  [paramGetAPI getStringParameterValue:&json
                         fromParameter:kKKParamMultiStageData];
  NSMutableArray<KKTimingLane *> *lanes =
      [[KKTimingLane lanesFromJSON:json] mutableCopy];
  if (!lanes.count)
    return nil;

  // Live param override: for each lane with a selected segment, read the
  // native param values so the preview updates while the user drags sliders
  // (Canvas pattern: KKParamsToPath at render time).
  NSArray<KKAnimatableProperty *> *props = [self animatableProperties];
  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    NSInteger selSeg = lane.selectedSegment;
    if (selSeg < 0 || (NSUInteger)selSeg >= lane.segments.count)
      continue;
    for (KKAnimatableProperty *prop in props) {
      if ([prop.label isEqualToString:lane.propertyLabel] &&
          prop.valueParamIDs.count > 0) {
        NSMutableArray<NSNumber *> *liveVals =
            [NSMutableArray arrayWithCapacity:prop.valueParamIDs.count];
        for (NSNumber *pid in prop.valueParamIDs) {
          double v = 0;
          [paramGetAPI getFloatValue:&v
                       fromParameter:pid.unsignedIntValue
                              atTime:renderTime];
          [liveVals addObject:@(v)];
        }
        KKTimingLane *mLane = [lane copy];
        NSMutableArray *mSegs = [mLane.segments mutableCopy];
        KKTimingSegment *mSeg = [mSegs[selSeg] copy];
        mSeg.values = liveVals;
        mSegs[selSeg] = mSeg;
        mLane.segments = mSegs;
        lanes[li] = mLane;
        break;
      }
    }
  }

  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];
  double startSec = CMTimeGetSeconds(effectStart);
  double durSec = CMTimeGetSeconds(effectDuration);
  double nowSec = CMTimeGetSeconds(renderTime);
  double frac = (durSec > 0) ? (nowSec - startSec) / durSec : 0.0;
  frac = MAX(0.0, MIN(1.0, frac));

  NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *result =
      [NSMutableDictionary dictionaryWithCapacity:lanes.count];

  for (KKTimingLane *lane in lanes) {
    if (!lane.enabled)
      continue;
    NSArray<KKTimingSegment *> *segments = lane.segments;
    if (!segments.count)
      continue;

    KKTimingSegment *active = nil;
    for (KKTimingSegment *seg in segments) {
      if (frac >= seg.start && frac < seg.end) {
        active = seg;
        break;
      }
    }
    if (!active && frac >= segments.lastObject.end)
      active = segments.lastObject;

    if (!active)
      continue;

    if (active.type == KKSegmentTypeHold) {
      result[lane.propertyLabel] = active.values;
    } else {
      NSUInteger idx = [segments indexOfObjectIdenticalTo:active];
      NSArray<NSNumber *> *fromVals = active.values;
      NSArray<NSNumber *> *toVals = active.values;

      if (idx > 0)
        fromVals = segments[idx - 1].values;
      if (idx + 1 < segments.count)
        toVals = segments[idx + 1].values;

      double segDur = active.end - active.start;
      double t = (segDur > 0) ? (frac - active.start) / segDur : 1.0;
      t = MAX(0.0, MIN(1.0, t));
      double easedT =
          KKApplyEasing(t, active.easing, active.intensity, active.frequency);

      NSUInteger valCount = MIN(fromVals.count, toVals.count);
      NSMutableArray<NSNumber *> *interpolated =
          [NSMutableArray arrayWithCapacity:valCount];
      for (NSUInteger i = 0; i < valCount; i++) {
        double fv = fromVals[i].doubleValue;
        double tv = toVals[i].doubleValue;
        [interpolated addObject:@(fv + (tv - fv) * easedT)];
      }
      result[lane.propertyLabel] = interpolated;
    }
  }

  return result.count ? result : nil;
}

- (BOOL)multiStageHandleParameterChanged:(UInt32)parameterID
                                  atTime:(CMTime)time {
  if (KKMultiStageSelectionInProgress)
    return NO;

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return NO;

  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled
              fromParameter:kKKParamMultiStageEnabled
                     atTime:time];
  if (!enabled)
    return NO;

  NSArray<KKAnimatableProperty *> *props = [self animatableProperties];
  if (!props.count)
    return NO;

  KKAnimatableProperty *matchedProp = nil;
  for (KKAnimatableProperty *prop in props) {
    for (NSNumber *pid in prop.valueParamIDs) {
      if (pid.unsignedIntValue == parameterID) {
        matchedProp = prop;
        break;
      }
    }
    if (matchedProp)
      break;
  }
  if (!matchedProp)
    return NO;

  NSMutableArray<KKTimingLane *> *lanes =
      [KKMultiStageLanesSnapshot mutableCopy];
  if (!lanes)
    return NO;

  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    if (![lane.propertyLabel isEqualToString:matchedProp.label])
      continue;
    NSInteger selSeg = lane.selectedSegment;
    if (selSeg < 0 || (NSUInteger)selSeg >= lane.segments.count)
      break;

    NSMutableArray<NSNumber *> *liveVals =
        [NSMutableArray arrayWithCapacity:matchedProp.valueParamIDs.count];
    for (NSNumber *pid in matchedProp.valueParamIDs) {
      double v = 0;
      [paramGetAPI getFloatValue:&v
                   fromParameter:pid.unsignedIntValue
                          atTime:time];
      [liveVals addObject:@(v)];
    }

    KKTimingLane *mLane = [lane copy];
    NSMutableArray *mSegs = [mLane.segments mutableCopy];
    KKTimingSegment *mSeg = [mSegs[selSeg] copy];
    mSeg.values = liveVals;
    mSegs[selSeg] = mSeg;
    mLane.segments = mSegs;
    lanes[li] = mLane;

    NSArray<KKTimingLane *> *updated = [lanes copy];
    KKMultiStagePendingLanes = updated;
    KKMultiStageLanesSnapshot = updated;

    // Persist to JSON so values survive clip re-selection.
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI) {
      NSString *json = [KKTimingLane jsonFromLanes:updated];
      if (json)
        [paramSetAPI setStringParameterValue:json
                                 toParameter:kKKParamMultiStageData];
    }
    return YES;
  }
  return NO;
}

+ (void)multiStageFlushPendingLanes {
  NSArray<KKTimingLane *> *pending = KKMultiStagePendingLanes;
  if (!pending)
    return;
  KKMultiStagePendingLanes = nil;
  KKStageSequencerView *seq =
      (__bridge KKStageSequencerView *)KKMultiStageSequencerView;
  if (!seq)
    return;
  dispatch_async(dispatch_get_main_queue(), ^{
    seq.lanes = pending;
  });
}

static double KKPendingPlayheadFraction = -1;
static double KKPendingPlayheadDuration = -1;
static BOOL KKPlayheadDispatchPending = NO;

+ (void)multiStageUpdatePlayhead:(double)fraction duration:(double)duration {
  KKStageSequencerView *seq =
      (__bridge KKStageSequencerView *)KKMultiStageSequencerView;
  if (!seq)
    return;
  KKPendingPlayheadFraction = fraction;
  KKPendingPlayheadDuration = duration;
  if (KKPlayheadDispatchPending)
    return;
  KKPlayheadDispatchPending = YES;
  dispatch_async(dispatch_get_main_queue(), ^{
    KKPlayheadDispatchPending = NO;
    seq.effectDuration = KKPendingPlayheadDuration;
    seq.playheadFraction = KKPendingPlayheadFraction;
  });
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

static void _setFlagsIfNeeded(id<FxParameterSettingAPI_v5> setAPI,
                              id<FxParameterRetrievalAPI_v6> getAPI,
                              FxParameterFlags flags, UInt32 paramID) {
  FxParameterFlags cur = 0;
  [getAPI getParameterFlags:&cur fromParameter:paramID];
  if (cur != flags)
    [setAPI setParameterFlags:flags toParameter:paramID];
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

  _setFlagsIfNeeded(paramSetAPI, paramGetAPI,
                    expandedTiming ? kCustomUI : kFxParameterFlag_HIDDEN,
                    kKKParamTimingCurvePreview);

  _setFlagsIfNeeded(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                    kKKParamAnimateIn);
  _setFlagsIfNeeded(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                    kKKParamAnimateOut);

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

  int sel = KKTimingGraphSectionHold;
  [paramGetAPI getIntValue:&sel
             fromParameter:kKKParamTimingSelectedSection
                    atTime:kCMTimeZero];

  UInt32 alwaysHidden[] = {
      kKKParamAnimateInDuration,
      kKKParamAnimateOutDuration,
      kKKParamAnimateInInterpolation,
      kKKParamAnimateInIntensity,
      kKKParamAnimateOutInterpolation,
      kKKParamAnimateOutIntensity,
      kKKParamHoldEffect,
      kKKParamHoldIntensity,
      kKKParamAnimateInFrequency,
      kKKParamAnimateOutFrequency,
      kKKParamHoldFrequency,
      kKKParamHoldSeed,
      kKKParamMultiStageData,
      kKKParamMultiStageSelectedProperty,
      kKKParamMultiStageSelectedStage,
  };
  for (NSUInteger i = 0; i < sizeof(alwaysHidden) / sizeof(alwaysHidden[0]);
       i++) {
    _setFlagsIfNeeded(paramSetAPI, paramGetAPI, kFxParameterFlag_HIDDEN,
                      alwaysHidden[i]);
  }

  for (NSNumber *paramID in self.timingGroupExtraParamIDs) {
    FxParameterFlags flagTiming =
        expandedTiming ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
    _setFlagsIfNeeded(paramSetAPI, paramGetAPI, flagTiming,
                      paramID.unsignedIntValue);
  }
}

@end
