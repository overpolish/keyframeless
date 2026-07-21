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

/// Draw alpha (multiplies fill + stroke). Default 1.0; set < 1.0 to dim the
/// ring as an Opt-hold revealed ghost. While < 1.0 the ring also ignores
/// hover/active emphasis and shows the arrow cursor (it's a re-enable target,
/// not an interactive control).
@property(nonatomic) float ghostAlpha;

/// Fixed cursor to use on hover instead of the angle-based resize cursor.
/// When nil (default), the ring picks a resize cursor based on mouse angle.
@property(nonatomic, strong, nullable) NSCursor *hoverCursor;

/// When YES, the ring always draws its ACTIVE (solid white) fill + stroke +
/// widths, ignoring idle/hover state - for a host with no hover feedback (e.g.
/// a mini-viewer-parity handle) so it reads crisply white always instead of the
/// dim idle grey. Ghost (Opt-reveal) dimming still applies. Default NO.
@property(nonatomic) BOOL solidStyle;

/// Opt-hover visibility affordance: 0 = none (normal resize/ghost cursor),
/// 1 = "hide" (eye.slash, an Opt-click will hide a visible ring), 2 = "show"
/// (eye, an Opt-click will re-enable a revealed ghost). Set by the owner when
/// Opt is held over a toggleable ring; the ring shows the matching cursor on
/// hit and tracks it so clearCursorIfSet resets it. Default 0.
@property(nonatomic) NSInteger visibilityHint;

/// Configure this ring as the standard small "radius widget" handle - the
/// shared look used for Canvas's live-corner widget and Rounded's radius
/// handle, so the two can't drift. Sets ringRadius / fillWidth /
/// ringOutlineWidth + clearsOnDraw; the caller still sets `center` and
/// `tintColor` per use.
- (void)applyRadiusWidgetStyle;

/// Updates the resize cursor direction based on mouse position relative to
/// center. Call during drag to keep the cursor aligned with drag direction.
- (void)updateCursorForMouseX:(double)positionX positionY:(double)positionY;

/// Resets cursor to arrow if this ring previously set a hover cursor. Call
/// when skipping hit-test on a ring that may have been hovered, to avoid a
/// stale cursor.
- (void)clearCursorIfSet;

@end

NS_ASSUME_NONNULL_END
