/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>

@class KKGradientStop;

NS_ASSUME_NONNULL_BEGIN

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

NS_ASSUME_NONNULL_END
