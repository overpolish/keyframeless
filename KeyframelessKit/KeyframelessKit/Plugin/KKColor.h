/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKConstants.h>
#import <KeyframelessKit/KKGradientBarView.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKColorResult : NSObject

@property(nonatomic, readonly) KKColorMode mode;
@property(nonatomic, readonly) simd_float3 solidColor;
@property(nonatomic, readonly, copy) NSArray<KKGradientStop *> *gradientStops;

+ (instancetype)resultWithMode:(KKColorMode)mode
                    solidColor:(simd_float3)solidColor
                 gradientStops:(NSArray<KKGradientStop *> *)stops;

@end

NS_ASSUME_NONNULL_END
