/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimingEvaluation.h"

#import "../Plugin/KKColor.h"
#import "KKBezierPath.h"
#import "KKEasing.h"
#import "KKGradientSampling.h"

const double KKRotateWithMotionWindowSeconds = 1.0 / 12.0;

BOOL KKEvaluateBezierPathPosition(KKTimingSegment *active, BOOL isAnimateOut,
                                  double localT, simd_float2 fromPos,
                                  simd_float2 toPos, simd_float2 *outPos) {
  if (!active || active.type != KKSegmentTypeTransition ||
      active.pathData.length == 0)
    return NO;
  KKBezierPath *path = [KKBezierPath pathWithData:active.pathData];
  if (!path)
    return NO;
  double ti = isAnimateOut ? (1.0 - localT) : localT;
  double easedT =
      KKApplyEasing(ti, active.easing, active.intensity, active.frequency);
  if (isAnimateOut)
    easedT = 1.0 - easedT;
  *outPos = [path positionAtT:(float)easedT start:fromPos end:toPos];
  return YES;
}

double KKRotateWithMotionDeltaRadians(double vx) {
  return vx * 5.0 * (M_PI / 180.0);
}

KKTimingSegment *
KKTimingSegmentForFraction(NSArray<KKTimingSegment *> *segments, double frac) {
  if (!segments.count)
    return nil;
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

/// Expands a slot-level kinds array into per-scalar kinds, matching the
/// shape of `segment.values`. Color → 3, Point → 2, Gradient → 0
/// (variable), Bool → 1, Float → 1. Returns nil when `slotKinds` is nil/
/// empty so callers fall back to "treat everything as Float".
static NSArray<NSNumber *> *_Nullable KKExpandComponentKinds(
    NSArray<NSNumber *> *_Nullable slotKinds) {
  if (!slotKinds.count)
    return nil;
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (NSNumber *k in slotKinds) {
    KKAnimatableParamKind kind = (KKAnimatableParamKind)k.integerValue;
    NSUInteger n = 1;
    switch (kind) {
    case KKAnimatableParamKindColor:
      n = 3;
      break;
    case KKAnimatableParamKindPoint:
      n = 2;
      break;
    case KKAnimatableParamKindGradient:
    case KKAnimatableParamKindMorph:
      n = 0;
      break;
    default:
      n = 1;
      break;
    }
    for (NSUInteger i = 0; i < n; i++)
      [out addObject:k];
  }
  return out;
}

static BOOL KKLaneIsGradient(KKTimingLane *lane) {
  for (NSNumber *k in lane.valueComponentKinds)
    if (k.integerValue == KKAnimatableParamKindGradient)
      return YES;
  return NO;
}

static NSArray<NSNumber *> *KKEvaluateHold(KKTimingSegment *active, double frac,
                                           BOOL gradientLane) {
  double segDur = active.end - active.start;
  double t = (segDur > 0) ? (frac - active.start) / segDur : 0.0;
  t = MAX(0.0, MIN(1.0, t));

  if (gradientLane) {
    NSArray<NSNumber *> *baseLut = KKGradientFlatLUTFromStops(
        KKGradientStopsFromFlat(active.values) ?: @[], KK_GRADIENT_LUT_SIZE);
    if (active.holdEffect == KKHoldEffectNone)
      return baseLut;
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
    double factor = KKApplyHoldEffect(t, active.holdEffect, active.intensity,
                                      active.frequency, (int)active.seed);
    for (NSNumber *v in active.values)
      [modulated addObject:@(v.doubleValue * factor)];
  } else {
    for (NSUInteger i = 0; i < active.values.count; i++) {
      double factor = KKApplyHoldEffectForComponent(
          t, active.holdEffect, active.intensity, active.frequency,
          (int)active.seed, (int)i);
      [modulated addObject:@(active.values[i].doubleValue * factor)];
    }
  }
  return modulated;
}

static NSArray<NSNumber *> *
KKEvaluateTransition(NSArray<KKTimingSegment *> *segments, NSUInteger idx,
                     double frac, BOOL gradientLane,
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
      NSNumber *own = (i < active.values.count) ? active.values[i] : @(fv);
      [interpolated addObject:own];
    } else {
      [interpolated addObject:@(fv + (tv - fv) * easedT)];
    }
  }
  return interpolated;
}

NSArray<NSNumber *> *KKTimingLaneValueAtFraction(KKTimingLane *lane,
                                                 double frac) {
  NSArray<KKTimingSegment *> *segments = lane.segments;
  if (!segments.count)
    return nil;
  KKTimingSegment *active = KKTimingSegmentForFraction(segments, frac);
  if (!active)
    return nil;
  BOOL gradientLane = KKLaneIsGradient(lane);
  if (active.type == KKSegmentTypeHold)
    return KKEvaluateHold(active, frac, gradientLane);
  NSUInteger idx = [segments indexOfObjectIdenticalTo:active];
  NSArray<NSNumber *> *componentKinds =
      KKExpandComponentKinds(lane.valueComponentKinds);
  return KKEvaluateTransition(segments, idx, frac, gradientLane,
                              componentKinds);
}
