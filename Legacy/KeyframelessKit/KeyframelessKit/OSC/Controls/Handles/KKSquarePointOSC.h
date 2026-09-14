/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKOnScreenControl.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKSquarePointOSC : KKOnScreenControl

/// Half-width of the square in canvas pixels. Default 6.
@property(nonatomic) float oscSize;

/// Corner radius in canvas pixels. Default 2.
@property(nonatomic) float cornerRadius;

/// Outline width in canvas pixels. Default 1.5.
@property(nonatomic) float outlineWidth;

/// Multiplies all (fill / stroke / shadow) alphas, for drawing a dimmed
/// opt-reveal ghost of a hidden control. Default 1.0 (fully opaque).
@property(nonatomic) float ghostAlpha;

@end

NS_ASSUME_NONNULL_END
