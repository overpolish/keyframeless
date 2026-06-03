/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKConstants.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

#define KK_GRADIENT_LUT_SIZE 64

@interface KKColorResult : NSObject

@property(nonatomic, readonly) KKColorMode mode;
@property(nonatomic, readonly) simd_float3 solidColor;
/// Pre-sampled gradient LUT (RGB, KK_GRADIENT_LUT_SIZE entries). Only valid
/// when mode == KKColorModeGradient.
@property(nonatomic, readonly) const simd_float3 *gradientLUT;

+ (instancetype)resultWithMode:(KKColorMode)mode
                    solidColor:(simd_float3)solidColor;

+ (instancetype)resultWithGradientLUT:(simd_float3 *)lut;

@end

NS_ASSUME_NONNULL_END
