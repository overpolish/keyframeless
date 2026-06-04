/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

// Scale box handle indices: 0-3 corners (BL, BR, TR, TL), 4-7 edge midpoints
// (bottom, right, top, left). Corners drive both axes; bottom/top drive Y,
// right/left drive X.
static inline BOOL kScaleHandleIsCorner(NSInteger h) {
  return h >= 0 && h <= 3;
}
static inline BOOL kScaleHandleControlsX(NSInteger h) {
  return kScaleHandleIsCorner(h) || h == 5 || h == 7;
}
static inline BOOL kScaleHandleControlsY(NSInteger h) {
  return kScaleHandleIsCorner(h) || h == 4 || h == 6;
}

// Lane lookups + per-fraction evaluators against the process timeline snapshot.
// All MagicMove OSC files share these (defined in MagicMoveOSCMath.m).
KKLane *_Nullable _laneNamed(NSString *label);
KKLane *_Nullable _positionLane(void);
KKLane *_Nullable _rotationLane(void);
KKLane *_Nullable _scaleLane(void);
KKLane *_Nullable _anchorLane(void);

BOOL _positionVisibleAtFraction(double frac);
BOOL _rotationVisibleAtFraction(double frac);
BOOL _scaleVisibleAtFraction(double frac);
BOOL _anchorVisibleAtFraction(double frac);

NSArray<NSNumber *> *_anchorValuesAtFraction(double frac);
NSArray<NSNumber *> *_positionValuesAtFraction(double frac);
NSArray<NSNumber *> *_rotationValuesAtFraction(double frac);
NSArray<NSNumber *> *_scaleValuesAtFraction(double frac);

// Canvas positions of the 8 scale-box handles for a given centre + scale
// percents: out[0..3] corners (BL, BR, TR, TL), out[4..7] edge midpoints
// (bottom, right, top, left). Shared by draw + hit-test so they agree.
void MMScaleHandlePositions(CGPoint center, double sclX, double sclY, double e0,
                            double span, CGPoint out[_Nonnull 8]);

NS_ASSUME_NONNULL_END
