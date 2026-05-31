/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKOnScreenControl.h>

NS_ASSUME_NONNULL_BEGIN

/// 3-ring sphere rotation gizmo. Each ring is the great-circle perpendicular
/// to its axis, drawn with the current world rotation `R = Ry * Rx * Rz`
/// applied (matching MagicMove's shader order) so the rings visually tilt
/// as the pose changes. Per-ring axis drag: grab a ring, drag tangentially,
/// rotate that axis only.
@interface KKRotationOSC : KKOnScreenControl

/// Canvas-space center of rotation. Set by the owning plugin before hit
/// testing or drawing.
@property(nonatomic) CGPoint center;

/// Sphere radius in canvas pixels. Default 90.
@property(nonatomic) float radius;

/// Ring fill half-width in pixels. Default 2.5.
@property(nonatomic) float ringHalfWidth;

/// Ring outline half-width (extra beyond fill) in pixels. Default 1.0.
@property(nonatomic) float outlineWidth;

/// Alpha multiplier applied to the back hemisphere of each ring. Default 0.3.
@property(nonatomic) float backDim;

/// Current rotation in radians. Order applied as R = Ry * Rx * Rz.
@property(nonatomic) float rotX;
@property(nonatomic) float rotY;
@property(nonatomic) float rotZ;

/// Per-axis ring colors. Default red / green / blue.
@property(nonatomic, strong) NSColor *colorX;
@property(nonatomic, strong) NSColor *colorY;
@property(nonatomic, strong) NSColor *colorZ;
@property(nonatomic, strong) NSColor *outlineColor;

/// Per-axis ring visibility (default YES). A hidden ring is neither drawn nor
/// hit-tested, letting the OSC-visibility popover suppress individual rings.
@property(nonatomic) BOOL showX;
@property(nonatomic) BOOL showY;
@property(nonatomic) BOOL showZ;

/// 0 = X, 1 = Y, 2 = Z, -1 = none. Set by `hitTestAtMousePositionX:...`
/// and consumed by the draw call to highlight the grabbed ring + by
/// `angleDeltaFromPressPoint:currentPoint:` to choose the axis to rotate.
@property(nonatomic, readonly) NSInteger activeAxis;

/// Convert a screen-space drag (press → current, in canvas pixels) into the
/// rotation delta (radians) to apply to `activeAxis`. Projects the screen
/// displacement onto the ring's screen-space tangent at the press point,
/// then divides by radius. Returns 0 if no ring is active.
- (double)angleDeltaFromPressPoint:(CGPoint)pressPoint
                      currentPoint:(CGPoint)currentPoint;

@end

NS_ASSUME_NONNULL_END
