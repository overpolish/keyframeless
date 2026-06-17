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
KKLane *_anchorLane(void) { return _laneNamed(@"Anchor"); }

BOOL _positionVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_positionLane(), frac,
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
  // anchor (the mini-viewer already uses the raw value, hence stays aligned).
  NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, frac);
  return v.count >= 2 ? v : @[ @0.5, @0.5 ];
}
