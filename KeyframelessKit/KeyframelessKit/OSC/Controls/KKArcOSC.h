/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKOnScreenControl.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKArcOSC : KKOnScreenControl

/// Outer radius of the ring in canvas pixels. Default 23.
@property(nonatomic) float oscRadius;

/// Thickness of the ring stroke. Default 10.
@property(nonatomic) float strokeWidth;

/// Width of the outline around the ring. Default 1.75.
@property(nonatomic) float outlineWidth;

@end

NS_ASSUME_NONNULL_END
