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

BOOL _positionVisibleAtFraction(double frac) {
  return KKLaneVisibleAtFraction(_positionLane(), frac,
                                 KKProcessFrameDurationSeconds());
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
