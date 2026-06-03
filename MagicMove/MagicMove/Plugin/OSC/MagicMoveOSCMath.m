/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MagicMoveOSCMath.h"
#import <KeyframelessKit/KeyframelessKit.h>
#import <simd/simd.h>

KKLane *_laneNamed(NSString *label) {
  for (KKLane *lane in KKProcessTimelineSnapshot().lanes)
    if ([lane.label isEqualToString:label])
      return lane;
  return nil;
}

KKLane *_positionLane(void) { return _laneNamed(@"Position"); }
KKLane *_rotationLane(void) { return _laneNamed(@"Rotation"); }
KKLane *_scaleLane(void) { return _laneNamed(@"Scale"); }
KKLane *_anchorLane(void) { return _laneNamed(@"Anchor"); }

BOOL _positionVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_positionLane(), frac,
                                 KKProcessFrameDurationSeconds());
}
BOOL _rotationVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_rotationLane(), frac,
                                 KKProcessFrameDurationSeconds());
}
BOOL _scaleVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_scaleLane(), frac,
                                 KKProcessFrameDurationSeconds());
}
BOOL _anchorVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_anchorLane(), frac,
                                 KKProcessFrameDurationSeconds());
}

// (anchorX, anchorY) in normalized object space (0.5,0.5 = clip center),
// defaulting to centre when the lane is absent.
NSArray<NSNumber *> *_anchorValuesAtFraction(double frac) {
  KKLane *lane = _anchorLane();
  // No lane, or a lane present in the cold-boot snapshot with no keyposes yet
  // (untouched Anchor on a fresh instance): default to centre. Without the
  // keypose-count guard the evaluator returns [0,0] for an empty lane, which
  // drew the pivot square at the left edge even though the inspector lane shows
  // the real 0.5,0.5 default.
  if (!lane || lane.keyposes.count == 0)
    return @[ @0.5, @0.5 ];
  NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, frac);
  return v.count >= 2 ? v : @[ @0.5, @0.5 ];
}

NSArray<NSNumber *> *_positionValuesAtFraction(double frac) {
  KKLane *lane = _positionLane();
  if (!lane)
    return @[ @0.5, @0.5 ];
  // Raw (un-rounded) value so the arc handle lands exactly on the keypose
  // anchors, which are drawn from raw kp.values. The Smoothed variant
  // corner-rounds at interior joins, which pulled the handle off the active
  // anchor (the mini-canvas already uses the raw value, hence stays aligned).
  NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, frac);
  return v.count >= 2 ? v : @[ @0.5, @0.5 ];
}

// (rotX, rotY, rotZ) in DEGREES (matches storage).
NSArray<NSNumber *> *_rotationValuesAtFraction(double frac) {
  KKLane *lane = _rotationLane();
  if (!lane)
    return @[ @0.0, @0.0, @0.0 ];
  NSArray<NSNumber *> *v =
      KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  if (v.count >= 3)
    return v;
  NSMutableArray *out = [NSMutableArray arrayWithArray:v];
  while (out.count < 3)
    [out addObject:@0.0];
  return out;
}

// (scaleX, scaleY) in PERCENT (100 = identity). Floored at 0 so overshoot
// easing never shows the box / readout a negative (flipped) scale.
NSArray<NSNumber *> *_scaleValuesAtFraction(double frac) {
  KKLane *lane = _scaleLane();
  if (!lane)
    return @[ @100.0, @100.0 ];
  NSArray<NSNumber *> *v =
      KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithArray:v ?: @[]];
  while (out.count < 2)
    [out addObject:@100.0];
  out[0] = @(fmax(0.0, out[0].doubleValue));
  out[1] = @(fmax(0.0, out[1].doubleValue));
  return out;
}

// Canvas positions of the 8 scale-box handles for a given centre + scale
// percents: out[0..3] corners (BL, BR, TR, TL), out[4..7] edge midpoints
// (bottom, right, top, left). Shared by draw + hit-test so they agree.
void MMScaleHandlePositions(CGPoint center, double sclX, double sclY, double e0,
                            double span, CGPoint out[8]) {
  double halfW = KKScaleGizmoExtentForPercent(sclX, e0, span);
  double halfH = KKScaleGizmoExtentForPercent(sclY, e0, span);
  double l = center.x - halfW, r = center.x + halfW;
  double b = center.y - halfH, t = center.y + halfH;
  out[0] = CGPointMake(l, b);
  out[1] = CGPointMake(r, b);
  out[2] = CGPointMake(r, t);
  out[3] = CGPointMake(l, t);
  out[4] = CGPointMake(center.x, b);
  out[5] = CGPointMake(r, center.y);
  out[6] = CGPointMake(center.x, t);
  out[7] = CGPointMake(l, center.y);
}
