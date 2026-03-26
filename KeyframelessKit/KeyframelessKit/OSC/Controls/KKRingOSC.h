/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKOnScreenControl.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKRingOSC : KKOnScreenControl

/// Canvas-space center of the ring. Set by the owning plugin before hit
/// testing or drawing.
@property(nonatomic) CGPoint center;

/// Radius from center to the middle of the ring stroke. Default 50.
@property(nonatomic) float ringRadius;

/// Width of the fill stroke. Default 2.
@property(nonatomic) float fillWidth;

/// Width of the outline on each side of the fill. Default 1.5.
@property(nonatomic) float ringOutlineWidth;

/// Updates the resize cursor direction based on mouse position relative to
/// center. Call during drag to keep the cursor aligned with drag direction.
- (void)updateCursorForMouseX:(double)positionX positionY:(double)positionY;

@end

NS_ASSUME_NONNULL_END
