/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKScopedDefaults.h>

NS_ASSUME_NONNULL_BEGIN

/// The transition shape a freshly created interval starts at. `curve` is a
/// KKIntervalCurve (kept as NSInteger so this header stays independent of
/// KKTimeline.h, which the timeline model imports the other way round).
typedef struct {
  NSInteger curve;
  double intensity;
  double frequency;
} KKCurveDefault;

/// EaseInOut / 0.5 / 0.5 - the shape every interval used before the user could
/// save their own. Saved animations always carry explicit values, so this only
/// governs brand-new intervals and legacy blobs missing the fields.
FOUNDATION_EXPORT const KKCurveDefault KKCurveDefaultBuiltIn;

/// The modulate popover saves the same three numbers under its own key, with
/// `curve` holding a KKIntervalModulation instead of a KKIntervalCurve. Its
/// built-in is None / 0.5 / 0.5 - no modulation until the user saves one.
FOUNDATION_EXPORT const KKCurveDefault KKModulationDefaultBuiltIn;

/// Read / write / clear the stored default. A nil scope means the active one
/// (see KKScopedDefaults for how scopes and storage work). Reads fall back to
/// `KKCurveDefaultBuiltIn` when nothing is stored.
FOUNDATION_EXPORT KKCurveDefault
KKCurveDefaultsRead(NSString *_Nullable scope);
FOUNDATION_EXPORT BOOL KKCurveDefaultsHasCustom(NSString *_Nullable scope);
FOUNDATION_EXPORT void KKCurveDefaultsWrite(KKCurveDefault value,
                                            NSString *_Nullable scope);
FOUNDATION_EXPORT void KKCurveDefaultsClear(NSString *_Nullable scope);

/// The modulate popover's own default, stored beside the curve one under the
/// same scope. `curve` carries a KKIntervalModulation here.
FOUNDATION_EXPORT KKCurveDefault
KKModulationDefaultsRead(NSString *_Nullable scope);
FOUNDATION_EXPORT void KKModulationDefaultsWrite(KKCurveDefault value,
                                                 NSString *_Nullable scope);

/// The modulate popover's pills are indexed by KKHoldEffect (0 None, 1 Bounce,
/// 2 Wiggle); the model stores KKIntervalModulation, and the evaluator maps
/// Wiggle→Wiggle but Oscillate→Bounce - so the two are NOT interchangeable.
/// Both the popover and the stored default cross that boundary, hence the pair
/// living here rather than in either view.
FOUNDATION_EXPORT NSInteger KKModulationToPill(NSInteger modulation);
FOUNDATION_EXPORT NSInteger KKPillToModulation(NSInteger pill);

NS_ASSUME_NONNULL_END
