/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class NSCursor;

NS_ASSUME_NONNULL_BEGIN

/// FCP's custom resize-handle cursors (extracted from LunaKit into this
/// framework's Resources; see the fcp-cursors reference note). Shared by every
/// resizable OSC - the viewer radius ring (KKRingOSC) and the box gizmo
/// (KKBoxOSC) - so they show identical, FCP-native art.
typedef NS_ENUM(NSInteger, KKResizeCursorKind) {
  KKResizeCursorHorizontal,   // <->  (ResizeLeftRightCursor)
  KKResizeCursorVertical,     // up/down (MoveCurve)
  KKResizeCursorDiagonalNESW, // "/"  (ResizeTopRightCursor)
  KKResizeCursorDiagonalNWSE, // "\"  (ResizeTopLeftCursor)
};

/// The FCP cursor for a resize kind (cached; falls back to the private
/// window-resize cursor, then a public cursor, if the bundled art is missing).
NSCursor *KKResizeCursorOfKind(KKResizeCursorKind kind);

/// Resize cursor for a hover angle in radians (atan2(dy, dx)). Used by ring
/// OSCs where the resize axis is the tangent at the hovered point.
NSCursor *KKResizeCursorForAngle(double radians);

/// Resize cursor for a KKBoxOSC handle index (0-3 corners BL, BR, TR, TL; 4-7
/// edge midpoints bottom, right, top, left). Returns nil for a non-handle
/// index.
NSCursor *_Nullable KKResizeCursorForBoxHandle(NSInteger handleIndex);

/// FCP's move cursor (the 4-way MoveCurveSegment arrow) for a draggable point
/// handle - a radius point, a position/anchor dot, a path point. Cached.
NSCursor *KKPointMoveCursor(void);

/// FCP's rotate cursor (the corner-oriented curved arrow) for a rotation ring,
/// picked by the hover angle in radians (atan2(dy, dx), canvas Y-up) so the
/// curve follows the quadrant the pointer is in. Cached.
NSCursor *KKRotateCursorForAngle(double radians);

/// Cursor for hovering a 3D rotation ring, by axis (0 = X, 1 = Y, 2 = Z). The
/// cursor encodes the axis rather than the hover position, so it stays
/// meaningful as the gizmo reorients: X tilt -> vertical resize (up/down), Y
/// turn -> horizontal resize (left/right), Z spin -> rotate (the curved arrow,
/// picked by `hoverRadians` quadrant). Cached.
NSCursor *KKRotationAxisCursor(NSInteger axis, double hoverRadians);

/// Visibility-toggle cursors for the Opt-hover hide/show affordance on OSC
/// handles. FCP has no native eye cursor, so these render the SF Symbols
/// `eye.slash` / `eye` as a white glyph with a dark outline (so they read on
/// any canvas). `Hide` = hovering a visible control while Opt is held
/// (Opt-click hides it); `Show` = hovering a revealed ghost (Opt-click
/// re-enables it). Cached; falls back to the arrow cursor if the symbol can't
/// be rendered.
NSCursor *KKVisibilityHideCursor(void);
NSCursor *KKVisibilityShowCursor(void);

NS_ASSUME_NONNULL_END
