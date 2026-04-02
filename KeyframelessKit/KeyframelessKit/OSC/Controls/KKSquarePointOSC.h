/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
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

@end

NS_ASSUME_NONNULL_END
