/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Math/KKEasing.h"
#import "../Math/KKGradientSampling.h"
#import "../Math/KKTimingStage.h"
#import "../Views/KKAnimatableProperty.h"
#import "../Views/StageSequencer/KKStageSequencerView.h"
#import "KKColor.h"
#import "KKConstants.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

/// Stamps the "recent parameter change" timestamp used by the multi-stage
/// pump to suppress render-sourced playhead updates in the wake of a slider
/// drag. Defined in KKPlugin+MultiStagePump.m.
extern void KKMultiStageMarkParameterChanged(void);

/// Whether a property's native param list is a single gradient (the kind
/// consumes all segment values, so a gradient property has exactly one
/// entry in valueParamIDs).
static BOOL KKPropertyIsGradient(KKAnimatableProperty *prop) {
  for (NSNumber *k in prop.valueParamKinds)
    if (k.integerValue == KKAnimatableParamKindGradient)
      return YES;
  return NO;
}

/// Resolves the segment covering `frac` (or clamps to first/last).
static KKTimingSegment *
KKMultiStageSegmentForFraction(NSArray<KKTimingSegment *> *segments,
                               double frac) {
  for (KKTimingSegment *seg in segments) {
    if (frac >= seg.start && frac < seg.end)
      return seg;
  }
  if (frac >= segments.lastObject.end)
    return segments.lastObject;
  if (frac < segments.firstObject.start)
    return segments.firstObject;
  return nil;
}

/// Evaluates a hold-type segment at `frac`, returning either the raw
/// segment values or a per-component modulation when a hold effect is set.
static NSArray<NSNumber *> *KKMultiStageHoldValues(KKTimingSegment *active,
                                                   double frac,
                                                   BOOL gradientLane) {
  double segDur = active.end - active.start;
  double t = (segDur > 0) ? (frac - active.start) / segDur : 0.0;
  t = MAX(0.0, MIN(1.0, t));

  if (gradientLane) {
    NSArray<NSNumber *> *baseLut = KKGradientFlatLUTFromStops(
        KKGradientStopsFromFlat(active.values) ?: @[], KK_GRADIENT_LUT_SIZE);
    if (active.holdEffect == KKHoldEffectNone)
      return baseLut;
    // Gradient LUTs share a single factor so colour stops scale together
    // (independent per-channel modulation would rainbow-shift the gradient).
    double factor = KKApplyHoldEffect(t, active.holdEffect, active.intensity,
                                      active.frequency, (int)active.seed);
    NSMutableArray<NSNumber *> *modulated =
        [NSMutableArray arrayWithCapacity:baseLut.count];
    for (NSNumber *v in baseLut)
      [modulated addObject:@(v.doubleValue * factor)];
    return modulated;
  }

  if (active.holdEffect == KKHoldEffectNone)
    return active.values;

  NSMutableArray<NSNumber *> *modulated =
      [NSMutableArray arrayWithCapacity:active.values.count];
  if (active.linked) {
    // Single shared factor: components modulate in lockstep (e.g. Radius
    // X/Y stays aspect-locked through a Bounce).
    double factor = KKApplyHoldEffect(t, active.holdEffect, active.intensity,
                                      active.frequency, (int)active.seed);
    for (NSNumber *v in active.values)
      [modulated addObject:@(v.doubleValue * factor)];
  } else {
    // Independent factor per component (e.g. Position wobbling randomly
    // in 2D instead of along a single diagonal).
    for (NSUInteger i = 0; i < active.values.count; i++) {
      double factor = KKApplyHoldEffectForComponent(
          t, active.holdEffect, active.intensity, active.frequency,
          (int)active.seed, (int)i);
      [modulated addObject:@(active.values[i].doubleValue * factor)];
    }
  }
  return modulated;
}

/// Evaluates a transition segment between `fromVals` and `toVals` using
/// the segment's easing. Last-segment transitions are treated as animate-out
/// by mirroring time, matching the classic single-stage behaviour.
static NSArray<NSNumber *> *
KKMultiStageTransitionValues(NSArray<KKTimingSegment *> *segments,
                             NSUInteger idx, double frac, BOOL gradientLane,
                             NSArray<NSNumber *> *componentKinds) {
  KKTimingSegment *active = segments[idx];
  NSArray<NSNumber *> *fromVals = KKTimingBoundaryBefore(idx, segments);
  NSArray<NSNumber *> *toVals = KKTimingBoundaryAfter(idx, segments);

  double segDur = active.end - active.start;
  double t = (segDur > 0) ? (frac - active.start) / segDur : 1.0;
  t = MAX(0.0, MIN(1.0, t));
  BOOL isAnimateOut = (idx == segments.count - 1);
  double ti = isAnimateOut ? (1.0 - t) : t;
  double easedT =
      KKApplyEasing(ti, active.easing, active.intensity, active.frequency);
  if (isAnimateOut)
    easedT = 1.0 - easedT;

  if (gradientLane)
    return KKGradientInterpFlatLUT(fromVals, toVals, easedT,
                                   KK_GRADIENT_LUT_SIZE);
  NSUInteger valCount = MIN(fromVals.count, toVals.count);
  NSMutableArray<NSNumber *> *interpolated =
      [NSMutableArray arrayWithCapacity:valCount];
  for (NSUInteger i = 0; i < valCount; i++) {
    double fv = fromVals[i].doubleValue;
    double tv = toVals[i].doubleValue;
    BOOL isBool = i < componentKinds.count &&
                  componentKinds[i].integerValue == KKAnimatableParamKindBool;
    if (isBool) {
      // Bool components are step values authored per-segment. Respect the
      // transition's own stored value across its whole duration so HTH
      // overrides (e.g. MagicMove "rotate with motion" toggled on the
      // transition only) take effect at render time.
      NSNumber *own = (i < active.values.count) ? active.values[i] : @(fv);
      [interpolated addObject:own];
    } else {
      [interpolated addObject:@(fv + (tv - fv) * easedT)];
    }
  }
  return interpolated;
}

/// Returns a mutated copy of `lanes` where any lane with an active selected
/// segment gets its values replaced with the property's current native
/// param values. This lets the preview track slider drags in real time
/// (Canvas pattern: KKParamsToPath at render time).
static NSMutableArray<KKTimingLane *> *
KKMultiStageApplyLiveOverrides(NSMutableArray<KKTimingLane *> *lanes,
                               NSArray<KKAnimatableProperty *> *props,
                               id<FxParameterRetrievalAPI_v6> paramGetAPI,
                               CMTime renderTime) {
  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    NSInteger selSeg = lane.selectedSegment;
    if (selSeg < 0 || (NSUInteger)selSeg >= lane.segments.count)
      continue;
    for (KKAnimatableProperty *prop in props) {
      if (![prop.label isEqualToString:lane.propertyLabel] ||
          prop.valueParamIDs.count == 0)
        continue;
      NSArray<NSNumber *> *liveVals = [prop readValuesWithGetAPI:paramGetAPI
                                                          atTime:renderTime];
      if (!liveVals)
        break;
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
  return lanes;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (MultiStage)

- (NSDictionary<NSString *, NSArray<NSNumber *> *> *)multiStageValuesAtTime:
    (CMTime)renderTime {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!paramGetAPI || !timingAPI)
    return nil;

  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  if (!lanes.count)
    return nil;

  NSArray<KKAnimatableProperty *> *props = [self animatableProperties];
  lanes = KKMultiStageApplyLiveOverrides(lanes, props, paramGetAPI, renderTime);

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

  NSMutableDictionary<NSString *, KKAnimatableProperty *> *propByLabel =
      [NSMutableDictionary dictionaryWithCapacity:props.count];
  for (KKAnimatableProperty *p in props)
    propByLabel[p.label] = p;

  for (KKTimingLane *lane in lanes) {
    if (!lane.enabled)
      continue;
    NSArray<KKTimingSegment *> *segments = lane.segments;
    if (!segments.count)
      continue;
    KKTimingSegment *active = KKMultiStageSegmentForFraction(segments, frac);
    if (!active)
      continue;

    KKAnimatableProperty *prop = propByLabel[lane.propertyLabel];
    BOOL gradientLane = KKPropertyIsGradient(prop);
    if (active.type == KKSegmentTypeHold) {
      result[lane.propertyLabel] =
          KKMultiStageHoldValues(active, frac, gradientLane);
    } else {
      NSUInteger idx = [segments indexOfObjectIdenticalTo:active];
      NSMutableArray<NSNumber *> *componentKinds = nil;
      if (prop) {
        componentKinds = [NSMutableArray array];
        for (NSNumber *k in prop.valueParamKinds) {
          KKAnimatableParamKind kk = (KKAnimatableParamKind)k.integerValue;
          NSUInteger n = 1;
          switch (kk) {
          case KKAnimatableParamKindColor:
            n = 3;
            break;
          case KKAnimatableParamKindPoint:
            n = 2;
            break;
          case KKAnimatableParamKindGradient:
            n = 0;
            break;
          default:
            n = 1;
            break;
          }
          for (NSUInteger i = 0; i < n; i++)
            [componentKinds addObject:k];
        }
      }
      result[lane.propertyLabel] = KKMultiStageTransitionValues(
          segments, idx, frac, gradientLane, componentKinds);
    }
  }

  return result.count ? result : nil;
}

- (KKTimingSegment *)
    multiStageActiveSegmentForLabel:(NSString *)label
                             atTime:(CMTime)time
                           segments:(NSArray<KKTimingSegment *> **)outSegments
                             localT:(double *)outLocalT {
  if (outSegments)
    *outSegments = nil;
  if (outLocalT)
    *outLocalT = 0;

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!paramGetAPI || !timingAPI || !label.length)
    return nil;

  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  if (!lanes.count)
    return nil;

  NSArray<KKAnimatableProperty *> *props = [self animatableProperties];
  lanes = KKMultiStageApplyLiveOverrides(lanes, props, paramGetAPI, time);

  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];
  double startSec = CMTimeGetSeconds(effectStart);
  double durSec = CMTimeGetSeconds(effectDuration);
  double nowSec = CMTimeGetSeconds(time);
  double frac = (durSec > 0) ? (nowSec - startSec) / durSec : 0.0;
  frac = MAX(0.0, MIN(1.0, frac));

  for (KKTimingLane *lane in lanes) {
    if (![lane.propertyLabel isEqualToString:label])
      continue;
    if (!lane.enabled || !lane.segments.count)
      return nil;
    KKTimingSegment *active =
        KKMultiStageSegmentForFraction(lane.segments, frac);
    if (!active)
      return nil;
    if (outSegments)
      *outSegments = lane.segments;
    if (outLocalT) {
      double segDur = active.end - active.start;
      double t = (segDur > 0) ? (frac - active.start) / segDur : 0.0;
      *outLocalT = MAX(0.0, MIN(1.0, t));
    }
    return active;
  }
  return nil;
}

- (BOOL)multiStageAnyLaneInTransitionAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!paramGetAPI || !timingAPI)
    return NO;

  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  if (!lanes.count)
    return NO;

  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];
  double startSec = CMTimeGetSeconds(effectStart);
  double durSec = CMTimeGetSeconds(effectDuration);
  double nowSec = CMTimeGetSeconds(time);
  double frac = (durSec > 0) ? (nowSec - startSec) / durSec : 0.0;
  frac = MAX(0.0, MIN(1.0, frac));

  for (KKTimingLane *lane in lanes) {
    if (!lane.enabled || !lane.segments.count)
      continue;
    KKTimingSegment *active =
        KKMultiStageSegmentForFraction(lane.segments, frac);
    if (active && active.type == KKSegmentTypeTransition)
      return YES;
  }
  return NO;
}

- (KKTimingLane *)multiStageLaneForLabel:(NSString *)label atTime:(CMTime)time {
  if (!label.length)
    return nil;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return nil;
  NSMutableArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  if (!lanes.count)
    return nil;
  NSArray<KKAnimatableProperty *> *props = [self animatableProperties];
  lanes = KKMultiStageApplyLiveOverrides(lanes, props, paramGetAPI, time);
  for (KKTimingLane *lane in lanes)
    if ([lane.propertyLabel isEqualToString:label])
      return lane;
  return nil;
}

- (BOOL)multiStageSetPathData:(NSData *)pathData
                     forLabel:(NSString *)label
                 segmentIndex:(NSInteger)segmentIndex {
  if (!label.length || segmentIndex < 0)
    return NO;
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (!state)
    return NO;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return NO;

  NSMutableArray<KKTimingLane *> *lanes =
      [state.lanesSnapshot mutableCopy]
          ?: KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  if (!lanes.count)
    return NO;

  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    if (![lane.propertyLabel isEqualToString:label])
      continue;
    if ((NSUInteger)segmentIndex >= lane.segments.count)
      return NO;
    KKTimingLane *mLane = [lane copy];
    NSMutableArray *mSegs = [mLane.segments mutableCopy];
    KKTimingSegment *mSeg = [mSegs[segmentIndex] copy];
    mSeg.pathData = pathData.length > 0 ? [pathData copy] : nil;
    mSegs[segmentIndex] = mSeg;
    mLane.segments = mSegs;
    lanes[li] = mLane;

    NSMutableArray<KKTimingLane *> *normalized = [lanes mutableCopy];
    KKApplyHTHNormalizationInPlace(normalized, [self _kindsByLaneLabel]);
    NSArray<KKTimingLane *> *updated = [normalized copy];
    state.pendingLanes = updated;
    state.lanesSnapshot = updated;

    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI) {
      NSString *json = [KKTimingLane jsonFromLanes:updated];
      if (json)
        [paramSetAPI setStringParameterValue:json
                                 toParameter:kKKParamMultiStageData];
    }

    KKStageSequencerView *seq = state.sequencerView;
    NSArray<KKTimingViewRefs *> *extras =
        [state.additionalTimingViews copy] ?: @[];
    if (seq || extras.count) {
      NSArray<KKTimingLane *> *visible =
          KKFilterLanesForVisibility(updated, state.hiddenLaneLabels);
      dispatch_async(dispatch_get_main_queue(), ^{
        seq.lanes = visible;
        for (KKTimingViewRefs *r in extras)
          r.seqView.lanes = visible;
      });
    }
    return YES;
  }
  return NO;
}

- (BOOL)multiStageHandleParameterChanged:(UInt32)parameterID
                                  atTime:(CMTime)time {
  KKMultiStageMarkParameterChanged();
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (!state || state.selectionInProgress)
    return NO;

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
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

  NSMutableArray<KKTimingLane *> *lanes = [state.lanesSnapshot mutableCopy];
  if (!lanes)
    return NO;

  for (NSUInteger li = 0; li < lanes.count; li++) {
    KKTimingLane *lane = lanes[li];
    if (![lane.propertyLabel isEqualToString:matchedProp.label])
      continue;
    NSInteger selSeg = lane.selectedSegment;
    if (selSeg < 0 || (NSUInteger)selSeg >= lane.segments.count)
      break;

    NSArray<NSNumber *> *liveVals =
        [matchedProp readValuesWithGetAPI:paramGetAPI atTime:time];
    if (!liveVals)
      break;

    KKTimingLane *mLane = [lane copy];
    NSMutableArray *mSegs = [mLane.segments mutableCopy];
    KKTimingSegment *mSeg = [mSegs[selSeg] copy];
    mSeg.values = liveVals;
    mSegs[selSeg] = mSeg;
    mLane.segments = mSegs;
    lanes[li] = mLane;

    KKApplyHTHNormalizationInPlace(lanes, [self _kindsByLaneLabel]);
    NSArray<KKTimingLane *> *updated = [lanes copy];
    state.pendingLanes = updated;
    state.lanesSnapshot = updated;

    // Persist to JSON so values survive clip re-selection.
    id<FxParameterSettingAPI_v5> paramSetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (paramSetAPI) {
      NSString *json = [KKTimingLane jsonFromLanes:updated];
      if (json)
        [paramSetAPI setStringParameterValue:json
                                 toParameter:kKKParamMultiStageData];
    }

    // Push to the view immediately — pendingLanes flush only runs on the
    // next drawOSC/render tick, which is too slow for live picker edits.
    KKStageSequencerView *seq = state.sequencerView;
    NSArray<KKTimingViewRefs *> *extras =
        [state.additionalTimingViews copy] ?: @[];
    if (seq || extras.count) {
      NSArray<KKTimingLane *> *visible =
          KKFilterLanesForVisibility(updated, state.hiddenLaneLabels);
      dispatch_async(dispatch_get_main_queue(), ^{
        seq.lanes = visible;
        for (KKTimingViewRefs *r in extras)
          r.seqView.lanes = visible;
      });
    }
    return YES;
  }
  return NO;
}

@end
#pragma clang diagnostic pop
