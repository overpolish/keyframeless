/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKOnScreenControl.h>

@class NSColor;
@class NSCursor;

NS_ASSUME_NONNULL_BEGIN

@interface KKRingOSC : KKOnScreenControl

/// Canvas-space center of the ring. Set by the owning plugin before hit
/// testing or drawing.
@property(nonatomic) CGPoint center;

/// Horizontal radius from center to the middle of the ring stroke. Default 50.
@property(nonatomic) float ringRadius;

/// Vertical radius. When different from ringRadius the ring draws as an
/// ellipse. Default 50.
@property(nonatomic) float ringRadiusY;

/// Width of the fill stroke. Default 2.
@property(nonatomic) float fillWidth;

/// Width of the outline on each side of the fill. Default 1.5.
@property(nonatomic) float ringOutlineWidth;

/// Optional tint color for axis-colored rings. When non-nil, idle/hover/active
/// fill colors are derived from this color at varying alpha levels.
@property(nonatomic, strong, nullable) NSColor *tintColor;

/// Fixed cursor to use on hover instead of the angle-based resize cursor.
/// When nil (default), the ring picks a resize cursor based on mouse angle.
@property(nonatomic, strong, nullable) NSCursor *hoverCursor;

/// Updates the resize cursor direction based on mouse position relative to
/// center. Call during drag to keep the cursor aligned with drag direction.
- (void)updateCursorForMouseX:(double)positionX positionY:(double)positionY;

/// Resets cursor to arrow if this ring previously set a hover cursor. Call
/// when skipping hit-test on a ring that may have been hovered, to avoid a
/// stale cursor.
- (void)clearCursorIfSet;

@end

NS_ASSUME_NONNULL_END
