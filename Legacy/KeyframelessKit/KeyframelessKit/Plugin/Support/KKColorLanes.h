/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKColor.h>     // KK_GRADIENT_LUT_SIZE
#import <KeyframelessKit/KKConstants.h> // KKColorMode
#import <simd/simd.h>

@class KKLane;

NS_ASSUME_NONNULL_BEGIN

/// A resolved colour-group value, ready to feed a shader. `solidColor` is sRGB
/// 0..1 (valid for Solid); `gradientType` 0 = radial / 1 = linear,
/// `gradientAngle` in radians, `gradientLUT` sRGB samples (both valid for
/// Gradient). The plugin maps `mode` to its own shader enum.
typedef struct {
  KKColorMode mode;
  simd_float3 solidColor;
  int gradientType;
  float gradientAngle;
  simd_float3 gradientLUT[KK_GRADIENT_LUT_SIZE];
} KKColorLanesValue;

/// Lane labels a colour group uses. `baseName` nil ->
/// "Mode"/"Solid"/"Gradient"; otherwise prefixed (e.g. "Fill" -> "Fill Mode")
/// so a plugin can host several colour groups (fill, stroke, ...) in one
/// timeline.
FOUNDATION_EXPORT NSString *KKColorLanesModeLabel(NSString *_Nullable baseName);
FOUNDATION_EXPORT NSString *
KKColorLanesSolidLabel(NSString *_Nullable baseName);
FOUNDATION_EXPORT NSString *
KKColorLanesGradientLabel(NSString *_Nullable baseName);

/// Build the Mode/Solid/Gradient lanes for one colour property. The caller owns
/// grouping: set `categoryKey`/`categorySymbol` on the returned lanes (not all
/// plugins group the same). `includesDynamic` adds a Dynamic option (source-
/// coloured) as the default mode; otherwise the modes are Solid (default) +
/// Gradient. `animatable` applies to Solid + Gradient (Mode is never
/// animatable).
FOUNDATION_EXPORT NSArray<KKLane *> *
KKColorLanesMake(NSString *_Nullable baseName, BOOL includesDynamic,
                 BOOL animatable);

/// Resolve a colour group to a ready value. `valuesProvider` maps a lane label
/// to its current component values, so the same resolver serves the main render
/// (timeline evaluator) and the mini-viewer (per-fraction reads). Returns white
/// solid / white LUT for any missing lane.
FOUNDATION_EXPORT KKColorLanesValue KKColorLanesResolve(
    NSString *_Nullable baseName, BOOL includesDynamic,
    NSArray<NSNumber *> *_Nullable (^valuesProvider)(NSString *label));

NS_ASSUME_NONNULL_END
