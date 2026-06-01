/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimingEvaluation.h"

#import "../Plugin/KKColor.h"
#import "KKBezierPath.h"
#import "KKGradientSampling.h"
#import "KKSpatialCurve.h"

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

// Apply the modulation envelope's multiplicative factor `f` (≈ 1±intensity*
// envelope) to `v`. Plain multiplication is a no-op when `v==0`, which
// breaks oscillation on offset-style params (Crop X/Y centred at 0). For
// near-zero values we fall back to an additive form whose amplitude scales
// with the component's value range (componentMax-componentMin), so 0
// wiggles by a meaningful fraction of its range instead of staying put.
static double KKApplyModulationFactor(double v, double f,
                                      NSArray<NSNumber *> *cMin,
                                      NSArray<NSNumber *> *cMax, NSUInteger i) {
  static const double kZeroThreshold = 1.0e-6;
  if (fabs(v) >= kZeroThreshold)
    return v * f;
  double lo = (i < cMin.count) ? cMin[i].doubleValue : 0.0;
  double hi = (i < cMax.count) ? cMax[i].doubleValue : 1.0;
  double range = hi - lo;
  if (range <= 0.0)
    range = 1.0;
  // Quarter-range amplitude keeps the wiggle visible at typical intensity
  // values without overshooting the plot's headroom too aggressively.
  return v + (f - 1.0) * range * 0.25;
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

static NSArray<NSNumber *> *KKLaneRawValueAtFraction(KKLane *lane,
                                                     double frac) {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  if (!kps.count)
    return nil;
  if (kps.count == 1)
    return kps[0].values;
  // Endpoint clamps must respect a flat first/last interval: if In is disabled
  // (first interval holdsFlat) the lane sits at the Hold value even at t≤0, so
  // clamp to the Hold-side keypose, not the (preserved) In-start value. Same at
  // the tail for a disabled Out.
  if (frac <= kps.firstObject.time)
    return (kps.firstObject.outgoing.holdsFlat) ? kps[1].values
                                                : kps.firstObject.values;
  if (frac >= kps.lastObject.time)
    return (kps[kps.count - 2].outgoing.holdsFlat) ? kps[kps.count - 2].values
                                                   : kps.lastObject.values;

  KKKeyPose *a = kps.firstObject;
  KKKeyPose *b = kps[1];
  NSUInteger ia = 0;
  for (NSUInteger i = 0; i + 1 < kps.count; i++) {
    if (frac < kps[i + 1].time) {
      a = kps[i];
      b = kps[i + 1];
      ia = i;
      break;
    }
  }

  double span = b.time - a.time;
  double localT = (span > 0) ? (frac - a.time) / span : 1.0;
  localT = MAX(0.0, MIN(1.0, localT));

  KKInterval *iv = a.outgoing;
  // A flat interval contributes no motion: hold at the Hold-side value (the
  // end keypose for the first/In interval, the start keypose for the last/Out
  // interval). Both keyposes' values stay stored so re-enabling restores them.
  if (iv && iv.holdsFlat)
    return (a == kps.firstObject) ? b.values : a.values;
  double easedT = iv ? KKApplyEasing(localT, (KKEasingCurve)iv.curve,
                                     iv.intensity, iv.frequency)
                     : localT;

  NSUInteger valCount = MIN(a.values.count, b.values.count);
  NSMutableArray<NSNumber *> *result =
      [NSMutableArray arrayWithCapacity:valCount];
  for (NSUInteger i = 0; i < valCount; i++) {
    double av = a.values[i].doubleValue;
    double bv = b.values[i].doubleValue;
    [result addObject:@(av + (bv - av) * easedT)];
  }

  // Spatial curve: when either bordering keypose is marked smooth, bend the
  // first two components (the 2D Position point) along a cubic bezier instead
  // of the straight line. Other components keep their linear interpolation, and
  // lanes with no smooth keypose are untouched. easedT is the eased progress of
  // the *time* through the segment; we feed it through arc-length
  // reparameterisation so it maps to distance travelled, giving constant speed
  // through curves of any sharpness (the easing then shapes speed-over-distance
  // as intended, instead of being warped by the bezier parameterisation).
  if (valCount >= 2 && (a.spatialSmooth || b.spatialSmooth)) {
    // Arc-length remap is only defined on the curve's own [0,1] domain. When
    // the easing overshoots (spring/elastic/back can push easedT past [0,1]),
    // feed the raw parameter straight to the bezier so it extrapolates along
    // the endpoint tangent - the position overshoots past the keypose, matching
    // what the straight-line lanes already do via linear interpolation.
    double t = (easedT < 0.0 || easedT > 1.0)
                   ? easedT
                   : KKLaneSpatialArcParam(kps, ia, easedT);
    double cx = 0, cy = 0;
    KKLaneSpatialBezierXY(kps, ia, t, &cx, &cy);
    result[0] = @(cx);
    result[1] = @(cy);
  }

  if (iv && iv.modulation != KKIntervalModulationNone) {
    // Multiplicative factor centred on 1.0; envelope zeroes at localT 0/1
    // so it joins the keyposes continuously. Wiggle = high-freq hash,
    // Oscillate = regular sinusoid, Handheld = low-freq fBm.
    KKHoldEffect effect =
        (iv.modulation == KKIntervalModulationWiggle)     ? KKHoldEffectWiggle
        : (iv.modulation == KKIntervalModulationHandheld) ? KKHoldEffectHandheld
                                                          : KKHoldEffectBounce;
    NSIndexSet *mask = iv.modulationComponents; // nil = all components
    NSArray<NSNumber *> *cMin = lane.componentMin;
    NSArray<NSNumber *> *cMax = lane.componentMax;
    if (iv.modulationLinked) {
      double f =
          KKApplyHoldEffect(localT, effect, iv.modulationIntensity,
                            iv.modulationFrequency, (int)iv.modulationSeed);
      for (NSUInteger i = 0; i < result.count; i++) {
        if (mask && ![mask containsIndex:i])
          continue;
        result[i] =
            @(KKApplyModulationFactor(result[i].doubleValue, f, cMin, cMax, i));
      }
    } else {
      for (NSUInteger i = 0; i < result.count; i++) {
        if (mask && ![mask containsIndex:i])
          continue;
        double f = KKApplyHoldEffectForComponent(
            localT, effect, iv.modulationIntensity, iv.modulationFrequency,
            (int)iv.modulationSeed, (int)i);
        result[i] =
            @(KKApplyModulationFactor(result[i].doubleValue, f, cMin, cMax, i));
      }
    }
  }
  return result;
}

NSArray<NSNumber *> *KKTimelineLaneValueAtFraction(KKLane *lane, double frac) {
  return KKLaneRawValueAtFraction(lane, frac);
}

double KKHermiteJoinBlend(double frac, double boundary, double window,
                          double (^sample)(double f)) {
  if (window <= 0.0)
    return sample(frac);
  double lo = boundary - window;
  double hi = boundary + window;
  if (frac <= lo || frac >= hi)
    return sample(frac);
  double h = window * 0.05;
  if (h < 1.0e-5)
    h = 1.0e-5;
  // Two-half Hermite: both segments share the keypose value at the boundary
  // so the smoothed curve passes through it exactly (instead of the symmetric
  // midpoint, which was undershooting at the keypose). Central-difference
  // tangent at the boundary keeps the curve C1 across both halves.
  double pB = sample(boundary);
  double mB = (sample(boundary + h) - sample(boundary - h)) / (2.0 * h);
  double p0, p1, m0, m1, L, segLo;
  if (frac < boundary) {
    p0 = sample(lo);
    p1 = pB;
    m0 = (sample(lo + h) - sample(lo - h)) / (2.0 * h);
    m1 = mB;
    L = boundary - lo;
    segLo = lo;
  } else {
    p0 = pB;
    p1 = sample(hi);
    m0 = mB;
    m1 = (sample(hi + h) - sample(hi - h)) / (2.0 * h);
    L = hi - boundary;
    segLo = boundary;
  }
  double x = (frac - segLo) / L;
  double x2 = x * x, x3 = x2 * x;
  double h00 = 2.0 * x3 - 3.0 * x2 + 1.0;
  double h10 = x3 - 2.0 * x2 + x;
  double h01 = -2.0 * x3 + 3.0 * x2;
  double h11 = x3 - x2;
  return h00 * p0 + h10 * m0 * L + h01 * p1 + h11 * m1 * L;
}

NSArray<NSNumber *> *KKTimelineLaneValueAtFractionSmoothed(KKLane *lane,
                                                           double frac) {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  if (kps.count < 3)
    return KKLaneRawValueAtFraction(lane, frac); // no interior join to round
  if (frac <= kps.firstObject.time || frac >= kps.lastObject.time)
    return KKLaneRawValueAtFraction(lane, frac); // endpoints stay exact

  // Find the interior keypose whose join window contains `frac`. Windows are
  // a fraction of the smaller adjacent span and capped so neighbouring
  // windows can't overlap (and never reach a neighbour keypose).
  for (NSUInteger i = 1; i + 1 < kps.count; i++) {
    double b = kps[i].time;
    double prev = b - kps[i - 1].time;
    double next = kps[i + 1].time - b;
    if (prev <= 0.0 || next <= 0.0)
      continue;
    // A join touching hold-modulation gets a wider fillet (the wobble and the
    // ease-out both reach the keypose at zero velocity, so a narrow blend
    // leaves a visible stop).
    BOOL modJoin =
        (kps[i - 1].outgoing.modulation != KKIntervalModulationNone) ||
        (kps[i].outgoing.modulation != KKIntervalModulationNone);
    double blendFrac = modJoin ? KK_JOIN_BLEND_MOD_FRAC : KK_JOIN_BLEND_FRAC;
    double w = blendFrac * MIN(prev, next);
    w = MIN(w, 0.49 * prev);
    w = MIN(w, 0.49 * next);
    if (frac <= b - w || frac >= b + w)
      continue;

    NSArray<NSNumber *> *probe = KKLaneRawValueAtFraction(lane, b);
    NSUInteger nc = probe.count;
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:nc];
    for (NSUInteger c = 0; c < nc; c++) {
      double v = KKHermiteJoinBlend(frac, b, w, ^double(double f) {
        NSArray<NSNumber *> *vv = KKLaneRawValueAtFraction(lane, f);
        return c < vv.count ? vv[c].doubleValue : 0.0;
      });
      [out addObject:@(v)];
    }
    return out;
  }
  return KKLaneRawValueAtFraction(lane, frac);
}

// Inverse of the Basic-view _projection's visual In/Out remap. Stored kp
// times sit at tIn/tOut even when In/Out is off - the Basic graph draws the
// Hold-start at visual t=0 (In off) and Hold-end at visual t=1 (Out off).
// This function applies the same remap on the read side so the rendered
// output and OSC reads match the visual graph.
static double _kkVisualToDataFrac(KKLane *lane, double visualFrac) {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  NSInteger n = (NSInteger)kps.count;
  if (n < 2)
    return visualFrac;

  static const double kEps = 1e-4;
  // The remap exists for the Basic projection (KPs anchored at canonical
  // positions: first at 0, last at the last-frame). In Advanced the user
  // can drag KPs anywhere, in which case the stored time IS the visual
  // time - stretching the [first.time, last.time] range over [0, 1] would
  // mis-time the lane (e.g. firstKP @ 0.2 then visualFrac=0.1 maps into
  // the transition instead of clamping to firstKP's value).
  // Heuristic: skip remap when first/last KPs aren't anchored to the
  // Basic edges. Conservative - short clips at unknown frame durations
  // can put `lastFrameFrac` slightly inside 1; allow ~2% slack.
  if (kps.firstObject.time > 2.0 * kEps)
    return visualFrac;
  if (kps.lastObject.time < 0.98)
    return visualFrac;

  // Shape detection - match KKShapeOfLane (count-based, framerate-agnostic).
  BOOL inEn = NO, outEn = NO;
  if (n == 4) {
    inEn = YES;
    outEn = YES;
  } else if (n == 3) {
    if (kps.firstObject.time < kEps)
      inEn = YES;
    else
      outEn = YES;
  }
  NSInteger holdStart = inEn ? 1 : 0;
  NSInteger holdEnd = n - (outEn ? 2 : 1);
  if (holdEnd <= holdStart)
    return visualFrac;
  double tA = kps[holdStart].time;
  double tB = kps[holdEnd].time;
  // Visual extents of the Hold region. In on → starts at tA (after In
  // transition). Out on → ends at tB (before Out transition).
  double vL = inEn ? tA : 0.0;
  double vR = outEn ? tB : 1.0;

  if (visualFrac <= vL)
    return inEn ? visualFrac : tA;
  if (visualFrac >= vR)
    return outEn ? visualFrac : tB;
  double span = vR - vL;
  if (span <= kEps)
    return tA;
  double t = (visualFrac - vL) / span;
  return tA + t * (tB - tA);
}

NSArray<NSNumber *> *
KKTimelineLaneValueAtVisualFractionSmoothed(KKLane *lane, double visualFrac) {
  return KKTimelineLaneValueAtFractionSmoothed(
      lane, _kkVisualToDataFrac(lane, visualFrac));
}

BOOL KKLaneVisibleAtFraction(KKLane *lane, double frac, double frameDurSec) {
  // Constants (disabled / no kps) - always show. Callers that want a
  // different "constant" rule should branch before calling.
  if (!lane || !lane.enabled)
    return YES;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  if (kps.count == 0)
    return YES;

  // Count-based shape detection - must match KKShapeOfLane /
  // _kkVisualToDataFrac so visibility lines up with where the kp is
  // *drawn* (Basic-view projects Hold-start→0 when In off, Hold-end→1
  // when Out off; stored times stay at tIn/tOut).
  static const double kShapeEps = 1e-4;
  NSInteger n = (NSInteger)kps.count;
  BOOL inEnabled = NO, outEnabled = NO;
  if (n == 4) {
    inEnabled = YES;
    outEnabled = YES;
  } else if (n == 3) {
    if (kps.firstObject.time < kShapeEps)
      inEnabled = YES;
    else
      outEnabled = YES;
  }
  NSInteger holdStart = inEnabled ? 1 : 0;
  NSInteger holdEnd = n - (outEnabled ? 2 : 1);

  // Frame-aware snap tolerance - FCP's playhead is frame-quantized, so
  // the readback frac is up to one frame off the kp's stored time.
  double clipDur = lane.lastKnownClipDuration;
  double epsilon;
  if (clipDur > 0.0 && frameDurSec > 0.0)
    epsilon = frameDurSec / clipDur;
  else
    epsilon = 0.05;
  static const double kMinEps = 1e-4;
  if (epsilon < kMinEps)
    epsilon = kMinEps;

  // Last-frame fraction - matches the scrubber's visual max and where
  // FCP delivers the playhead when parked at the clip end. Used as the
  // Out-end position when Out is off so the projected kp aligns with
  // where the playhead can actually land.
  double lastFrameFrac = 1.0;
  if (clipDur > 0.0 && frameDurSec > 0.0 && frameDurSec < clipDur)
    lastFrameFrac = (clipDur - frameDurSec) / clipDur;

  for (NSInteger i = 0; i < n; i++) {
    double t = kps[i].time;
    if (i == holdStart && !inEnabled)
      t = 0.0;
    else if (i == holdEnd && !outEnabled)
      t = lastFrameFrac;
    if (fabs(t - frac) <= epsilon)
      return YES;
  }
  return NO;
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
