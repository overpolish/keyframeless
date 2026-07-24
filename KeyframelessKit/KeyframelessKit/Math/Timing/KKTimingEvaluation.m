/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimingEvaluation.h"

#import "KKBezierPath.h"
#import "KKColor.h"
#import "KKEasing.h"
#import "KKGradientSampling.h"
#import "KKSpatialCurve.h"

const double KKRotateWithMotionWindowSeconds = 1.0 / 12.0;

double KKRotateWithMotionDeltaRadians(double vx) {
  return vx * 5.0 * (M_PI / 180.0);
}

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

  // Composite gradient lanes interpolate specially: type is held, angle lerps,
  // stops blend structurally - a per-component lerp of [type, angle, stops...]
  // would be nonsense (type 0<->1) and breaks on a stop-count change.
  if (lane.valueType == KKLaneValueTypeGradient &&
      lane.gradientShowsTypeAngle) {
    NSArray<NSNumber *> *g =
        KKGradientCompositeInterp(a.values, b.values, easedT);
    // The angle (component 1) is the one wiggle-able part of a gradient, and
    // only on a Linear gradient (type 1) - Radial ignores angle entirely.
    if (iv && iv.modulation != KKIntervalModulationNone && g.count >= 2 &&
        llround(g[0].doubleValue) == 1) {
      NSIndexSet *mask = iv.modulationComponents;
      if (!mask || [mask containsIndex:1]) {
        KKHoldEffect effect = (iv.modulation == KKIntervalModulationWiggle)
                                  ? KKHoldEffectWiggle
                              : (iv.modulation == KKIntervalModulationHandheld)
                                  ? KKHoldEffectHandheld
                                  : KKHoldEffectBounce;
        double f =
            KKApplyHoldEffect(localT, effect, iv.modulationIntensity,
                              iv.modulationFrequency, (int)iv.modulationSeed);
        // Angle wiggles ADDITIVELY (uniform +/-degrees), not multiplicatively,
        // so the swing is independent of the base angle and never runs away at
        // large angles. Quarter-range (90 deg of 360) matches the additive form
        // KKApplyModulationFactor uses for zero-centred params. Trig in the
        // shader is periodic, so an angle past 0/360 is fine - no wrap needed.
        NSMutableArray<NSNumber *> *m = [g mutableCopy];
        m[1] = @(g[1].doubleValue + (f - 1.0) * 360.0 * 0.25);
        return m;
      }
    }
    return g;
  }

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

// File-internal: the C1 join-smoothing stage of KKLaneDisplayValueAtFraction
// (no external callers - display paths always want the visual projection
// too, authoring paths always want the exact evaluator).
static NSArray<NSNumber *> *KKTimelineLaneValueAtFractionSmoothed(KKLane *lane,
                                                                  double frac) {
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  // Composite gradient values aren't a vector of independent scalars, so the C1
  // per-component join blend would corrupt them - use the raw (gradient-aware)
  // interpolation directly.
  if (lane.valueType == KKLaneValueTypeGradient && lane.gradientShowsTypeAngle)
    return KKLaneRawValueAtFraction(lane, frac);
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

NSArray<NSNumber *> *KKLaneDisplayValueAtFraction(KKLane *lane,
                                                  double visualFrac) {
  // No visual->data remap: stored keypose times ARE visual times since the
  // Basic rebuild anchors the hold pair at [0, lastFrameFrac] when a phase
  // is off. (The old _kkVisualToDataFrac remap was provably ~identity for
  // everything its own anchoring guard admitted, and skipped the legacy
  // tIn-anchored blobs it was written for - a vestige, deleted.)
  return KKTimelineLaneValueAtFractionSmoothed(lane, visualFrac);
}

// THE hold-shape resolver (see header). `lane.holdShape` is authoritative -
// stamped by every Basic rebuild so dragging a boundary past 0.5 can't flip
// the interpretation; the count/middle-time heuristic survives only for
// legacy Auto blobs that predate the annotation.
KKHoldShape KKShapeOfLane(KKLane *lane) {
  KKHoldShape s = {NO, NO, 0, 0};
  NSArray<KKKeyPose *> *k = lane.keyposes;
  if (k.count < 2)
    return s;
  switch (lane.holdShape) {
  case KKLaneHoldShapeNone:
    break;
  case KKLaneHoldShapeInOnly:
    s.inEnabled = YES;
    break;
  case KKLaneHoldShapeOutOnly:
    s.outEnabled = YES;
    break;
  case KKLaneHoldShapeBoth:
    s.inEnabled = YES;
    s.outEnabled = YES;
    break;
  case KKLaneHoldShapeAuto: {
    NSInteger n = (NSInteger)k.count;
    if (n == 4) {
      s.inEnabled = YES;
      s.outEnabled = YES;
    } else if (n == 3) {
      if (k[1].time < 0.5)
        s.inEnabled = YES;
      else
        s.outEnabled = YES;
    }
    break;
  }
  }
  s.holdStart = s.inEnabled ? 1 : 0;
  s.holdEnd = (NSInteger)k.count - (s.outEnabled ? 2 : 1);
  if (s.holdEnd < s.holdStart)
    s.holdEnd = s.holdStart;
  return s;
}

// Shared core for KKLaneVisibleAtFraction / KKLaneKeyedAtFraction. When
// `includeEdges` is YES the flat lead-in (before the first kp) and lead-out
// (after the last kp) also count as visible - the grabbable-across-the-hold
// behaviour the viewer handle wants. When NO, only a fraction sitting ON a
// keypose counts, so a lane parked in its lead-out doesn't read as "keyed
// here".
static BOOL _kkLaneAtFraction(KKLane *lane, double frac, double frameDurSec,
                              BOOL includeEdges) {
  // Constants (disabled / no kps) - always show. Callers that want a
  // different "constant" rule should branch before calling.
  if (!lane || !lane.enabled)
    return YES;
  NSArray<KKKeyPose *> *kps = lane.keyposes;
  if (kps.count == 0)
    return YES;

  // THE shared shape resolver (holdShape-authoritative) so visibility lines
  // up with where the Basic view draws the keypose - a private count guess
  // here could disagree with the graph the moment the heuristic mis-read a
  // shape (e.g. a modern OutOnly lane whose hold-start sits at 0).
  NSInteger n = (NSInteger)kps.count;
  KKHoldShape shape = KKShapeOfLane(lane);
  BOOL inEnabled = shape.inEnabled, outEnabled = shape.outEnabled;
  NSInteger holdStart = shape.holdStart;
  NSInteger holdEnd = shape.holdEnd;

  // Frame-aware snap tolerance: HALF a frame, so the kp reads "present" only on
  // its OWN frame, not the two neighbours. The playhead is frame-quantized and
  // keyposes are created at a quantized playhead, so on the kp's frame the diff
  // is ~0; the adjacent frames sit a full frame away and are correctly
  // excluded.
  double clipDur = lane.lastKnownClipDuration;
  double epsilon;
  if (clipDur > 0.0 && frameDurSec > 0.0)
    epsilon = 0.5 * frameDurSec / clipDur;
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
  // Lead-in / lead-out: the value holds flat BEFORE the first keypose and AFTER
  // the last one (drawn gray in the timeline), so keep the handle grabbable
  // across those flat edges - a drag there writes the nearest (i.e. first /
  // last) keypose. Uses the ACTUAL keypose times so an animation whose motion
  // starts/ends mid-clip stays editable across its holds, not only at the
  // projected timeline ends. The interior transition (between first and last)
  // stays hidden - only the on-keypose checks above light it up there.
  if (includeEdges && n >= 2 &&
      (frac <= kps.firstObject.time || frac >= kps.lastObject.time))
    return YES;
  return NO;
}

BOOL KKLaneVisibleAtFraction(KKLane *lane, double frac, double frameDurSec) {
  return _kkLaneAtFraction(lane, frac, frameDurSec, /*includeEdges=*/YES);
}

BOOL KKLaneKeyedAtFraction(KKLane *lane, double frac, double frameDurSec) {
  return _kkLaneAtFraction(lane, frac, frameDurSec, /*includeEdges=*/NO);
}
