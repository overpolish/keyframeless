/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKOnScreenControl.h>
#import <simd/simd.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKRectBorderOSC : KKOnScreenControl

/// Line color. Default white at 0.6 alpha.
@property(nonatomic) simd_float4 borderColor;

/// Half-width of the border line in canvas pixels. Default 1.0.
@property(nonatomic) float lineHalfWidth;

/// Multiplier on the border alpha (default 1.0). Draw at < 1.0 for a dimmed
/// "ghost" border during opt-reveal.
@property(nonatomic) float ghostAlpha;

/// Draws a rectangular border between two canvas-space corners.
- (void)drawWithTopRight:(CGPoint)topRight
              bottomLeft:(CGPoint)bottomLeft
        destinationImage:(FxImageTile *)destinationImage;

@end

NS_ASSUME_NONNULL_END
