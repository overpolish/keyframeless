/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKOnScreenControl.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKPointOSC : KKOnScreenControl

/// Radius of the point in canvas pixels. Default 7.
@property(nonatomic) float oscRadius;

/// Width of the outline around the point. Default 2.
@property(nonatomic) float outlineWidth;

@end

NS_ASSUME_NONNULL_END
