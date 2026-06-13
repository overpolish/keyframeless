/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>

@class KKGradientStop;

NS_ASSUME_NONNULL_BEGIN

/// Default two-stop black→white gradient JSON. Used as the seed value when
/// a path first switches to gradient mode and as the fallback when stops are
/// missing or malformed at render time.
NSString *KKDefaultGradientJSON(void);

/// Parse persisted gradient JSON (array of {p, r, g, b, m}) into stops.
/// Returns nil when input is malformed or has fewer than 2 stops.
NSArray<KKGradientStop *> *_Nullable KKGradientStopsFromJSON(
    NSString *_Nullable json);

/// Serialize stops to the persisted JSON shape.
NSString *_Nullable KKGradientJSONFromStops(NSArray<KKGradientStop *> *stops);

/// Rasterize stops into `lut` of length `size` (simd_float3 RGB samples).
/// Uses each stop's midpoint to bias the interpolation between adjacent pairs.
void KKGradientSampleStopsToLUT(NSArray<KKGradientStop *> *stops,
                                simd_float3 *lut, int size);

/// Flatten stops to `[pos, r, g, b, mid]` per stop. Used as segment values
/// for the gradient animatable-property kind in the multi-stage sequencer.
NSArray<NSNumber *> *KKGradientFlatFromStops(NSArray<KKGradientStop *> *stops);

/// Inverse of `KKGradientFlatFromStops`. Returns nil when `flat.count` is
/// not a multiple of 5 or has fewer than 2 stops.
NSArray<KKGradientStop *> *_Nullable KKGradientStopsFromFlat(
    NSArray<NSNumber *> *flat);

/// Rasterizes stops to a LUT and returns the result as `[r0, g0, b0, r1, ...]`
/// of length `size * 3`. Use this to deliver gradient samples to a plugin
/// renderer as a flat `NSArray<NSNumber *>`.
NSArray<NSNumber *> *
KKGradientFlatLUTFromStops(NSArray<KKGradientStop *> *stops, int size);

/// Interpolate two flattened gradients at eased `t` and return a flat LUT
/// (`[r0, g0, b0, r1, ...]`, length `3 * size`). Falls back to LUT blending
/// when stop counts differ; otherwise preserves natural midpoint/position
/// animation by blending stops structurally.
NSArray<NSNumber *> *KKGradientInterpFlatLUT(NSArray<NSNumber *> *fromFlat,
                                             NSArray<NSNumber *> *toFlat,
                                             double t, int size);

/// Interpolate two COMPOSITE gradient values - `[type, angleDegrees, <flat
/// stops>]` - at `t`. `type` is held from `from` (discrete, never animated),
/// `angle` is lerped, and the stops are interpolated structurally when both
/// sides have the same stop count (else held from `from`). Returns a composite
/// value in the same layout.
NSArray<NSNumber *> *KKGradientCompositeInterp(NSArray<NSNumber *> *from,
                                               NSArray<NSNumber *> *to,
                                               double t);

/// A single 0..1 "signature" of a stop set - a weighted aggregate of every
/// stop's position, midpoint and colour so any edit moves it. Used to plot an
/// animated gradient as one graph line (alongside the angle line).
double KKGradientStopsSignature(NSArray<KKGradientStop *> *stops);

NS_ASSUME_NONNULL_END
