/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKOnScreenControl.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKRotationOSC : KKOnScreenControl

/// Canvas-space center of rotation. Set by the owning plugin before hit
/// testing or drawing.
@property(nonatomic) CGPoint center;

/// Distance from center to the handle circle center. Default 28.
@property(nonatomic) float armLength;

/// Offset from center where the line begins. Default 6.
@property(nonatomic) float centerOffset;

/// Radius of the handle circle at the end of the arm. Default 7.
@property(nonatomic) float circleRadius;

/// Width of the connecting line. Default 2.5.
@property(nonatomic) float lineWidth;

/// Width of the outline around the line and circle. Default 1.75.
@property(nonatomic) float outlineWidth;

/// Current rotation angle in radians. Default 0 (pointing right).
@property(nonatomic) float angle;

@end

NS_ASSUME_NONNULL_END
