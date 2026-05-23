/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKTimelineBasicView_Private.h"

#import "../Math/KKTimelineScale.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKCheckboxView.h"
#import "KKKeyposeSymbol.h"
#import "KKTimelineZoomPan.h"
#import <CoreGraphics/CGEventSource.h>
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKTimingEvaluation.h>

// Constants, typedefs, projection struct, ivars and private method decls
// shared across all categories live in KKTimelineBasicView_Private.h. Pure
// C helpers (KKShapeOfLane, KKBasicMotionY*, projection geometry, …) are
// defined here in the core .m and exported there so the categories can use
// them.

@implementation KKTimelineBasicView

- (instancetype)initWithAvailableLanes:(NSArray<KKLane *> *)availableLanes
                              timeline:(KKTimeline *)timeline {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _availableLanes = [availableLanes copy];
    _timeline = timeline;
    _hoverSection = KKBasicSectionNone;
    _playheadFraction = -1.0; // hidden until the render tick pushes a value
    _snappedScrubFrac = NAN;
    _zp = [[KKTimelineZoomPan alloc] init];
    [self _buildUI];
  }
  return self;
}

- (void)_buildUI {
  _inLabel =
      [self _makeSectionLabel:KKLoc(@"In", @"Timeline phase: In (ease-in).")];
  _holdLabel = [self
      _makeSectionLabel:KKLoc(@"Hold", @"Timeline phase / hold effect name.")];
  _outLabel = [self
      _makeSectionLabel:KKLoc(@"Out", @"Timeline phase: Out (ease-out).")];

  _inCheck = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
  _outCheck = [[KKCheckboxView alloc] initWithFrame:NSZeroRect];
  for (KKCheckboxView *c in @[ _inCheck, _outCheck ])
    [self addSubview:c];

  __weak typeof(self) weak = self;
  _inCheck.onToggle = ^(BOOL on) {
    __strong typeof(self) s = weak;
    [s _setInEnabled:on];
    if (s && s->_onPhaseToggled)
      s->_onPhaseToggled(0, on);
  };
  _outCheck.onToggle = ^(BOOL on) {
    __strong typeof(self) s = weak;
    [s _setOutEnabled:on];
    if (s && s->_onPhaseToggled)
      s->_onPhaseToggled(1, on);
  };
}

- (NSTextField *)_makeSectionLabel:(NSString *)text {
  NSTextField *l = [NSTextField labelWithString:text];
  l.font = [NSFont systemFontOfSize:KKFontSizeSM weight:NSFontWeightMedium];
  l.textColor = [NSColor inspectorLabel];
  [self addSubview:l];
  return l;
}

- (void)resetZoom {
  if (![_zp reset])
    return;
  [self setNeedsDisplay:YES];
  [self _notifyZoomChanged];
}

- (void)applyTimeline:(KKTimeline *)timeline {
  _timeline = timeline;
  [self _restoreCheckboxes];
  self.needsLayout = YES;
  [self layoutSubtreeIfNeeded]; // flush now so the Hold/Drift label
                                // refreshes in lockstep with the curve
  [self setNeedsDisplay:YES];
}

- (void)_restoreCheckboxes {
  KKBasicProj p = [self _projection];
  _inCheck.isChecked = p.inEnabled;
  _outCheck.isChecked = p.outEnabled;
}

- (void)setClipDurationSeconds:(double)seconds {
  if (fabs(seconds - _clipDurationSeconds) < 1.0e-4)
    return;
  _clipDurationSeconds = seconds;
  [self setNeedsDisplay:YES];
}

- (void)setFrameDurationSeconds:(double)seconds {
  if (fabs(seconds - _frameDurationSeconds) < 1.0e-5)
    return;
  _frameDurationSeconds = seconds;
  [self setNeedsDisplay:YES];
}

- (void)setPlayheadFraction:(double)frac {
  // While scrubbing, the view owns the playhead optimistically - ignore the
  // render round-trip so it doesn't fight the drag (the "double" jitter).
  if (_scrubbing)
    return;
  // Hidden sentinel is anything outside [0,1]; clamp real values so a tiny
  // overshoot at the clip edge still pins to the end.
  double v = (frac < 0.0 || frac > 1.0) ? -1.0 : frac;
  if (fabs(v - _playheadFraction) < 1.0e-4 &&
      (v >= 0.0) == (_playheadFraction >= 0.0))
    return;
  _playheadFraction = v;
  [self setNeedsDisplay:YES];
}

// The canonical Basic shape of a lane. The two Hold keyposes are ALWAYS
// present (so drift / modulation are always possible); an In adds a keypose
// at t≈0, an Out at t≈1. Keypose counts: neither 2, In 3, Out 3, both 4.
// New model: the hold endpoints sit at t=0 and t=outEndFrac (~1) when In/Out
// are off; In adds a t=0 In-start (hold-start shifts to t_inEnd); Out adds a
// t=outEndFrac Out-end (hold-end shifts to t_outStart).
//   n==2: [hold@0, hold@outEndFrac]                     - no In, no Out
//   n==3: [in@0, hold@t_inEnd, hold@outEndFrac]         - In only  (mid<0.5)
//   n==3: [hold@0, hold@t_outStart, out@outEndFrac]     - Out only (mid≥0.5)
//   n==4: [in@0, hold@t_inEnd, hold@t_outStart, out@outEndFrac]
KKHoldShape KKShapeOfLane(KKLane *lane) {
  KKHoldShape s = {NO, NO, 0, 0};
  NSArray<KKKeyPose *> *k = lane.keyposes;
  if (k.count < 2)
    return s;
  // Explicit holdShape overrides the count/time heuristic. Set every time
  // Basic rebuilds, so once a lane has been touched the projection is no
  // longer guessing - dragging the boundary past 0.5 stays In (or Out).
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
    // Legacy blobs without the annotation: infer from KP count + middle
    // time. Breaks for boundary > 0.5 in single-phase but that's exactly
    // what the explicit field is for; legacy data hasn't been through a
    // rebuild yet.
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

- (double)_clipDuration {
  if (_clipDurationSeconds > 0.0)
    return _clipDurationSeconds;
  double dur = 0.0;
  for (KKLane *lane in _timeline.lanes)
    dur = MAX(dur, lane.lastKnownClipDuration);
  return dur;
}

- (KKBasicProj)_projection {
  KKBasicProj p = {0};
  p.inEndFrac = kDefaultInEnd;
  p.outStartFrac = kDefaultOutStart;
  p.inCurve = KKEasingCurveEaseInOut;
  p.outCurve = KKEasingCurveEaseInOut;
  p.inIntensity = 1.0;
  p.outIntensity = 1.0;
  p.inFrequency = 0.5;
  p.outFrequency = 0.5;
  p.holdCurve = KKEasingCurveLinear; // drift defaults to linear
  p.holdIntensity = 1.0;
  p.holdFrequency = 0.5;
  p.holdDrift = NO;
  p.holdMod = KKIntervalModulationNone;
  p.holdModIntensity = 1.0;
  p.holdModFrequency = 1.0;
  p.holdModSeed = 0;
  BOOL holdFound = NO;

  for (KKLane *lane in _timeline.lanes) {
    if (!lane.enabled || lane.keyposes.count < 2)
      continue;
    p.anyAnimatable = YES;
    KKHoldShape s = KKShapeOfLane(lane);
    if (!holdFound) {
      holdFound = YES;
      // Tentative boundary times + the shared Hold curve/mod params from the
      // first animatable lane. The In/Out blocks below OVERRIDE inEndFrac /
      // outStartFrac from a lane that actually participates in that phase -
      // a Hold-only lane parks its hold-start at t=0 (no In) / hold-end at the
      // clip edge (no Out), so reading boundaries off the first lane collapses
      // the In/Out region when that lane isn't an In/Out participant.
      p.inEndFrac = lane.keyposes[s.holdStart].time;
      p.outStartFrac = lane.keyposes[s.holdEnd].time;
      KKInterval *hv = lane.keyposes[s.holdStart].outgoing;
      if (hv) {
        p.holdCurve = (KKEasingCurve)hv.curve;
        p.holdIntensity = hv.intensity;
        p.holdFrequency = hv.frequency;
        p.holdMod = hv.modulation;
        p.holdModIntensity = hv.modulationIntensity;
        p.holdModFrequency = hv.modulationFrequency;
        p.holdModSeed = hv.modulationSeed;
      }
    }
    // Drift is OR-style across animated lanes: any lane with differing Hold
    // endpoint values means the graph should show a drift slope. Without
    // this, adding a new (initially-flat) animatable lane would mask an
    // existing drifted lane and visually flatten the curve.
    if (!p.holdDrift && s.holdEnd > s.holdStart &&
        !KKValuesEqual(lane.keyposes[s.holdStart].values,
                       lane.keyposes[s.holdEnd].values))
      p.holdDrift = YES;
    // In/Out is "on" when at least one property still APPLIES (its phase
    // interval isn't flat). A property toggled off via applies-to keeps its
    // keypose but goes flat, so removing the last applier turns the phase off
    // even though the keyposes remain.
    KKInterval *iiv = lane.keyposes.firstObject.outgoing;
    if (!p.inEnabled && s.inEnabled && !iiv.holdsFlat) {
      p.inEnabled = YES;
      // Authoritative In→Hold boundary from an applying lane.
      p.inEndFrac = lane.keyposes[s.holdStart].time;
      if (iiv) {
        p.inCurve = (KKEasingCurve)iiv.curve;
        p.inIntensity = iiv.intensity;
        p.inFrequency = iiv.frequency;
      }
    }
    KKInterval *oiv = lane.keyposes[s.holdEnd].outgoing;
    if (!p.outEnabled && s.outEnabled && !oiv.holdsFlat) {
      p.outEnabled = YES;
      // Authoritative Hold→Out boundary from an applying lane.
      p.outStartFrac = lane.keyposes[s.holdEnd].time;
      if (oiv) {
        p.outCurve = (KKEasingCurve)oiv.curve;
        p.outIntensity = oiv.intensity;
        p.outFrequency = oiv.frequency;
      }
    }
  }
  if (!p.anyAnimatable)
    for (KKLane *lane in _timeline.lanes)
      if (lane.enabled) {
        p.anyAnimatable = YES;
        break;
      }
  if (p.inEndFrac >= p.outStartFrac) {
    p.inEndFrac = kDefaultInEnd;
    p.outStartFrac = kDefaultOutStart;
  }
  // Projection-only: a disabled In/Out has no transition, so its Hold
  // boundary is drawn at the clip edge (the value is held from the very
  // start / to the very end). The stored keypose time is left untouched -
  // re-enabling the phase restores its boundary, and keypose-presence
  // inference stays valid (we never move keyposes to 0/1 in the model).
  // Keep outStartFrac at 1.0 (not 1-frameFrac) so the log-warped edge
  // remap doesn't see a thin "Out region" and inflate it to its floor
  // width, which would push the Hold-end diamond visually inward.
  // Scrubber-max + OSC-snap handle the playhead's last-frame quantization
  // separately; the diamond stays parked at the visual right edge.
  if (!p.inEnabled)
    p.inEndFrac = 0.0;
  if (!p.outEnabled)
    p.outStartFrac = 1.0;
  p.clipDur = [self _clipDuration];
  p.zoom = _zp.zoom > 0.0 ? _zp.zoom : 1.0;
  p.panOffset = _zp.panOffset;
  // Value-based: a phase only draws its easing ramp when its endpoints
  // actually differ. A freshly enabled In/Out seeds its endpoint to the hold
  // value, so the schematic stays flat until the user gives it a distinct
  // value (matching the accent colour rule).
  p.inIsTransition = [self _inIsTransition];
  p.outIsTransition = [self _outIsTransition];
  return p;
}

// Modulation enum → hold-effect shape, same mapping the evaluator uses
// (KKTimingEvaluation.m): Wiggle→Wiggle, Oscillate→Bounce.
KKHoldEffect KKBasicHoldEffect(KKIntervalModulation m) {
  if (m == KKIntervalModulationWiggle)
    return KKHoldEffectWiggle;
  if (m == KKIntervalModulationHandheld)
    return KKHoldEffectHandheld;
  return KKHoldEffectBounce;
}

// The Hold region's normalized value: the flat held level (1) or the drift
// slope (1→2), times the modulation envelope when one is set - exactly the
// evaluator's "eased value × hold-effect factor". The envelope zeroes at the
// region ends so it joins In/Out continuously.
double KKBasicHoldValue(double t, KKBasicProj p, double holdEnd) {
  double span = p.outStartFrac - p.inEndFrac;
  double base = 1.0;
  if (span > kEps) {
    double q = (t - p.inEndFrac) / span;
    if (p.holdDrift)
      base = 1.0 +
             KKApplyEasing(q, p.holdCurve, p.holdIntensity, p.holdFrequency) *
                 (holdEnd - 1.0);
    if (p.holdMod != KKIntervalModulationNone)
      base *=
          KKApplyHoldEffect(q, KKBasicHoldEffect(p.holdMod), p.holdModIntensity,
                            p.holdModFrequency, (int)p.holdModSeed);
  }
  return base;
}

// Normalized motion value (0 = settled-out, 1 = held) at clip fraction t.
// In rises 0→1 (its easing), Hold is flat at 1, Out falls 1→0 (its easing).
// A phase that is off stays flat at the hold level (no transition). When the
// Hold is a drift the held plateau becomes a slope 1→2 along the Hold curve
// (so movement is unmistakable), and Out then falls 2→0. A modulated Hold
// wobbles around the held level.
double KKBasicMotionY(double t, KKBasicProj p) {
  double holdEnd = p.holdDrift ? 2.0 : 1.0;
  if (t <= p.inEndFrac) {
    if (p.inEnabled && p.inIsTransition && p.inEndFrac > kEps)
      return KKApplyEasing(t / p.inEndFrac, p.inCurve, p.inIntensity,
                           p.inFrequency);
    return 1.0;
  }
  if (t < p.outStartFrac)
    return KKBasicHoldValue(t, p, holdEnd);
  if (p.outEnabled && p.outIsTransition && p.outStartFrac < 1.0 - kEps) {
    double q = (t - p.outStartFrac) / (1.0 - p.outStartFrac);
    return holdEnd -
           KKApplyEasing(q, p.outCurve, p.outIntensity, p.outFrequency) *
               holdEnd;
  }
  return holdEnd;
}

// The drawn curve: `KKBasicMotionY` with the same C1 join smoothing the
// render evaluator applies (`KKTimelineLaneValueAtFractionSmoothed`), so the
// graph shows exactly what plays - transitions glide into/out of the Hold
// with no detectable stop. Only an *enabled* In/Out is a real join (a
// disabled phase is already a flat continuation). Diamonds/handles keep the
// raw value so they stay pinned to the true keypose.
double KKBasicMotionYSmoothed(double t, KKBasicProj p) {
  double (^raw)(double) = ^double(double f) {
    return KKBasicMotionY(f, p);
  };
  if (p.inEnabled && p.inIsTransition && p.inEndFrac > kEps) {
    double prev = p.inEndFrac;
    double next = p.outStartFrac - p.inEndFrac;
    if (next > 0.0) {
      double w = KK_JOIN_BLEND_FRAC * MIN(prev, next);
      w = MIN(MIN(w, 0.49 * prev), 0.49 * next);
      if (t > p.inEndFrac - w && t < p.inEndFrac + w)
        return KKHermiteJoinBlend(t, p.inEndFrac, w, raw);
    }
  }
  if (p.outEnabled && p.outIsTransition && p.outStartFrac < 1.0 - kEps) {
    double prev = p.outStartFrac - p.inEndFrac;
    double next = 1.0 - p.outStartFrac;
    if (prev > 0.0) {
      double w = KK_JOIN_BLEND_FRAC * MIN(prev, next);
      w = MIN(MIN(w, 0.49 * prev), 0.49 * next);
      if (t > p.outStartFrac - w && t < p.outStartFrac + w)
        return KKHermiteJoinBlend(t, p.outStartFrac, w, raw);
    }
  }
  return KKBasicMotionY(t, p);
}

- (NSRect)_graphRect {
  CGFloat bottom = kLabelStripH + kGraphBottomGap;
  CGFloat top = kRulerH + kRulerGap + kGraphPadTop;
  return NSMakeRect(kGraphPadX, bottom, NSWidth(self.bounds) - 2 * kGraphPadX,
                    NSHeight(self.bounds) - bottom - top);
}

// Maps (frac, value) into the track. `lo`/`hi` is the curve's actual value
// extent (elastic/bounce overshoot [0,1]); the curve is scaled to fit it so
// it never spills into the ruler. A point-based inset keeps the diamond
// glyphs (radius kDiamondR) off the track edges too.
// Display widths (u-fractions, summing to 1) of the In / Hold / Out sections,
// each ∝ its shared log-weight. Same formula will drive Advanced's N
// intervals.
void KKBasicDisplayWidths(KKBasicProj p, double *outIn, double *outHold,
                          double *outOut) {
  double tIn = p.inEndFrac, tOut = p.outStartFrac;
  double gIn = KKTimelineScaleLogWeight(tIn, p.clipDur);
  double gHold = KKTimelineScaleLogWeight(tOut - tIn, p.clipDur);
  double gOut = KKTimelineScaleLogWeight(1.0 - tOut, p.clipDur);
  double sum = gIn + gHold + gOut;
  if (sum < 1.0e-9) {
    *outIn = 0.0;
    *outHold = 1.0;
    *outOut = 0.0;
    return;
  }
  *outIn = gIn / sum;
  *outHold = gHold / sum;
  *outOut = gOut / sum;
}

// True clip fraction (0–1) → warped position fraction across the graph.
double KKBasicFracToU(double frac, KKBasicProj p) {
  double dIn, dHold, dOut;
  KKBasicDisplayWidths(p, &dIn, &dHold, &dOut);
  double tIn = p.inEndFrac, tOut = p.outStartFrac;
  double u;
  if (frac <= tIn)
    u = (tIn > 1.0e-9) ? (frac / tIn) * dIn : 0.0;
  else if (frac <= tOut)
    u = dIn + (frac - tIn) / MAX(1.0e-9, tOut - tIn) * dHold;
  else
    u = dIn + dHold + (frac - tOut) / MAX(1.0e-9, 1.0 - tOut) * dOut;
  return MAX(0.0, MIN(1.0, u));
}

// Inverse of KKBasicFracToU.
double KKBasicUToFrac(double u, KKBasicProj p) {
  double dIn, dHold, dOut;
  KKBasicDisplayWidths(p, &dIn, &dHold, &dOut);
  double tIn = p.inEndFrac, tOut = p.outStartFrac;
  u = MAX(0.0, MIN(1.0, u));
  if (u <= dIn)
    return (dIn > 1.0e-9) ? (u / dIn) * tIn : 0.0;
  if (u <= dIn + dHold)
    return tIn + (u - dIn) / MAX(1.0e-9, dHold) * (tOut - tIn);
  return tOut + (u - dIn - dHold) / MAX(1.0e-9, dOut) * (1.0 - tOut);
}

// Display u of a dragged boundary (d==2: In|Hold, d==3: Hold|Out) if it sat
// at fraction v - recomputing the warp for that v. Strictly increasing in v.
double KKBasicBoundaryU(KKBasicProj p, NSInteger d, double v) {
  KKBasicProj t = p;
  if (d == 2)
    t.inEndFrac = v;
  else
    t.outStartFrac = v;
  double dIn, dHold, dOut;
  KKBasicDisplayWidths(t, &dIn, &dHold, &dOut);
  return (d == 2) ? dIn : (dIn + dHold);
}

// Solve for the boundary fraction whose *warped* screen position equals
// targetU, accounting for the warp depending on that very fraction. A
// per-frame bisection - exact and feedback-free, so the handle tracks the
// cursor under the live log scale with no oscillation.
double KKBasicSolveBoundary(KKBasicProj p, NSInteger d, double targetU,
                            double lo, double hi) {
  if (hi <= lo)
    return lo;
  if (targetU <= KKBasicBoundaryU(p, d, lo))
    return lo;
  if (targetU >= KKBasicBoundaryU(p, d, hi))
    return hi;
  for (int i = 0; i < 48; i++) {
    double mid = 0.5 * (lo + hi);
    if (KKBasicBoundaryU(p, d, mid) < targetU)
      lo = mid;
    else
      hi = mid;
  }
  return 0.5 * (lo + hi);
}

// Basic's 3-section frac→u remap, then the shared zoom/pan transform.
CGFloat KKBasicXForFrac(double frac, NSRect g, KKBasicProj p) {
  return KKTimelineScaleUToX(KKBasicFracToU(frac, p), g, p.zoom, p.panOffset);
}

// Inverse: shared screen x → u, then Basic's 3-section u→frac remap.
double KKBasicFracForX(CGFloat x, NSRect g, KKBasicProj p) {
  return KKBasicUToFrac(KKTimelineScaleXToU(x, g, p.zoom, p.panOffset), p);
}

NSPoint KKBasicPoint(NSRect g, double frac, double val, double lo, double hi,
                     KKBasicProj p) {
  CGFloat pad = kDiamondR + 2.0;
  CGFloat usableH = MAX(1.0, NSHeight(g) - 2.0 * pad);
  double span = (hi - lo > 1.0e-6) ? (hi - lo) : 1.0;
  double norm = (val - lo) / span;
  return NSMakePoint(KKBasicXForFrac(frac, g, p),
                     NSMinY(g) + pad + norm * usableH);
}

// Curve value extent, always including the [0,1] base range, plus 6% slack.
// Sample each phase's easing in its OWN normalized parameter (not global t),
// so the extent depends only on the curve type/intensity - never on the
// In/Out durations. Otherwise a short segment gets too few global samples to
// catch an overshoot peak, and the detected max flickers as you drag the
// boundary (the curve appears to rise and fall though the peak is fixed).
void KKBasicValueExtent(KKBasicProj p, double *outLo, double *outHi) {
  double mn = 0.0, mx = 1.0; // always include the [0,1] base range
  const NSInteger n = 128;
  if (p.inEnabled)
    for (NSInteger i = 0; i <= n; i++) {
      double v =
          KKApplyEasing((double)i / n, p.inCurve, p.inIntensity, p.inFrequency);
      mn = MIN(mn, v);
      mx = MAX(mx, v);
    }
  // A drift slope (1→2) and/or a modulation wobble lift the Hold off its
  // flat level; Out then falls from wherever Hold ended. Sample the actual
  // Hold value so the whole curve still scales to fit the track.
  double holdEnd = p.holdDrift ? 2.0 : 1.0;
  double holdSpan = p.outStartFrac - p.inEndFrac;
  if ((p.holdDrift || p.holdMod != KKIntervalModulationNone) && holdSpan > kEps)
    for (NSInteger i = 0; i <= n; i++) {
      double v =
          KKBasicHoldValue(p.inEndFrac + (double)i / n * holdSpan, p, holdEnd);
      mn = MIN(mn, v);
      mx = MAX(mx, v);
    }
  if (p.outEnabled)
    for (NSInteger i = 0; i <= n; i++) {
      double v = holdEnd - KKApplyEasing((double)i / n, p.outCurve,
                                         p.outIntensity, p.outFrequency) *
                               holdEnd;
      mn = MIN(mn, v);
      mx = MAX(mx, v);
    }
  double slack = MAX(mx - mn, 1.0e-6) * 0.06;
  *outLo = mn - slack;
  *outHi = mx + slack;
}

- (void)layout {
  [super layout];
  KKBasicProj p = [self _projection];
  NSRect g = [self _graphRect];
  CGFloat midY = kLabelStripH / 2.0;

  CGFloat W = NSWidth(g);
  // Fixed anchors (left / centre / right thirds). Tracking the variable
  // section centres made the labels jump when enabling/disabling In/Out
  // snapped the projection fractions - not worth matching section width.
  [self _placeSection:_inLabel
             checkbox:_inCheck
              centerX:NSMinX(g) + 0.16 * W
                 midY:midY
              enabled:p.inEnabled];
  [self _placeSection:_outLabel
             checkbox:_outCheck
              centerX:NSMinX(g) + 0.84 * W
                 midY:midY
              enabled:p.outEnabled];

  // Label tells the truth from the values: equal endpoints = "Hold",
  // differing = "Drift" (warn-tinted), regardless of the link toggle.
  BOOL drift = [self _holdDrift];
  _holdLabel.stringValue =
      drift ? KKLoc(@"Drift", @"Hold effect: endpoints differ (drift).")
            : KKLoc(@"Hold", @"Timeline phase / hold effect name.");
  _holdLabel.textColor = drift ? [NSColor warning] : [NSColor inspectorLabel];
  [_holdLabel sizeToFit];
  CGFloat hx = NSMinX(g) + 0.5 * W;
  NSSize hs = _holdLabel.frame.size;
  _holdLabel.frame =
      NSMakeRect(round(hx - hs.width / 2.0), round(midY - hs.height / 2.0),
                 hs.width, hs.height);
  _holdLabel.alphaValue = 0.7;
}

- (void)_placeSection:(NSTextField *)label
             checkbox:(KKCheckboxView *)check
              centerX:(CGFloat)cx
                 midY:(CGFloat)midY
              enabled:(BOOL)enabled {
  [label sizeToFit];
  NSSize ls = label.frame.size;
  CGFloat box = check.intrinsicContentSize.width;
  CGFloat gap = KKSpacingSM;
  CGFloat total = box + gap + ls.width;
  CGFloat x = round(cx - total / 2.0);
  check.frame = NSMakeRect(x, round(midY - box / 2.0), box, box);
  label.frame = NSMakeRect(round(x + box + gap), round(midY - ls.height / 2.0),
                           ls.width, ls.height);
  label.alphaValue = enabled ? 0.85 : 0.4;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_trackingArea)
    [self removeTrackingArea:_trackingArea];
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:NSZeroRect
           options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                   NSTrackingActiveInActiveApp | NSTrackingInVisibleRect
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

@end
