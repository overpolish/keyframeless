/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

// Lane lookups + per-fraction evaluators against the process timeline snapshot.
// All MagicMove OSC files share these (defined in MagicMoveOSCMath.m). The
// Scale gizmo (sizing, handle positions, drag) lives in the kit's KKScaleOSC /
// KKScaleGizmo now, so the scale lookups moved there.
KKLane *_Nullable _laneNamed(NSString *label);
KKLane *_Nullable _positionLane(void);
KKLane *_Nullable _rotationLane(void);
KKLane *_Nullable _anchorLane(void);

BOOL _positionVisibleAtFraction(double frac);
BOOL _rotationVisibleAtFraction(double frac);
BOOL _anchorVisibleAtFraction(double frac);

NSArray<NSNumber *> *_anchorValuesAtFraction(double frac);
NSArray<NSNumber *> *_positionValuesAtFraction(double frac);
NSArray<NSNumber *> *_rotationValuesAtFraction(double frac);

NS_ASSUME_NONNULL_END
