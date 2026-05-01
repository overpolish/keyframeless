/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

#import <KeyframelessKit/KKTimingStage.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns the segment of `segments` covering the fraction `frac`, clamping
/// to the first segment when `frac < firstStart` and to the last when
/// `frac >= lastEnd`. Returns nil only when `segments` is empty.
FOUNDATION_EXPORT KKTimingSegment *_Nullable KKTimingSegmentForFraction(
    NSArray<KKTimingSegment *> *segments, double frac);

/// Evaluates `lane` at fraction `frac` (0–1 of clip duration) and returns
/// the per-component values appropriate for the lane's `valueComponentKinds`.
///
/// - **Float lanes** return a flat scalar array, one per component.
/// - **Color lanes** return `[R, G, B]`.
/// - **Point lanes** return `[X, Y]`.
/// - **Gradient lanes** return a flat LUT (`KK_GRADIENT_LUT_SIZE × [r,g,b]`)
///   computed from the active segment's stops, optionally modulated when
///   the segment carries a hold effect.
/// - **Bool components** are stepped — they use the active segment's own
///   value verbatim across transitions rather than easing-interpolated.
///
/// Returns nil when `lane.segments` is empty. Disabled lanes are still
/// evaluated by this function — call sites that want the kill-switch
/// behaviour should check `lane.enabled` themselves.
FOUNDATION_EXPORT NSArray<NSNumber *> *_Nullable KKTimingLaneValueAtFraction(
    KKTimingLane *lane, double frac);

NS_ASSUME_NONNULL_END
